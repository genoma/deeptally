// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3
import Testing

@testable import DeepTallyCore

// MARK: - Fixtures

/// A ledger in a throwaway folder, plus a plain connection to the same file for the two things the
/// store deliberately does not expose: dumps to compare, and a trigger that counts every write to
/// `request` — the only way to prove a row was *not* rewritten.
private final class RepriceFixture {
  let directory: URL
  let url: URL
  let store: LedgerStore
  let raw: RawConnection

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-reprice-tests-\(UUID().uuidString)")
    url = directory.appending(path: "Application Support/DeepTally/ledger.sqlite")
    store = try LedgerStore(url: url)
    raw = try RawConnection(url: url)
  }

  /// Starts counting `request` writes. Call it after the fixture rows are in, so only the pass under
  /// test is counted.
  func countWrites() throws {
    try raw.execute("CREATE TABLE write_log(writes INTEGER NOT NULL)")
    try raw.execute("INSERT INTO write_log VALUES (0)")
    try raw.execute(
      """
      CREATE TRIGGER log_request_write AFTER UPDATE ON request
      BEGIN UPDATE write_log SET writes = writes + 1; END
      """)
  }

  func writes() throws -> Int { try raw.integer("SELECT writes FROM write_log") }

  /// Every stored cost, oldest row first.
  func costs() throws -> [Int64] {
    try raw.integers("SELECT cost_micro_usd FROM request ORDER BY id")
  }

  func destroy() { try? FileManager.default.removeItem(at: directory) }
}

/// A failure in a test's own sqlite plumbing, never in the code under test.
private struct RawConnectionError: Error {
  let message: String
}

/// A second connection to the same file, with just enough SQL to watch it.
private final class RawConnection {
  private var handle: OpaquePointer?

  init(url: URL) throws {
    var opened: OpaquePointer?
    let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE, nil)
    guard code == SQLITE_OK, let database = opened else {
      let reason = opened.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
      if let opened { _ = sqlite3_close(opened) }
      throw RawConnectionError(message: "could not open \(url.path): \(reason)")
    }
    handle = database
  }

  deinit {
    if let handle { _ = sqlite3_close(handle) }
  }

  func execute(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(handle, sql, nil, nil, &message)
    guard code == SQLITE_OK else {
      let detail = message.map { String(cString: $0) } ?? "code \(code)"
      sqlite3_free(message)
      throw RawConnectionError(message: "\(detail) while running: \(sql)")
    }
  }

  /// The first column of every row, as text.
  func strings(_ sql: String) throws -> [String] {
    var values: [String] = []
    try read(sql) { statement in
      if let bytes = sqlite3_column_text(statement, 0) {
        let count = Int(sqlite3_column_bytes(statement, 0))
        values.append(
          String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
      } else {
        values.append("")
      }
    }
    return values
  }

  func integers(_ sql: String) throws -> [Int64] {
    var values: [Int64] = []
    try read(sql) { statement in values.append(sqlite3_column_int64(statement, 0)) }
    return values
  }

  func integer(_ sql: String) throws -> Int {
    guard let first = try integers(sql).first else {
      throw RawConnectionError(message: "no rows from: \(sql)")
    }
    return Int(first)
  }

  private func read(_ sql: String, _ body: (OpaquePointer) -> Void) throws {
    var statement: OpaquePointer?
    let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard prepare == SQLITE_OK, let prepared = statement else {
      throw RawConnectionError(message: "could not prepare: \(sql)")
    }
    defer { _ = sqlite3_finalize(prepared) }
    while true {
      let step = sqlite3_step(prepared)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw RawConnectionError(message: "could not read: \(sql)")
      }
      body(prepared)
    }
  }
}

/// The shipped flash prices in a table small enough to compute by hand. 2026-09-28 is a Monday, so
/// 02:00 UTC is inside the 01:00–04:00 peak window and 12:00 UTC is off-peak at exactly half.
private func repriceTable(
  version: String = "reprice-tests",
  cacheMissUSDPerMillion: String = "0.30"
) -> PriceTable {
  PriceTable(
    version: version,
    currency: "USD",
    effectiveFrom: "2026-09-24",
    offPeakMultiplier: Decimal.parse("0.5"),
    peakWindowsUTC: [PeakWindow(startHourUTC: 1, endHourUTC: 4)],
    holidays: [],
    models: [
      ModelPrice(
        model: "deepseek-flash",
        cacheHitUSDPerMillion: Decimal.parse("0.006"),
        cacheMissUSDPerMillion: Decimal.parse(cacheMissUSDPerMillion),
        outputUSDPerMillion: Decimal.parse("1.20")
      )
    ]
  )
}

private func instant(_ iso8601: String) -> Date {
  let formatter = ISO8601DateFormatter()
  guard let date = formatter.date(from: iso8601) else {
    preconditionFailure("invalid fixture instant: \(iso8601)")
  }
  return date
}

/// One million uncached prompt tokens and nothing else: 0.30 USD in peak, 0.15 off-peak, exactly.
private let millionMissTokens = TokenUsage(
  promptTokens: 1_000_000,
  completionTokens: 0,
  cacheHitTokens: 0,
  cacheMissTokens: 1_000_000,
  reasoningTokens: 0
)

/// 500k cached, 250k uncached, 100k completion of which 20k is reasoning — the arithmetic case from
/// the ledger suite, so a rounding difference would be visible rather than convenient.
private let mixedTokens = TokenUsage(
  promptTokens: 750_000,
  completionTokens: 100_000,
  cacheHitTokens: 500_000,
  cacheMissTokens: 250_000,
  reasoningTokens: 20_000
)

private func record(
  at timestamp: Date,
  model: String = "deepseek-flash",
  usage: TokenUsage,
  costUSD: Decimal,
  sessionID: String
) -> UsageRecord {
  UsageRecord(
    timestamp: timestamp,
    source: .opencode,
    provider: .deepseek,
    model: model,
    usage: usage,
    costUSD: costUSD,
    sessionID: sessionID
  )
}

private func insert(_ records: [UsageRecord], into store: LedgerStore) throws -> Int {
  try store.insert(records) { $0.sessionID ?? "" }
}

/// What the engine would have stored for a row imported with this table.
private func storedCost(
  _ engine: CostEngine, model: String = "deepseek-flash", usage: TokenUsage, at timestamp: Date
) -> Int64 {
  MicroUSD.fromDecimal(engine.cost(model: model, usage: usage, at: timestamp))
}

// MARK: - Reprice

@Suite("Ledger reprice")
struct LedgerRepriceTests {
  @Test("a row stored with the wrong cost is repriced from its own tokens")
  func correctsAWrongCost() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let engine = CostEngine(table: repriceTable())
    let at = instant("2026-09-28T02:00:00Z")
    let expected = storedCost(engine, usage: mixedTokens, at: at)
    #expect(expected > 0)

    #expect(
      try insert(
        [record(at: at, usage: mixedTokens, costUSD: .zero, sessionID: "ses_a")],
        into: fixture.store) == 1)
    #expect(try fixture.costs() == [0])

    let outcome = try fixture.store.reprice(costing: engine)

    #expect(outcome.rowsExamined == 1)
    #expect(outcome.rowsChanged == 1)
    #expect(outcome.rowsUnpriced == 0)
    #expect(outcome.unpricedModels.isEmpty)
    #expect(outcome.madeNoChanges == false)
    #expect(outcome.spendBeforeUSD == .zero)
    #expect(outcome.spendAfterUSD == MicroUSD.decimal(expected))
    #expect(outcome.spendDeltaUSD == MicroUSD.decimal(expected))
    #expect(try fixture.costs() == [expected])
    #expect(outcome.priceTableVersion == "reprice-tests")
    #expect(outcome.previousPriceTableVersion == nil)
    #expect(try fixture.store.recordedRepricePriceTableVersion() == "reprice-tests")
  }

  @Test("only the rows whose cost changes are written")
  func writesOnlyChangedRows() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let engine = CostEngine(table: repriceTable())
    let at = instant("2026-09-28T02:00:00Z")
    let correct = storedCost(engine, usage: millionMissTokens, at: at)

    #expect(
      try insert(
        [
          // Already right: a reprice must leave it exactly as it is, not rewrite the same number.
          record(
            at: at, usage: millionMissTokens, costUSD: MicroUSD.decimal(correct),
            sessionID: "ses_ok"),
          // Stored when the model id did not resolve.
          record(at: at, usage: millionMissTokens, costUSD: .zero, sessionID: "ses_zero"),
        ], into: fixture.store) == 2)
    try fixture.countWrites()

    let outcome = try fixture.store.reprice(costing: engine)

    #expect(outcome.rowsExamined == 2)
    #expect(outcome.rowsChanged == 1)
    #expect(try fixture.writes() == 1)
    #expect(try fixture.costs() == [correct, correct])
    #expect(outcome.spendBeforeUSD == MicroUSD.decimal(correct))
    #expect(outcome.spendAfterUSD == MicroUSD.decimal(correct * 2))
  }

  @Test("reprice is idempotent: a second run writes nothing and says so")
  func isIdempotent() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let engine = CostEngine(table: repriceTable())
    let at = instant("2026-09-28T12:00:00Z")
    #expect(
      try insert(
        [record(at: at, usage: mixedTokens, costUSD: .zero, sessionID: "ses_a")],
        into: fixture.store) == 1)

    let first = try fixture.store.reprice(costing: engine)
    #expect(first.rowsChanged == 1)

    try fixture.countWrites()
    let second = try fixture.store.reprice(costing: engine)

    #expect(second.rowsExamined == 1)
    #expect(second.rowsChanged == 0)
    #expect(second.madeNoChanges)
    #expect(try fixture.writes() == 0)
    #expect(second.spendBeforeUSD == first.spendAfterUSD)
    #expect(second.spendAfterUSD == first.spendAfterUSD)
    #expect(second.previousPriceTableVersion == "reprice-tests")
    #expect(try fixture.store.recordedRepricePriceTableVersion() == "reprice-tests")
  }

  @Test("each row is priced with the window in force at its own instant")
  func pricesEachRowWithItsOwnInstant() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let engine = CostEngine(table: repriceTable())
    // Same tokens, twelve hours apart: 02:00 UTC on a Monday is peak, 12:00 UTC is off-peak.
    let peak = instant("2026-09-28T02:00:00Z")
    let offPeak = instant("2026-09-28T12:00:00Z")

    #expect(
      try insert(
        [
          record(at: peak, usage: millionMissTokens, costUSD: .zero, sessionID: "ses_peak"),
          record(at: offPeak, usage: millionMissTokens, costUSD: .zero, sessionID: "ses_off"),
        ], into: fixture.store) == 2)

    let outcome = try fixture.store.reprice(costing: engine)

    #expect(outcome.rowsChanged == 2)
    // 1M miss tokens at 0.30 USD/1M: 300,000 micro-USD in peak, 150,000 off-peak.
    #expect(try fixture.costs() == [300_000, 150_000])
    #expect(outcome.spendAfterUSD == MicroUSD.decimal(450_000))
  }

  @Test("the daily rollups are rebuilt from the recomputed rows")
  func rebuildsRollups() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let engine = CostEngine(table: repriceTable())
    let at = instant("2026-09-28T02:00:00Z")
    #expect(
      try insert(
        [
          record(at: at, usage: millionMissTokens, costUSD: .zero, sessionID: "ses_a"),
          record(at: at, usage: millionMissTokens, costUSD: .zero, sessionID: "ses_b"),
          record(
            at: instant("2026-09-29T02:00:00Z"), usage: millionMissTokens, costUSD: .zero,
            sessionID: "ses_c"),
        ], into: fixture.store) == 3)
    #expect(try fixture.raw.integers("SELECT cost_micro_usd FROM daily") == [0, 0])

    let outcome = try fixture.store.reprice(costing: engine)

    #expect(outcome.rowsChanged == 3)
    // The rollup is a direct aggregate of the raw rows it is derived from.
    let daily = try fixture.raw.strings(
      """
      SELECT date || '|' || provider || '|' || model || '|' || input || '|' || output || '|'
             || reasoning || '|' || cache_read || '|' || cost_micro_usd || '|' || request_count
        FROM daily ORDER BY date, provider, model
      """)
    let aggregate = try fixture.raw.strings(
      """
      SELECT date(ts, 'unixepoch') || '|' || provider || '|' || model || '|' || SUM(input) || '|'
             || SUM(output) || '|' || SUM(reasoning) || '|' || SUM(cache_read) || '|'
             || SUM(cost_micro_usd) || '|' || COUNT(*)
        FROM request GROUP BY date(ts, 'unixepoch'), provider, model
       ORDER BY date(ts, 'unixepoch'), provider, model
      """)
    #expect(daily == aggregate)
    #expect(daily.count == 2)
    #expect(daily.contains { $0.hasSuffix("|600000|2") })
    #expect(daily.contains { $0.hasSuffix("|300000|1") })

    // And the summary a caller reads agrees with what the pass reported.
    let summary = try fixture.store.summary(since: .distantPast, until: .distantFuture)
    #expect(summary.spendUSD == outcome.spendAfterUSD)
    #expect(summary.requestCount == 3)
  }

  @Test("a model the table cannot price is reported and left exactly as it was")
  func reportsUnpricedRowsWithoutInventingACost() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let engine = CostEngine(table: repriceTable())
    let at = instant("2026-09-28T02:00:00Z")
    let correct = storedCost(engine, usage: millionMissTokens, at: at)

    #expect(
      try insert(
        [
          record(
            at: at, usage: millionMissTokens, costUSD: MicroUSD.decimal(correct),
            sessionID: "ses_ok"),
          // A model this table cannot price that still carries a cost: repricing must not zero it.
          // Deliberately not a real DeepSeek id: an id the shipped table resolves by alias would make
          // "unpriced" mean two different things here and in the real ledger.
          record(
            at: at, model: "retired-unlisted-model", usage: millionMissTokens,
            costUSD: Decimal.parse("0.02"), sessionID: "ses_retired"),
        ], into: fixture.store) == 2)

    let outcome = try fixture.store.reprice(costing: engine)

    #expect(outcome.rowsExamined == 2)
    #expect(outcome.rowsChanged == 0)
    #expect(outcome.rowsUnpriced == 1)
    #expect(
      outcome.unpricedModels == [
        UnpricedModel(model: "retired-unlisted-model", rows: 1, spendUSD: Decimal.parse("0.02"))
      ])
    #expect(try fixture.costs() == [correct, 20_000])
    #expect(outcome.spendBeforeUSD == outcome.spendAfterUSD)
  }

  @Test("a ledger larger than one batch is repriced completely and exactly once")
  func repricesAcrossBatches() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let engine = CostEngine(table: repriceTable())
    let at = instant("2026-09-28T02:00:00Z")

    // 23 rows at four per page: six pages, the last one short.
    let rows = (0..<23).map { index in
      record(at: at, usage: millionMissTokens, costUSD: .zero, sessionID: "ses_\(index)")
    }
    #expect(try insert(rows, into: fixture.store) == rows.count)

    let outcome = try fixture.store.reprice(costing: engine, batchSize: 4)

    #expect(outcome.rowsExamined == 23)
    #expect(outcome.rowsChanged == 23)
    #expect(try fixture.costs() == Array(repeating: 300_000, count: 23))
    #expect(outcome.spendAfterUSD == MicroUSD.decimal(300_000 * 23))
    #expect(try fixture.raw.integer("SELECT request_count FROM daily") == 23)
  }

  @Test("an empty ledger reprices to nothing and still records the table")
  func handlesAnEmptyLedger() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }

    let outcome = try fixture.store.reprice(costing: CostEngine(table: repriceTable()))

    #expect(outcome.rowsExamined == 0)
    #expect(outcome.rowsChanged == 0)
    #expect(outcome.rowsUnpriced == 0)
    #expect(outcome.unpricedModels.isEmpty)
    #expect(outcome.madeNoChanges)
    #expect(outcome.spendBeforeUSD == .zero)
    #expect(outcome.spendAfterUSD == .zero)
    #expect(try fixture.store.recordedRepricePriceTableVersion() == "reprice-tests")
  }

  @Test("the recorded version says which table produced the stored costs")
  func recordsThePriceTableVersion() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let at = instant("2026-09-28T02:00:00Z")
    #expect(
      try insert(
        [record(at: at, usage: millionMissTokens, costUSD: .zero, sessionID: "ses_a")],
        into: fixture.store) == 1)
    #expect(try fixture.store.recordedRepricePriceTableVersion() == nil)

    _ = try fixture.store.reprice(costing: CostEngine(table: repriceTable(version: "first")))
    #expect(try fixture.store.recordedRepricePriceTableVersion() == "first")

    // Same prices, new version: the costs do not move, but the ledger now says which table they come
    // from, and the outcome reports what it replaced.
    let second = try fixture.store.reprice(
      costing: CostEngine(table: repriceTable(version: "second")))
    #expect(second.madeNoChanges)
    #expect(second.priceTableVersion == "second")
    #expect(second.previousPriceTableVersion == "first")
    #expect(try fixture.store.recordedRepricePriceTableVersion() == "second")
  }

  @Test("a price fixed in the table reaches rows that were stored before it")
  func aPriceChangeReachesStoredRows() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let at = instant("2026-09-28T02:00:00Z")
    let old = CostEngine(table: repriceTable())
    #expect(
      try insert(
        [
          record(
            at: at, usage: mixedTokens,
            costUSD: MicroUSD.decimal(storedCost(old, usage: mixedTokens, at: at)),
            sessionID: "ses_a")
        ], into: fixture.store) == 1)
    let before = try fixture.store.summary(since: .distantPast, until: .distantFuture)

    // The user fixes the table: the miss price doubles, which is exactly the sibling lane's alias fix
    // in miniature — an id that did not resolve now does, or resolved at the wrong price now does not.
    let corrected = CostEngine(
      table: repriceTable(version: "corrected", cacheMissUSDPerMillion: "0.60"))
    let outcome = try fixture.store.reprice(costing: corrected)

    #expect(outcome.rowsChanged == 1)
    #expect(outcome.spendBeforeUSD == before.spendUSD)
    #expect(outcome.spendAfterUSD > outcome.spendBeforeUSD)
    #expect(outcome.priceTableVersion == "corrected")
    #expect(
      try fixture.store.summary(since: .distantPast, until: .distantFuture).spendUSD
        == outcome.spendAfterUSD)
    let daily = try fixture.raw.integers("SELECT cost_micro_usd FROM daily")
    #expect(daily == [MicroUSD.fromDecimal(outcome.spendAfterUSD)])
  }

  @Test("the unpriced summary counts per model, biggest first, and writes nothing")
  func unpricedSummaryWritesNothing() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let engine = CostEngine(table: repriceTable())
    let at = instant("2026-09-28T02:00:00Z")

    #expect(
      try insert(
        [
          record(at: at, model: "ghost-a", usage: mixedTokens, costUSD: .zero, sessionID: "ses_a1"),
          record(at: at, model: "ghost-a", usage: mixedTokens, costUSD: .zero, sessionID: "ses_a2"),
          record(
            at: at, model: "ghost-b", usage: millionMissTokens, costUSD: Decimal.parse("0.05"),
            sessionID: "ses_b"),
          record(
            at: at, model: "deepseek-flash", usage: mixedTokens, costUSD: .zero, sessionID: "ses_ok"
          ),
        ], into: fixture.store) == 4)
    try fixture.countWrites()

    let summary = try fixture.store.unpricedSummary(costing: engine)

    #expect(summary.rowsExamined == 4)
    #expect(summary.rowsUnpriced == 3)
    #expect(summary.isComplete == false)
    // Two rows of ghost-a first, then ghost-b: the biggest gap is the one to fix first.
    #expect(summary.models.map { $0.model } == ["ghost-a", "ghost-b"])
    #expect(summary.models.first?.rows == 2)
    #expect(summary.models.last?.spendUSD == Decimal.parse("0.05"))
    // Nothing was written, and nothing was recorded as repriced.
    #expect(try fixture.writes() == 0)
    #expect(try fixture.costs().last == 0)
    #expect(try fixture.store.recordedRepricePriceTableVersion() == nil)
  }

  @Test("a costing that names no table records nothing and says so")
  func unnamedCostingIsNotRecorded() throws {
    let fixture = try RepriceFixture()
    defer { fixture.destroy() }
    let at = instant("2026-09-28T02:00:00Z")
    #expect(
      try insert(
        [record(at: at, usage: millionMissTokens, costUSD: .zero, sessionID: "ses_a")],
        into: fixture.store) == 1)

    let outcome = try fixture.store.reprice(costing: AnUnnamedCosting())

    #expect(outcome.rowsChanged == 1)
    #expect(outcome.priceTableVersion == "")
    #expect(try fixture.store.recordedRepricePriceTableVersion() == nil)
    #expect(try fixture.costs() == [1])
  }
}

/// A costing that prices everything at one micro-USD per row and names no table: the ledger must not
/// claim to know which table produced costs that came from somewhere else.
private struct AnUnnamedCosting: RowCosting {
  let priceTableVersion = ""
  func costIfPriced(model: String, usage: TokenUsage, at timestamp: Date) -> Decimal? {
    MicroUSD.decimal(1)
  }
}
