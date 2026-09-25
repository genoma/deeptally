// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import SQLite3
import Testing

@testable import DeepTallyApp

// MARK: - Fixtures

/// A table small enough to price by hand: one model, no peak window and a multiplier of 1, so one row
/// costs exactly `tokens × the rate named here` and the only thing a reprice can change is that rate.
private func repairPriceTable(
  version: String,
  cacheMissUSDPerMillion: String = "0.30"
) -> PriceTable {
  PriceTable(
    version: version,
    currency: "USD",
    effectiveFrom: "2026-09-24",
    offPeakMultiplier: 1,
    peakWindowsUTC: [],
    holidays: [],
    models: [
      ModelPrice(
        model: "deepseek-flash",
        cacheHitUSDPerMillion: decimal("0.006"),
        cacheMissUSDPerMillion: decimal(cacheMissUSDPerMillion),
        outputUSDPerMillion: decimal("1.20")
      )
    ]
  )
}

/// 2026-09-28T02:00:00Z. The fixture calendar is UTC, so this instant is both "now" and inside the
/// local day the metrics are read for, on every machine that runs this suite.
private func repairInstant() throws -> Date {
  try #require(ISO8601DateFormatter().date(from: "2026-09-28T02:00:00Z"))
}

/// The fixture's local calendar; see ``LocalUsageLedger/refresh(now:calendar:)``.
private func repairCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}

/// One million uncached prompt tokens and nothing else: $0.30 at the fixture table's default miss
/// rate, times the multiplier of 1.
private func millionMissRecord(at timestamp: Date, costUSD: Decimal) -> UsageRecord {
  UsageRecord(
    timestamp: timestamp,
    source: .opencode,
    provider: .deepseek,
    model: "deepseek-flash",
    usage: TokenUsage(
      promptTokens: 1_000_000,
      completionTokens: 0,
      cacheHitTokens: 0,
      cacheMissTokens: 1_000_000
    ),
    costUSD: costUSD,
    sessionID: "ses_repair"
  )
}

/// A store on a fixture ledger, left the way a previous import or the CLI would have left it.
private func seedRepairLedger(
  at url: URL,
  timestamp: Date,
  costUSD: Decimal
) throws -> LedgerStore {
  let store = try LedgerStore(url: url)
  _ = try store.insert(
    [millionMissRecord(at: timestamp, costUSD: costUSD)], rawHash: { _ in "row-1" })
  return store
}

/// What the fixture ledger's raw rows add up to right now.
private func storedSpend(_ store: LedgerStore) throws -> Decimal {
  try store.summary(since: .distantPast, until: .distantFuture).spendUSD
}

/// Makes every `request` write fail, so a reprice cannot commit while reading the ledger still works
/// exactly as before. `RAISE(FAIL)` reports the error without undoing the transaction's earlier
/// statements, which is what makes the write fail rather than vanish.
private let blockRepriceSQL = """
  CREATE TRIGGER block_reprice BEFORE UPDATE ON request
  BEGIN
    SELECT RAISE(FAIL, 'reprice blocked by the test');
  END
  """
private let unblockRepriceSQL = "DROP TRIGGER block_reprice"

/// Runs one statement on a fixture ledger through a connection of the test's own.
///
/// This is the one thing `LedgerStore` deliberately does not expose, and the reason it is here: a
/// `BEFORE UPDATE` trigger is how a reprice is made to fail deterministically without breaking the
/// reads the metrics come from. `Tests/DeepTallyCoreTests/RepriceTests.swift` opens the same kind of
/// side connection to count writes.
private func executeRaw(_ sql: String, at url: URL) throws {
  var opened: OpaquePointer?
  let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE, nil)
  guard code == SQLITE_OK, let handle = opened else {
    if let opened { _ = sqlite3_close(opened) }
    throw RawLedgerError(message: "could not open \(url.path) (sqlite \(code))")
  }
  defer { _ = sqlite3_close(handle) }
  var message: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(handle, sql, nil, nil, &message)
  guard result == SQLITE_OK else {
    let detail = message.map { String(cString: $0) } ?? "sqlite \(result)"
    sqlite3_free(message)
    throw RawLedgerError(message: "\(detail) while running: \(sql)")
  }
}

/// A failure in the test's own sqlite plumbing, never in the code under test.
private struct RawLedgerError: Error {
  let message: String
}

// MARK: - The repair itself

/// The one write the app makes to rows it has already imported: when it runs, when it must not, and
/// that a failure is silent.
@Suite("Launch cost repair")
struct LaunchCostRepairTests {
  @Test("a recorded version that differs is repriced before the metrics are read")
  func differingVersionRepairs() async throws {
    let now = try repairInstant()
    let url = temporaryLedgerURL()
    // Stored at the old miss rate, with "old" recorded as the table that produced it.
    let seeded = try seedRepairLedger(at: url, timestamp: now, costUSD: .zero)
    _ = try seeded.reprice(costing: CostEngine(table: repairPriceTable(version: "old")))
    #expect(try seeded.recordedRepricePriceTableVersion() == "old")
    #expect(try storedSpend(seeded) == decimal("0.30"))

    let source = StubUsageSource()
    let ledger = LocalUsageLedger(
      ledgerURL: url,
      priceTable: repairPriceTable(version: "new", cacheMissUSDPerMillion: "0.60"),
      makeSource: { source },
      costing: CostEngine(
        table: repairPriceTable(version: "new", cacheMissUSDPerMillion: "0.60")))

    let outcome = await ledger.refresh(now: now, calendar: repairCalendar())

    #expect(outcome.importProblem == nil)
    // $0.60, not the $0.30 stored a moment ago: the reprice ran before the read.
    #expect(outcome.metrics?.todaySpendUSD == decimal("0.60"))
    #expect(try seeded.recordedRepricePriceTableVersion() == "new")
    #expect(try storedSpend(seeded) == decimal("0.60"))
  }

  @Test("a ledger that was never repriced is repaired on the first pass")
  func absentVersionRepairs() async throws {
    let now = try repairInstant()
    let url = temporaryLedgerURL()
    // The real failure mode: a row stored at zero because its model id did not resolve then.
    let seeded = try seedRepairLedger(at: url, timestamp: now, costUSD: .zero)
    #expect(try seeded.recordedRepricePriceTableVersion() == nil)

    let source = StubUsageSource()
    let ledger = LocalUsageLedger(
      ledgerURL: url,
      priceTable: repairPriceTable(version: "new"),
      makeSource: { source },
      costing: CostEngine(table: repairPriceTable(version: "new")))

    let outcome = await ledger.refresh(now: now, calendar: repairCalendar())

    #expect(outcome.importProblem == nil)
    #expect(outcome.metrics?.todaySpendUSD == decimal("0.30"))
    #expect(try seeded.recordedRepricePriceTableVersion() == "new")
  }

  @Test("a matching version is not repriced: a wrong stored cost is left exactly as it is")
  func matchingVersionDoesNotScan() async throws {
    let now = try repairInstant()
    let url = temporaryLedgerURL()
    let table = repairPriceTable(version: "current")
    let seeded = try seedRepairLedger(at: url, timestamp: now, costUSD: .zero)
    _ = try seeded.reprice(costing: CostEngine(table: table))
    #expect(try seeded.recordedRepricePriceTableVersion() == "current")

    // Deliberately wrong *after* the version was recorded: only a scan would move this number, so a
    // $9.99 today is the proof that no scan happened. The write is raw because no public API can
    // change a stored cost from outside — which is the whole reason the repair exists.
    try executeRaw("UPDATE request SET cost_micro_usd = 9990000", at: url)
    #expect(try storedSpend(seeded) == decimal("9.99"))

    let source = StubUsageSource()
    let ledger = LocalUsageLedger(
      ledgerURL: url, priceTable: table, makeSource: { source },
      costing: CostEngine(table: table))

    let outcome = await ledger.refresh(now: now, calendar: repairCalendar())

    #expect(outcome.importProblem == nil)
    #expect(outcome.metrics?.todaySpendUSD == decimal("9.99"))
    #expect(try storedSpend(seeded) == decimal("9.99"))
    #expect(try seeded.recordedRepricePriceTableVersion() == "current")
  }

  @Test("a failed reprice is silent, leaves the stored numbers in place, and is attempted once")
  func failedRepairIsQuietAndOncePerRun() async throws {
    let now = try repairInstant()
    let url = temporaryLedgerURL()
    let seeded = try seedRepairLedger(at: url, timestamp: now, costUSD: decimal("0.42"))
    try executeRaw(blockRepriceSQL, at: url)

    let source = StubUsageSource()
    let ledger = LocalUsageLedger(
      ledgerURL: url,
      priceTable: repairPriceTable(version: "new"),
      makeSource: { source },
      costing: CostEngine(table: repairPriceTable(version: "new")))

    let first = await ledger.refresh(now: now, calendar: repairCalendar())

    // The failed repair is not an import problem, so nothing would be shown — least of all a banner.
    #expect(first.importProblem == nil)
    #expect(first.metrics?.todaySpendUSD == decimal("0.42"))
    #expect(try seeded.recordedRepricePriceTableVersion() == nil)

    // The next pass could repair (the version still does not match and the trigger is now gone) and
    // must not: one attempt per app run, never one per tick.
    try executeRaw(unblockRepriceSQL, at: url)
    let second = await ledger.refresh(now: now, calendar: repairCalendar())

    #expect(second.importProblem == nil)
    #expect(second.metrics?.todaySpendUSD == decimal("0.42"))
    #expect(try seeded.recordedRepricePriceTableVersion() == nil)
  }
}

// MARK: - What the user sees

/// The repair through the model, where a banner would have to appear if one were raised.
@Suite("App model cost repair", .serialized)
@MainActor
struct AppModelCostRepairTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.costrepair"

  @Test("a changed price table repairs the menu bar number without the user doing anything")
  func changedTableRepairsTheLabel() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let url = temporaryLedgerURL()
      let fixture = makeFixture(
        defaults: defaults,
        ledgerURL: url,
        costing: CostEngine(
          table: repairPriceTable(version: "new", cacheMissUSDPerMillion: "0.60")))
      let seeded = try seedRepairLedger(
        at: url, timestamp: fixture.clock.now, costUSD: .zero)
      _ = try seeded.reprice(costing: CostEngine(table: repairPriceTable(version: "old")))
      #expect(try seeded.recordedRepricePriceTableVersion() == "old")

      fixture.model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { fixture.model.localUsage != nil }
      fixture.model.settings.menuBarMetric = .todaySpend

      #expect(fixture.model.todaySpendText == "$0.60")
      #expect(fixture.model.localUsageNote == nil)
      #expect(fixture.model.banners.isEmpty)
    }
  }

  @Test("a failed repair keeps the label, the quiet note and the balance as they were")
  func failedRepairIsQuiet() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let url = temporaryLedgerURL()
      let fixture = makeFixture(
        defaults: defaults,
        ledgerURL: url,
        costing: CostEngine(table: repairPriceTable(version: "new")))
      _ = try seedRepairLedger(at: url, timestamp: fixture.clock.now, costUSD: decimal("0.42"))
      try executeRaw(blockRepriceSQL, at: url)

      fixture.model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { fixture.model.localUsage != nil }
      fixture.model.settings.menuBarMetric = .todaySpend

      // The number that was in the ledger stays; there is no note and no banner, because a repair
      // that did not happen left nothing the user has to clear.
      #expect(fixture.model.todaySpendText == "$0.42")
      #expect(fixture.model.localUsageProblem == nil)
      #expect(fixture.model.localUsageNote == nil)
      #expect(fixture.model.banners.isEmpty)
      // The balance path is untouched by any of it.
      #expect(fixture.model.balanceState?.amountText == "$12.34")
    }
  }
}
