// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The ledger owner: which range each metric comes from, that a pass resumes from the ledger's own
/// watermark, and that every failure is fail-soft rather than thrown at the app.
@Suite("Local usage ledger")
struct LocalUsageLedgerTests {
  /// A fixed +13 offset, not `Pacific/Auckland`: a DST transition inside a test fixture would move
  /// the local day boundary and make the assertion below depend on the date on the calendar.
  private static let timeZone = TimeZone(secondsFromGMT: 13 * 3_600)!
  /// The local calendar the app now computes day boundaries with; see ``AppEnvironment/calendar``.
  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }

  private static func date(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso))
  }

  /// A ledger actor whose source is the stub, so these tests never build a fixture opencode database.
  /// The shipped price table is the one the app ships with, so the stub's default `deepseek-flash`
  /// rows are priced and these assertions are not about the coverage note.
  private func makeLedger(
    source: StubUsageSource,
    ledgerURL: URL? = nil,
    canImport: Bool = true
  ) throws -> LocalUsageLedger {
    let target = ledgerURL ?? temporaryLedgerURL()
    let table = try PriceTableLoader().loadBundled()
    // `nil` is the shipping "no usable price table" case: read the metrics, import nothing.
    if canImport {
      return LocalUsageLedger(
        ledgerURL: target, priceTable: table, makeSource: { [source] in source })
    }
    return LocalUsageLedger(ledgerURL: target, priceTable: table, makeSource: nil)
  }

  @Test("today's spend is the local day, not the UTC day the rollup is keyed by")
  func todaySpendUsesLocalDayBoundaries() async throws {
    let source = StubUsageSource()
    // 2026-09-24 00:30 local. Both rows below fall on the same *UTC* day (2026-09-23), and only the
    // first one falls on the user's local day — so a UTC-keyed total would report 0.35 here.
    let now = try Self.date("2026-09-23T11:30:00Z")
    source.offer([
      importedRecord(at: try Self.date("2026-09-23T12:00:00Z"), costUSD: decimal("0.25")),
      importedRecord(at: try Self.date("2026-09-23T09:00:00Z"), costUSD: decimal("0.10")),
    ])

    let ledger = try makeLedger(source: source)
    let outcome = await ledger.refresh(now: now, calendar: Self.calendar)

    #expect(outcome.importProblem == nil)
    #expect(outcome.metrics?.todaySpendUSD == decimal("0.25"))
  }

  @Test("the cache-hit rate covers the trailing 30 local days and ignores what falls outside")
  func cacheHitRateWindow() async throws {
    let source = StubUsageSource()
    let now = try Self.date("2026-09-23T11:30:00Z")
    source.offer([
      // The first day of the window (start of today minus 29 days), inside by an hour.
      importedRecord(
        at: try Self.date("2026-08-25T12:00:00Z"), cacheHitTokens: 750, cacheMissTokens: 250,
        costUSD: decimal("0.20")),
      // One day too old: counting it would drag the rate from 75% to 15%.
      importedRecord(
        at: try Self.date("2026-08-24T12:00:00Z"), cacheHitTokens: 0, cacheMissTokens: 4_000,
        costUSD: decimal("0.30")),
    ])

    let ledger = try makeLedger(source: source)
    let outcome = await ledger.refresh(now: now, calendar: Self.calendar)

    #expect(outcome.metrics?.cacheHitRatio == 0.75)
  }

  @Test("a window with no prompt tokens has no cache-hit rate, and a spend that is still real")
  func noPromptTokensHasNoRate() async throws {
    let source = StubUsageSource()
    let now = try Self.date("2026-09-23T11:30:00Z")
    source.offer([
      importedRecord(
        at: now, cacheHitTokens: 0, cacheMissTokens: 0, completionTokens: 500,
        costUSD: decimal("0.10"))
    ])

    let ledger = try makeLedger(source: source)
    let outcome = await ledger.refresh(now: now, calendar: Self.calendar)

    // A rate with no denominator is unknown, not zero: `nil` is what the label turns into an em dash.
    #expect(outcome.metrics?.cacheHitRatio == nil)
    #expect(outcome.metrics?.todaySpendUSD == decimal("0.10"))
  }

  @Test("a second pass resumes from the ledger's watermark instead of rescanning")
  func laterPassesAreIncremental() async throws {
    let source = StubUsageSource()
    let now = try Self.date("2026-09-23T11:30:00Z")
    let imported = try Self.date("2026-09-23T12:00:00Z")
    source.offer([importedRecord(at: imported, costUSD: decimal("0.42"))])
    let ledger = try makeLedger(source: source)

    _ = await ledger.refresh(now: now, calendar: Self.calendar)
    source.offer([])
    let second = await ledger.refresh(now: now, calendar: Self.calendar)

    // The first pass had no watermark and scanned everything; the second asked for the newest instant
    // the ledger committed. A full scan on every tick is exactly what the watermark exists to avoid.
    let expected: [Date?] = [nil, imported]
    #expect(source.resumeInstants == expected)
    #expect(second.importProblem == nil)
    #expect(second.metrics?.todaySpendUSD == decimal("0.42"))
  }

  @Test("a failed import keeps the last good metrics and reports what went wrong")
  func failedImportKeepsLastGoodMetrics() async throws {
    let source = StubUsageSource()
    let now = try Self.date("2026-09-23T11:30:00Z")
    source.offer([importedRecord(at: now, costUSD: decimal("0.42"))])
    let ledger = try makeLedger(source: source)

    let first = await ledger.refresh(now: now, calendar: Self.calendar)
    #expect(first.metrics?.todaySpendUSD == decimal("0.42"))

    source.failFromNowOn()
    let second = await ledger.refresh(now: now, calendar: Self.calendar)

    #expect(second.importProblem != nil)
    #expect(second.metrics?.todaySpendUSD == decimal("0.42"))
  }

  @Test("an unopenable ledger yields no metrics and a problem, never a throw")
  func unusableLedgerIsFailSoft() async throws {
    let source = StubUsageSource()
    source.offer([importedRecord(at: try Self.date("2026-09-23T12:00:00Z"), costUSD: decimal("9"))])
    // `/dev/null` is not a directory, so the ledger's folder cannot be created under it.
    let ledger = try makeLedger(
      source: source, ledgerURL: URL(fileURLWithPath: "/dev/null/deeptally/ledger.sqlite"))

    let outcome = await ledger.refresh(
      now: try Self.date("2026-09-23T11:30:00Z"), calendar: Self.calendar)

    #expect(outcome.metrics == nil)
    #expect(outcome.importProblem != nil)
    // Nothing could be written, so nothing was read either: the source was never scanned.
    #expect(source.scanCount == 0)
  }

  @Test("with no usable price table the pass reads the ledger but never imports")
  func noPriceTableDisablesImporting() async throws {
    let source = StubUsageSource()
    source.offer([importedRecord(at: try Self.date("2026-09-23T12:00:00Z"), costUSD: decimal("9"))])
    let ledger = try makeLedger(source: source, canImport: false)

    let outcome = await ledger.refresh(
      now: try Self.date("2026-09-23T11:30:00Z"), calendar: Self.calendar)

    // An unknown model prices at zero, so importing under an unreadable table would store real usage
    // at $0 forever. The watermark stays put, so the same rows arrive once the table works again.
    #expect(source.scanCount == 0)
    #expect(outcome.importProblem != nil)
    #expect(outcome.metrics?.todaySpendUSD == .zero)
  }
}
