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

  /// Opened on the first pass and kept for the life of the actor: one connection, WAL, busy timeout.
  private var ledger: LedgerStore?
  /// The last successful read. Survives a failed pass so an import error cannot blank a number.
  private var lastMetrics: LocalUsageMetrics?

  /// `makeSource: nil` disables importing while still reading the metrics. A price table that cannot
  /// be read lists no models, and `CostEngine` prices a model it does not know at zero: importing then
  /// would write real usage into the ledger at $0 permanently, because the cost travels with the row.
  /// Skipping loses nothing — the watermark does not move — so the next pass with a good table
  /// imports exactly the rows that were skipped.
  init(
    ledgerURL: URL,
    priceTable: PriceTable,
    makeSource: (@Sendable () -> any UsageImporting)?
  ) {
    self.ledgerURL = ledgerURL
    self.priceTable = priceTable
    self.makeSource = makeSource
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

  /// Imports everything newer than the ledger's watermark, or returns why it did not.
  private func importNewerUsage(into ledger: LedgerStore) throws -> ImportReport {
    guard let makeSource else {
      return ImportReport(problem: Self.noPriceTableProblem, pricingNote: nil)
    }
    // Wrapped here, not in `AppEnvironment`, so the counters are read off the same instance the sync
    // consumed and the note describes exactly the rows that were offered to it.
    let source = PricingCoverage(wrapping: makeSource(), table: priceTable)
    try LedgerSync(ledger: ledger, source: source).sync()
    return ImportReport(problem: nil, pricingNote: source.pricingNote)
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
