// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation

/// What the ledger currently says about local usage, as one display-ready pair.
struct LocalUsageMetrics: Sendable, Equatable {
  /// Spend over the current **local** day.
  let todaySpendUSD: Decimal
  /// Cache-hit tokens over prompt tokens for the trailing ``LocalUsageLedger/cacheHitWindowDays``
  /// local days, or `nil` when that window recorded no prompt tokens at all.
  let cacheHitRatio: Double?
}

/// The app's single owner of the ledger: opening it, importing into it, and reading the two menu-bar
/// metrics out of it.
///
/// `LedgerStore` is deliberately not `Sendable` (one `sqlite3` connection, one isolation domain), and
/// this actor is that domain. Nothing here runs on the main actor, so neither a 400 MB opencode scan
/// nor a SQLite statement can stall the popover.
///
/// Every failure is fail-soft: ``Outcome/importProblem`` carries a short diagnostic and the last good
/// metrics stay in place. Nothing throws at the caller, because a missing opencode database, an
/// unwritable ledger or a locked file must not become an error banner — let alone a crash — in a menu
/// bar app whose other half (the balance) is unaffected.
actor LocalUsageLedger {
  /// The trailing window the cache-hit rate covers: the 30 local days ending today, today included.
  ///
  /// Local days rather than a fixed 720 hours, because every other boundary in the app is a local day
  /// (docs/PLAN.md §4), and today has to count from its first request rather than from tomorrow.
  /// Thirty days is the horizon the plan names for the cache-hit figure (docs/PLAN.md §5, Step 5):
  /// long enough to be a rate rather than a coin flip, short enough to follow a prompt change.
  static let cacheHitWindowDays = 30

  /// What one ``refresh(now:calendar:)`` found.
  struct Outcome: Sendable, Equatable {
    /// `nil` only when no read of the ledger has ever succeeded.
    let metrics: LocalUsageMetrics?
    /// The analytics panel's numbers, read in the same pass as ``metrics``, or `nil` when no read has
    /// succeeded. Carried in the outcome rather than fetched by a second call so the panel and the
    /// menu bar can never disagree about what the ledger holds.
    let analytics: LocalUsageAnalytics?
    /// Why this pass could not import, or `nil` when it did. A diagnostic, never an error message the
    /// user has to act on: the popover turns it into "local usage is not being imported yet".
    let importProblem: String?
    /// One calm sentence about rows this pass imported with no price, or `nil` when every offered row
    /// had one. Not a failure — the metrics keep their values — and not a banner: the settings panel
    /// shows it where it already says local usage is being imported.
    let pricingNote: String?
  }

  /// Kept out of the ledger: it is a fact about this process, not about the user's usage.
  private static let noPriceTableProblem = "the price table is unavailable"

  private let ledgerURL: URL
  /// The table this pass checks its offered rows against. The costing inside ``makeSource`` already
  /// prices with it — both come from the same ``AppEnvironment`` — so this is only what turns "the
  /// engine returned 0" into "the table cannot price that model".
  private let priceTable: PriceTable
  /// Builds the importer for one pass, or `nil` to disable importing.
  ///
  /// A closure so the scanner — which holds the pricing engine and is not `Sendable` — is created
  /// inside the actor's isolation domain and never crosses a boundary, and so a test can offer canned
  /// rows instead of a 400 MB fixture database.
  private let makeSource: (@Sendable () -> any UsageImporting)?

  /// What the one launch repair prices stored rows with, or `nil` when there is nothing to repair with:
  /// an unreadable price table, or a caller that only reads. A value, not a closure like
  /// ``makeSource``: ``RowCosting`` is `Sendable`, so unlike the importer it can cross into the actor,
  /// and it is the same table the importer prices new rows with.
  private let costing: (any RowCosting)?

  /// Opened on the first pass and kept for the life of the actor: one connection, WAL, busy timeout.
  private var ledger: LedgerStore?
  /// The last successful read. Survives a failed pass so an import error cannot blank a number.
  private var lastMetrics: LocalUsageMetrics?
  /// The last successful analytics read, kept beside ``lastMetrics`` and for the same reason: a failed
  /// pass must leave the panel showing what was true a moment ago, not empty it.
  private var lastAnalytics: LocalUsageAnalytics?
  /// `true` from the moment the one launch repair is reached, successful or not, so a reprice scan can
  /// never repeat on the fifteen-minute tick. See ``repairStoredCosts(in:)``.
  private var didAttemptRepair = false

  /// `makeSource: nil` disables importing while still reading the metrics. A price table that cannot
  /// be read lists no models, and `CostEngine` prices a model it does not know at zero: importing then
  /// would write real usage into the ledger at $0 permanently, because the cost travels with the row.
  /// Skipping loses nothing — the watermark does not move — so the next pass with a good table
  /// imports exactly the rows that were skipped.
  /// `costing: nil` disables the repair while still importing and reading: a caller with no price
  /// table, and every test that is not about the repair itself.
  init(
    ledgerURL: URL,
    priceTable: PriceTable,
    makeSource: (@Sendable () -> any UsageImporting)?,
    costing: (any RowCosting)? = nil
  ) {
    self.ledgerURL = ledgerURL
    self.priceTable = priceTable
    self.makeSource = makeSource
    self.costing = costing
  }

  /// One pass: import what the source has newer than the ledger's stored watermark, then read the two
  /// metric ranges.
  ///
  /// Passes are serial by construction (the actor runs one at a time) and the model never starts one
  /// while another is in flight, so "never import while another import is running" holds at both
  /// levels.
  func refresh(now: Date, calendar: Calendar) -> Outcome {
    let ledger: LedgerStore
    do {
      ledger = try openLedger()
    } catch {
      // The ledger itself is unusable: no import, no numbers, and the last good ones survive.
      return Outcome(
        metrics: lastMetrics, analytics: lastAnalytics,
        importProblem: String(describing: error), pricingNote: nil)
    }

    // Before the import, so a first run over a fresh ledger records the table without scanning the rows
    // it is about to import, and before the read, so the numbers shown are the repaired ones.
    repairStoredCosts(in: ledger)

    var importProblem: String?
    var pricingNote: String?
    do {
      let report = try importNewerUsage(into: ledger)
      importProblem = report.problem
      pricingNote = report.pricingNote
    } catch {
      importProblem = String(describing: error)
    }

    do {
      let readings = try Self.readUsage(from: ledger, now: now, calendar: calendar)
      lastMetrics = readings.metrics
      lastAnalytics = readings.analytics
      return Outcome(
        metrics: readings.metrics, analytics: readings.analytics, importProblem: importProblem,
        pricingNote: pricingNote)
    } catch {
      // The open and the import both worked and only the read failed, which is not a reason to blank
      // a number that was true a moment ago.
      return Outcome(
        metrics: lastMetrics, analytics: lastAnalytics,
        importProblem: importProblem ?? String(describing: error),
        pricingNote: pricingNote)
    }
  }

  /// What one ``record(_:now:calendar:)`` did.
  struct ProxyRecordOutcome: Sendable, Equatable {
    enum Disposition: Sendable, Equatable {
      /// The ledger stored the row.
      case recorded
      /// The ledger already held a row under this response's key: nothing was written.
      case duplicate
      /// There is no usable price table, so the row was not stored — see ``record(_:now:calendar:)``.
      case skippedNoPriceTable
      /// The ledger could not be written. The response still reached the client; this row is lost.
      case failed
    }

    let disposition: Disposition
    /// Today's spend and the trailing cache-hit rate as they read right after the write, or `nil`
    /// when nothing was written or the read failed. Carried here rather than fetched by a second call
    /// so a proxied request shows up in the menu bar without waiting for the fifteen-minute tick.
    let metrics: LocalUsageMetrics?
    /// The analytics panel's numbers from the same re-read, or `nil` for the same reasons.
    let analytics: LocalUsageAnalytics?
  }

  /// Records one proxied response.
  ///
  /// Priced by the same engine every other row is priced with, at the response's own instant, so a
  /// proxy row and an imported row for the same instant cannot disagree about the rate. The row is
  /// keyed on the response id, so a client that repeats a response — a retry that returns the same
  /// body, a duplicated stream — adds one row and not two; a body with no id falls back to the
  /// response's instant, model and counters.
  ///
  /// **With no price table nothing is recorded.** An unreadable table prices every model at zero and
  /// a row's cost travels with it forever, so a stored row would be a permanent $0 — the same reason
  /// ``refresh(now:calendar:)`` imports nothing without a table. Dropping the row costs this one
  /// request's counters; writing a cost that is wrong would corrupt the spend. This is harsher than
  /// the importer's skip: an import's watermark does not move, so those rows return once the table is
  /// back, while a proxied request is gone. It is reachable only when the bundled table itself fails to
  /// load, which is a broken installation rather than a transient state. A model the *table* cannot
  /// price is a different case and is stored at zero, exactly as the importer stores it, and
  /// ``ledgerPricingNote(_:)`` names it on the next pass.
  ///
  /// The menu-bar metrics and the analytics panel are re-read in the same call after a successful
  /// insert, so a recorded response is visible without waiting for the next import tick.
  func record(_ usage: ProxyUsage, now: Date, calendar: Calendar) -> ProxyRecordOutcome {
    guard let costing else {
      return ProxyRecordOutcome(disposition: .skippedNoPriceTable, metrics: nil, analytics: nil)
    }
    let ledger: LedgerStore
    do {
      ledger = try openLedger()
    } catch {
      return ProxyRecordOutcome(disposition: .failed, metrics: nil, analytics: nil)
    }

    let record = UsageRecord(
      timestamp: usage.recordedAt,
      source: .proxy,
      provider: .deepseek,
      model: usage.model,
      usage: usage.usage,
      // `costIfPriced` answers `nil` for a model the table does not list, and the row is stored at zero
      // rather than dropped: the ledger's own unpriced scan reports it, and a reprice repairs it once
      // the table knows the model.
      costUSD: costing.costIfPriced(model: usage.model, usage: usage.usage, at: usage.recordedAt)
        ?? .zero
    )

    do {
      let inserted = try ledger.insert([(record: record, rawHash: Self.rawHash(for: usage))])
      let readings = try? Self.readUsage(from: ledger, now: now, calendar: calendar)
      if let readings {
        lastMetrics = readings.metrics
        lastAnalytics = readings.analytics
      }
      return ProxyRecordOutcome(
        disposition: inserted > 0 ? .recorded : .duplicate,
        metrics: readings?.metrics, analytics: readings?.analytics)
    } catch {
      return ProxyRecordOutcome(disposition: .failed, metrics: nil, analytics: nil)
    }
  }

  /// The ledger's dedupe key for one proxied response: the source plus the response id. A body with
  /// no id — the API sends one, but the reader tolerates one without — falls back to the response's
  /// instant, model and counters, which is what makes a repeated identical response one row.
  ///
  /// The unit separator is the importer's convention for joining the parts of a key, and `raw_hash`
  /// is UNIQUE in the ledger, so this is the whole of the duplication policy.
  static func rawHash(for usage: ProxyUsage) -> String {
    let identity =
      usage.responseID
      ?? [
        // Seconds, not the full Double: a client that repeats an id-less response writes a different
        // microsecond every time, so a sub-second instant would make the fallback dedupe nothing.
        "\(Int(usage.recordedAt.timeIntervalSince1970.rounded()))", usage.model,
        "\(usage.usage.promptTokens):\(usage.usage.completionTokens)",
        "\(usage.usage.cacheHitTokens):\(usage.usage.cacheMissTokens):\(usage.usage.reasoningTokens)",
      ].joined(separator: "\u{1F}")
    return "\(UsageSource.proxy.rawValue)\u{1F}\(identity)"
  }

  /// What one import did: why the ledger got nothing new, and which of the rows it did get the price
  /// table cannot price.
  private struct ImportReport {
    let problem: String?
    let pricingNote: String?
  }

  /// The one repair pass this process runs: the only write the app makes to rows it has already
  /// imported, and the answer to a user who will never run a CLI command.
  ///
  /// A row's cost is computed once, at import, and stored beside its tokens. A row whose model id did
  /// not resolve then is stored at zero and a re-import cannot fix it, because `raw_hash` makes it a
  /// duplicate — correct for counting, useless for repair. ``LedgerStore/reprice(costing:batchSize:)``
  /// is the repair, and the only reason to run it is that the table in hand is not the one the stored
  /// costs came from, which the ledger records as a version (see
  /// ``LedgerStore/recordedRepricePriceTableVersion()``). A matching version, or a costing that names
  /// no table, is nothing to scan for.
  ///
  /// At most once per app run, on the first pass that has a costing, and never on the fifteen-minute
  /// tick: this is a repair for a changed price table, not a routine. Silent by design — it runs
  /// before the metrics are read, so success shows up as the repaired numbers, and a failure leaves
  /// the ledger exactly as it was, which is nothing the user would have to clear or could act on. The
  /// next launch tries again with whatever table it loads then.
  private func repairStoredCosts(in ledger: LedgerStore) {
    guard !didAttemptRepair, let costing, !costing.priceTableVersion.isEmpty else { return }
    didAttemptRepair = true
    do {
      guard try ledger.recordedRepricePriceTableVersion() != costing.priceTableVersion else {
        return
      }
      _ = try ledger.reprice(costing: costing)
    } catch {
      // Swallowed on purpose: the ledger still reads, so the numbers on screen are the ones it holds,
      // and this is not "local usage is not being imported yet". `deeptally ledger reprice` reports the
      // same failure to anyone who asks for the detail.
    }
  }

  /// Imports everything newer than the ledger's watermark, or returns why it did not.
  private func importNewerUsage(into ledger: LedgerStore) throws -> ImportReport {
    guard let makeSource else {
      return ImportReport(problem: Self.noPriceTableProblem, pricingNote: nil)
    }
    // Wrapped here, not in `AppEnvironment`, so the counters are read off the same instance the sync
    // consumed and the note describes exactly the rows that were offered to it.
    let source = PricingCoverage(wrapping: makeSource(), table: priceTable)
    try LedgerSync(ledger: ledger, source: source).sync()
    // The note describes the LEDGER, not this pass's offered rows: a pass that offers nothing while the
    // ledger still holds zero-cost rows would otherwise clear the caveat and leave a clean panel over
    // under-reported spend (review finding N1). The extra scan is one row pass over the ledger, on the
    // actor, on the same fifteen-minute cadence as the import itself.
    return ImportReport(problem: nil, pricingNote: try ledgerPricingNote(ledger))
  }

  /// The ledger-wide unpriced sentence, or `nil` when every stored row has a price.
  private func ledgerPricingNote(_ ledger: LedgerStore) throws -> String? {
    guard let costing else { return nil }
    let summary = try ledger.unpricedSummary(costing: costing)
    return PricingCoverage.note(
      rows: summary.rowsUnpriced, models: summary.models.map(\.model), scope: "ledger")
  }

  // MARK: - CSV transfer

  /// What one CSV transfer did, as a count. The wording belongs to the caller: this actor reports a
  /// number, the model turns it into a sentence.
  struct TransferOutcome: Sendable, Equatable {
    /// Export: rows written. Import: rows the ledger did not already have.
    let rows: Int
  }

  /// Writes every raw row to `url` and returns how many went out.
  ///
  /// The same `exportCSV` the CLI uses, on the actor's own connection, so a large ledger cannot
  /// block the popover and the app and the CLI produce byte-identical files for the same ledger.
  func exportCSV(to url: URL) throws -> TransferOutcome {
    let ledger = try openLedger()
    try ledger.exportCSV(to: url)
    // Every stored row is one request; the summary count is the number of lines written after the
    // header, and it reads the same store the export just read.
    let rows = try ledger.summary(since: .distantPast, until: .distantFuture).requestCount
    return TransferOutcome(rows: rows)
  }

  /// Adds the rows in a CSV file this app or the CLI wrote, and returns how many were new.
  ///
  /// A file with one malformed row is refused whole, so the ledger is either untouched or holds the
  /// file's rows — never half of them (`LedgerStore.importCSV(from:)` parses before it writes).
  func importCSV(from url: URL) throws -> TransferOutcome {
    TransferOutcome(rows: try openLedger().importCSV(from: url))
  }

  private func openLedger() throws -> LedgerStore {
    if let ledger { return ledger }
    let opened = try LedgerStore(url: ledgerURL)
    ledger = opened
    return opened
  }

  /// One pass's readings: the two menu bar metrics and the analytics panel's numbers, from the same
  /// queries so they cannot disagree.
  private struct Readings {
    let metrics: LocalUsageMetrics
    let analytics: LocalUsageAnalytics
  }

  /// Today's spend, the trailing cache-hit rate, and the analytics panel's three windows, per-model
  /// breakdown and daily series.
  ///
  /// Every range goes through `LedgerStore.usageWindow(since:until:provider:)`, which answers a day
  /// from `request` while its raw rows are there and from the `daily` rollup once a prune has taken
  /// them — so pruning never blanks the menu bar metric or the panel. The windows are local days
  /// because "today" is a question about the user's clock; the rollup days that stand in for pruned
  /// days are whole UTC days, and the panel says so when any of them appear
  /// (`LocalUsageAnalytics.rollupNote`).
  ///
  /// The range boundaries are built from `calendar`, the one place they are built, and days are added
  /// through it rather than as 86 400 seconds, so a DST day stays a whole local day.
  private static func readUsage(
    from ledger: LedgerStore,
    now: Date,
    calendar: Calendar
  ) throws -> Readings {
    let dayStart = calendar.startOfDay(for: now)
    let dayEnd =
      calendar.date(byAdding: .day, value: 1, to: dayStart)
      ?? dayStart.addingTimeInterval(86_400)

    func window(days: Int) throws -> LedgerUsageWindow {
      let start =
        calendar.date(byAdding: .day, value: -(days - 1), to: dayStart)
        ?? dayStart.addingTimeInterval(-Double(days - 1) * 86_400)
      return try ledger.usageWindow(since: start, until: dayEnd)
    }

    let today = try window(days: 1)
    let week = try window(days: 7)
    let month = try window(days: Self.cacheHitWindowDays)

    let metrics = LocalUsageMetrics(
      todaySpendUSD: today.summary.spendUSD,
      cacheHitRatio: month.summary.cacheHitRatio)

    func panelWindow(
      key: String, label: String, _ window: LedgerUsageWindow
    ) -> LocalUsageAnalytics.Window {
      LocalUsageAnalytics.Window(
        key: key,
        label: label,
        spendUSD: window.summary.spendUSD,
        requestCount: window.summary.requestCount,
        tokenCount: window.summary.promptTokens + window.summary.outputTokens
          + window.summary.reasoningTokens,
        cacheHitRatio: window.summary.cacheHitRatio,
        rollupDays: window.rollupDayCount,
        unavailableDays: window.unavailableDays)
    }

    let analytics = LocalUsageAnalytics(
      windows: [
        panelWindow(key: "today", label: "Today", today),
        panelWindow(key: "last_7_days", label: "7 days", week),
        panelWindow(key: "last_30_days", label: "\(Self.cacheHitWindowDays) days", month),
      ],
      models: month.summary.models.map {
        LocalUsageAnalytics.ModelRow(
          provider: $0.provider,
          model: $0.model,
          spendUSD: $0.spendUSD,
          requestCount: $0.requestCount,
          cacheHitRatio: $0.cacheHitRatio)
      },
      days: month.days.map {
        LocalUsageAnalytics.DayPoint(
          date: $0.date,
          spendUSD: $0.summary.spendUSD,
          requestCount: $0.summary.requestCount,
          cacheHitRatio: $0.summary.cacheHitRatio)
      })
    return Readings(metrics: metrics, analytics: analytics)
  }
}
