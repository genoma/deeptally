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
        metrics: lastMetrics, importProblem: String(describing: error), pricingNote: nil)
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
      let metrics = try Self.readMetrics(from: ledger, now: now, calendar: calendar)
      lastMetrics = metrics
      return Outcome(metrics: metrics, importProblem: importProblem, pricingNote: pricingNote)
    } catch {
      // The open and the import both worked and only the read failed, which is not a reason to blank
      // a number that was true a moment ago.
      return Outcome(
        metrics: lastMetrics,
        importProblem: importProblem ?? String(describing: error),
        pricingNote: pricingNote)
    }
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

  /// Today's spend and the trailing cache-hit rate, each from its own `ts` range on the raw rows.
  ///
  /// The range boundaries are local days computed from `calendar`, which is what `request.ts` range
  /// queries are for: `daily` is keyed by **UTC** date, so reading "today" out of it is off by a day
  /// for everyone east or west of UTC. This is the one place those boundaries are built.
  private static func readMetrics(
    from ledger: LedgerStore,
    now: Date,
    calendar: Calendar
  ) throws -> LocalUsageMetrics {
    let dayStart = calendar.startOfDay(for: now)
    let dayEnd =
      calendar.date(byAdding: .day, value: 1, to: dayStart)
      ?? dayStart.addingTimeInterval(86_400)
    let windowStart =
      calendar.date(byAdding: .day, value: 1 - cacheHitWindowDays, to: dayStart)
      ?? dayStart.addingTimeInterval(-Double(cacheHitWindowDays - 1) * 86_400)

    let today = try ledger.summary(since: dayStart, until: dayEnd)
    let window = try ledger.summary(since: windowStart, until: dayEnd)
    return LocalUsageMetrics(todaySpendUSD: today.spendUSD, cacheHitRatio: window.cacheHitRatio)
  }
}
