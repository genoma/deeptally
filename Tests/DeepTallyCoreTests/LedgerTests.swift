// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3
import Testing

@testable import DeepTallyCore

// MARK: - Fixtures

/// A ledger in a throwaway folder. Every test gets its own file under `temporaryDirectory`, so the
/// suite can run in parallel and never touches the developer's real ledger.
private final class LedgerFixture {
  let directory: URL
  let url: URL
  let store: LedgerStore

  init(busyTimeout: TimeInterval = 5) throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-ledger-tests-\(UUID().uuidString)")
    // Nested on purpose: opening the ledger has to create the folders too.
    url = directory.appending(path: "Application Support/DeepTally/ledger.sqlite")
    store = try LedgerStore(url: url, busyTimeout: busyTimeout)
  }

  /// A second store on the same file, which is what "reopen" means for the app and the CLI.
  func reopen(busyTimeout: TimeInterval = 5) throws -> LedgerStore {
    try LedgerStore(url: url, busyTimeout: busyTimeout)
  }

  func destroy() {
    try? FileManager.default.removeItem(at: directory)
  }
}

/// A failure in a test's own sqlite plumbing, never in the code under test.
private struct LedgerFixtureError: Error {
  let message: String
}

/// A second, plain connection to the same file. The store exposes only what a caller needs, so the
/// tests look at `daily`, delete a row or take the write lock through sqlite directly.
private final class RawLedger {
  private var handle: OpaquePointer?

  init(url: URL) throws {
    var opened: OpaquePointer?
    let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE, nil)
    guard code == SQLITE_OK, let database = opened else {
      let reason = opened.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
      if let opened { _ = sqlite3_close(opened) }
      throw LedgerFixtureError(message: "could not open \(url.path): \(reason)")
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
      throw LedgerFixtureError(message: "\(detail) while running: \(sql)")
    }
  }

  /// The first column of every row, rendered as text. Enough for counts, dumps and pragmas.
  func strings(_ sql: String) throws -> [String] {
    var statement: OpaquePointer?
    let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard prepare == SQLITE_OK, let prepared = statement else {
      throw LedgerFixtureError(message: "could not prepare: \(sql)")
    }
    defer { _ = sqlite3_finalize(prepared) }

    var values: [String] = []
    while true {
      let step = sqlite3_step(prepared)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw LedgerFixtureError(message: "could not read: \(sql)")
      }
      if let bytes = sqlite3_column_text(prepared, 0) {
        let count = Int(sqlite3_column_bytes(prepared, 0))
        values.append(
          String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
      } else {
        values.append("")
      }
    }
    return values
  }
}

/// One `daily` row per line, and the same shape for the aggregate it must equal.
private let dailyDump = """
  SELECT date || '|' || provider || '|' || model || '|' || input || '|' || output || '|'
         || reasoning || '|' || cache_read || '|' || cost_micro_usd || '|' || request_count
    FROM daily ORDER BY date, provider, model
  """

private let requestAggregateDump = """
  SELECT date(ts, 'unixepoch') || '|' || provider || '|' || model || '|' || SUM(input) || '|'
         || SUM(output) || '|' || SUM(reasoning) || '|' || SUM(cache_read) || '|'
         || SUM(cost_micro_usd) || '|' || COUNT(*)
    FROM request GROUP BY date(ts, 'unixepoch'), provider, model
   ORDER BY date(ts, 'unixepoch'), provider, model
  """

private let allTime = (since: Date.distantPast, until: Date.distantFuture)

private func instant(_ iso8601: String) -> Date {
  let formatter = ISO8601DateFormatter()
  guard let date = formatter.date(from: iso8601) else {
    preconditionFailure("invalid fixture instant: \(iso8601)")
  }
  return date
}

/// The shipped flash prices, in a table small enough to compute by hand. 2026-09-28 is a Monday, so
/// 02:00 UTC is inside the 01:00–04:00 peak window and 12:00 UTC is off-peak.
private func fixturePriceTable() -> PriceTable {
  PriceTable(
    version: "ledger-tests",
    currency: "USD",
    effectiveFrom: "2026-09-24",
    offPeakMultiplier: Decimal.parse("0.5"),
    peakWindowsUTC: [PeakWindow(startHourUTC: 1, endHourUTC: 4)],
    holidays: [],
    models: [
      ModelPrice(
        model: "deepseek-flash",
        cacheHitUSDPerMillion: Decimal.parse("0.006"),
        cacheMissUSDPerMillion: Decimal.parse("0.30"),
        outputUSDPerMillion: Decimal.parse("1.20")
      )
    ]
  )
}

/// 500k cached prompt tokens, 250k uncached, 100k completion of which 20k is reasoning.
private let handComputedUsage = TokenUsage(
  promptTokens: 750_000,
  completionTokens: 100_000,
  cacheHitTokens: 500_000,
  cacheMissTokens: 250_000,
  reasoningTokens: 20_000
)

private func record(
  at timestamp: Date,
  provider: Provider = .deepseek,
  model: String = "deepseek-flash",
  usage: TokenUsage,
  costUSD: Decimal,
  sessionID: String
) -> UsageRecord {
  UsageRecord(
    timestamp: timestamp,
    source: .opencode,
    provider: provider,
    model: model,
    usage: usage,
    costUSD: costUSD,
    sessionID: sessionID
  )
}

private func simpleRecord(
  at timestamp: Date,
  provider: Provider = .deepseek,
  model: String = "deepseek-flash",
  costUSD: Decimal = Decimal.parse("0.01"),
  sessionID: String
) -> UsageRecord {
  record(
    at: timestamp,
    provider: provider,
    model: model,
    usage: TokenUsage(
      promptTokens: 1_000, completionTokens: 100, cacheHitTokens: 800, cacheMissTokens: 200,
      reasoningTokens: 0),
    costUSD: costUSD,
    sessionID: sessionID
  )
}

// MARK: - Schema

@Suite("Ledger schema")
struct LedgerSchemaTests {
  @Test("creates the folder, the file and the v1 schema on first open")
  func createsSchemaOnEmptyFile() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    #expect(FileManager.default.fileExists(atPath: fixture.url.path))
    #expect(fixture.store.url == fixture.url)
    #expect(try fixture.store.schemaVersion() == 1)
    #expect(fixture.store.appliedMigrationVersions == [1])

    let raw = try RawLedger(url: fixture.url)
    // WAL is a property of the file, so a second connection sees it; `synchronous` and
    // `foreign_keys` are per-connection and are not observable from here.
    #expect(try raw.strings("PRAGMA journal_mode") == ["wal"])
    #expect(
      try raw.strings("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        == ["daily", "meta", "request"])
    #expect(try raw.strings("SELECT value FROM meta WHERE key = 'schema_version'") == ["1"])
    let requestDDL = try #require(
      try raw.strings("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'request'")
        .first)
    #expect(requestDDL.contains("raw_hash TEXT UNIQUE"))
    #expect(requestDDL.contains("cost_micro_usd INTEGER NOT NULL"))
    #expect(requestDDL.contains("ts INTEGER NOT NULL"))
  }

  @Test("reopening an existing ledger preserves rows and does not re-run v1")
  func reopeningPreservesRows() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(at: instant("2026-09-28T02:00:00Z"), sessionID: "ses_a"),
      simpleRecord(at: instant("2026-09-28T12:00:00Z"), sessionID: "ses_b"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 2)
    let before = try fixture.store.summary(since: allTime.since, until: allTime.until)

    let reopened = try fixture.reopen()
    #expect(reopened.appliedMigrationVersions.isEmpty)
    #expect(try reopened.schemaVersion() == 1)
    #expect(try reopened.summary(since: allTime.since, until: allTime.until) == before)
    #expect(try reopened.insert(records) { $0.sessionID ?? "" } == 0)
  }

  @Test("a later migration applies without losing data, and a downgrade is refused")
  func migrationRunnerAppliesLaterVersions() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    #expect(
      try fixture.store.insert([
        simpleRecord(at: instant("2026-09-28T02:00:00Z"), sessionID: "ses_a")
      ]) { $0.sessionID ?? "" } == 1)

    let second = LedgerStore.Migration(
      version: 2,
      statements: [
        "ALTER TABLE request ADD COLUMN note TEXT",
        "INSERT INTO meta(key, value) VALUES ('v2_marker', 'yes')",
      ])
    let upgraded = try LedgerStore(url: fixture.url, migrations: LedgerStore.migrations + [second])
    #expect(upgraded.appliedMigrationVersions == [2])
    #expect(try upgraded.schemaVersion() == 2)
    #expect(
      try RawLedger(url: fixture.url).strings("SELECT value FROM meta WHERE key = 'v2_marker'")
        == ["yes"])
    #expect(try upgraded.summary(since: allTime.since, until: allTime.until).requestCount == 1)
    // Reopening at v2 with the same migration list applies nothing again.
    let current = try LedgerStore(url: fixture.url, migrations: LedgerStore.migrations + [second])
    #expect(current.appliedMigrationVersions.isEmpty)
    #expect(try current.schemaVersion() == 2)

    // A build that only knows v1 must refuse rather than write an old schema over new data.
    #expect(throws: LedgerError.unsupportedSchemaVersion(found: 2, supported: 1)) {
      try LedgerStore(url: fixture.url, migrations: LedgerStore.migrations)
    }
  }
}

// MARK: - Writes, summaries, rollups

@Suite("Ledger writes and summaries")
struct LedgerWriteTests {
  @Test("inserting the same records twice stores them once and leaves the summary unchanged")
  func insertsAreIdempotent() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(at: instant("2026-09-27T22:00:00Z"), sessionID: "ses_a"),
      simpleRecord(at: instant("2026-09-28T02:00:00Z"), sessionID: "ses_b"),
      simpleRecord(
        at: instant("2026-09-28T03:00:00Z"), model: "deepseek-v4-pro", sessionID: "ses_c"),
    ]
    let key: (UsageRecord) -> String = { $0.sessionID ?? "" }

    #expect(try fixture.store.insert(records, rawHash: key) == 3)
    let first = try fixture.store.summary(since: allTime.since, until: allTime.until)
    #expect(first.requestCount == 3)

    #expect(try fixture.store.insert(records, rawHash: key) == 0)
    #expect(try fixture.store.summary(since: allTime.since, until: allTime.until) == first)

    let raw = try RawLedger(url: fixture.url)
    #expect(try raw.strings("SELECT COUNT(*) FROM request") == ["3"])
    // Idempotent in the rollup too, not just in the raw rows.
    #expect(try raw.strings(dailyDump) == (try raw.strings(requestAggregateDump)))
  }

  @Test("an upsert repairs counters and cost, and an identical record writes nothing at all")
  func upsertRepairsAndIsIdempotent() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let at = instant("2026-09-28T02:00:00Z")
    let key = "hash_rewritten_row"
    // Stored while the completion was still streaming: a partial counter and the partial cost that
    // follows from it.
    let partial = record(
      at: at,
      usage: TokenUsage(
        promptTokens: 100, completionTokens: 10, cacheHitTokens: 0, cacheMissTokens: 100),
      costUSD: Decimal.parse("0.00003"),
      sessionID: "ses_rewritten")
    #expect(
      try fixture.store.upsert([(record: partial, rawHash: key)])
        == UpsertOutcome(inserted: 1, updated: 0, unchanged: 0))

    // The same source row after opencode finished: more tokens, and the cost that follows from them.
    let complete = record(
      at: at,
      usage: TokenUsage(
        promptTokens: 1_000, completionTokens: 100, cacheHitTokens: 700, cacheMissTokens: 300),
      costUSD: Decimal.parse("0.00042"),
      sessionID: "ses_rewritten")
    #expect(
      try fixture.store.upsert([(record: complete, rawHash: key)])
        == UpsertOutcome(inserted: 0, updated: 1, unchanged: 0))

    // Repaired in place: one request, the new counters, the new cost.
    let summary = try fixture.store.summary(since: allTime.since, until: allTime.until)
    #expect(summary.requestCount == 1)
    #expect(summary.spendUSD == Decimal.parse("0.00042"))
    #expect(summary.inputTokens == 300)
    #expect(summary.cacheReadTokens == 700)
    #expect(summary.outputTokens == 100)

    let raw = try RawLedger(url: fixture.url)
    // The repair landed in the rollup too, and the row's own instant was not restated.
    #expect(try raw.strings(dailyDump) == (try raw.strings(requestAggregateDump)))
    #expect(
      try raw.strings("SELECT ts FROM request WHERE raw_hash = '\(key)'")
        == ["\(Int64(at.timeIntervalSince1970))"])

    // A re-offered record with the same counters must be absorbed without a single write.
    try raw.execute("CREATE TABLE write_log(writes INTEGER NOT NULL)")
    try raw.execute("INSERT INTO write_log VALUES (0)")
    try raw.execute(
      """
      CREATE TRIGGER log_request_write AFTER UPDATE ON request
      BEGIN UPDATE write_log SET writes = writes + 1; END
      """)
    let again = try fixture.store.upsert([(record: complete, rawHash: key)])
    #expect(again == UpsertOutcome(inserted: 0, updated: 0, unchanged: 1))
    #expect(try raw.strings("SELECT writes FROM write_log") == ["0"])
    #expect(try fixture.store.summary(since: allTime.since, until: allTime.until) == summary)
  }

  @Test("an offered record with the same counters leaves a stored cost alone")
  func upsertLeavesCostAloneWhenCountersMatch() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let at = instant("2026-09-28T02:00:00Z")
    let key = "hash_cost_only"
    let usage = TokenUsage(
      promptTokens: 1_000, completionTokens: 100, cacheHitTokens: 700, cacheMissTokens: 300)
    // Stored with one cost...
    #expect(
      try fixture.store.upsert([
        (
          record: record(
            at: at, usage: usage, costUSD: Decimal.parse("0.001"), sessionID: "ses_cost"),
          rawHash: key
        )
      ]) == UpsertOutcome(inserted: 1, updated: 0, unchanged: 0))

    // ...and re-offered with the same counters and another cost. Repairing money is `reprice`'s job,
    // so the import must not restate it: a resync that repriced history whenever the table changed
    // could not answer "what did this import change?".
    #expect(
      try fixture.store.upsert([
        (
          record: record(
            at: at, usage: usage, costUSD: Decimal.parse("0.002"), sessionID: "ses_cost"),
          rawHash: key
        )
      ]) == UpsertOutcome(inserted: 0, updated: 0, unchanged: 1))
    #expect(
      try fixture.store.summary(since: allTime.since, until: allTime.until).spendUSD
        == Decimal.parse("0.001"))
  }

  @Test("a write rebuilds only the days its batch touched; the full rebuild still repairs all")
  func writeRebuildsOnlyTouchedDays() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let dayOne = instant("2026-09-27T22:00:00Z")
    let dayTwo = instant("2026-09-28T02:00:00Z")
    let dayThree = instant("2026-09-29T02:00:00Z")
    #expect(
      try fixture.store.insert([
        simpleRecord(at: dayOne, costUSD: Decimal.parse("0.01"), sessionID: "ses_1"),
        simpleRecord(at: dayTwo, costUSD: Decimal.parse("0.02"), sessionID: "ses_2"),
      ]) { $0.sessionID ?? "" } == 2)

    let raw = try RawLedger(url: fixture.url)
    #expect(try raw.strings(dailyDump) == (try raw.strings(requestAggregateDump)))

    // Stand in for a rollup that drifted: a whole-table rebuild would refresh this day, a
    // day-restricted one must not touch it.
    try raw.execute(
      "UPDATE daily SET cost_micro_usd = 999999, request_count = 99 WHERE date = '2026-09-27'")

    // A row on a third day: its own day is recomputed...
    #expect(
      try fixture.store.insert([
        simpleRecord(at: dayThree, costUSD: Decimal.parse("0.03"), sessionID: "ses_3")
      ]) { $0.sessionID ?? "" } == 1)
    let daily = try raw.strings(dailyDump)
    #expect(daily.contains { $0.hasPrefix("2026-09-29|") && $0.hasSuffix("|30000|1") })
    // ...and the untouched day keeps whatever it had, which is the point of the restriction.
    #expect(daily.contains { $0.hasPrefix("2026-09-27|") && $0.hasSuffix("|999999|99") })

    // The explicit whole-table rebuild is the repair for a rollup that drifted; it restores the day.
    try fixture.store.rebuildDailyRollups()
    #expect(try raw.strings(dailyDump) == (try raw.strings(requestAggregateDump)))
    #expect(try raw.strings(dailyDump).count == 3)
  }

  @Test("an empty rawHash is refused instead of silently disabling dedupe")
  func emptyRawHashIsRefused() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(at: instant("2026-09-28T02:00:00Z"), sessionID: "ses_a"),
      simpleRecord(at: instant("2026-09-28T03:00:00Z"), sessionID: "ses_b"),
    ]
    #expect(throws: LedgerError.emptyRawHash(row: 1)) {
      try fixture.store.insert(records) { $0.sessionID == "ses_a" ? "hash_a" : "" }
    }
    // The refusal happens before the transaction, so nothing was written.
    #expect(try RawLedger(url: fixture.url).strings("SELECT COUNT(*) FROM request") == ["0"])

    #expect(throws: LedgerError.emptyRawHash(row: 0)) {
      try fixture.store.insert([(record: records[0], rawHash: "")])
    }
  }

  @Test("a hand-computed peak and off-peak pair adds up exactly")
  func handComputedCostIsExact() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let engine = CostEngine(table: fixturePriceTable())
    let peak = instant("2026-09-28T02:00:00Z")
    let offPeak = instant("2026-09-28T12:00:00Z")
    // Non-vacuity: the two instants really are classified differently.
    #expect(engine.peakOffPeak.classify(peak).period == .peak)
    #expect(engine.peakOffPeak.classify(offPeak).period == .offPeak)

    // Peak: 0.5 × $0.006 + 0.25 × $0.30 + 0.1 × $1.20 = 0.003 + 0.075 + 0.12 = $0.198
    // Off-peak is exactly half of that: $0.099.
    let peakRecord = record(
      at: peak, usage: handComputedUsage,
      costUSD: engine.cost(model: "deepseek-flash", usage: handComputedUsage, at: peak),
      sessionID: "ses_peak")
    let offPeakRecord = record(
      at: offPeak, usage: handComputedUsage,
      costUSD: engine.cost(model: "deepseek-flash", usage: handComputedUsage, at: offPeak),
      sessionID: "ses_off")
    #expect(peakRecord.costUSD == Decimal.parse("0.198"))
    #expect(offPeakRecord.costUSD == Decimal.parse("0.099"))

    #expect(try fixture.store.insert([peakRecord, offPeakRecord]) { $0.sessionID ?? "" } == 2)

    let summary = try fixture.store.summary(
      since: instant("2026-09-28T00:00:00Z"), until: instant("2026-09-29T00:00:00Z"))
    #expect(summary.spendUSD == Decimal.parse("0.297"))
    #expect(summary.requestCount == 2)
    #expect(summary.models.count == 1)

    let flash = try #require(summary.models.first)
    #expect(flash.provider == .deepseek)
    #expect(flash.model == "deepseek-flash")
    #expect(flash.spendUSD == Decimal.parse("0.297"))
    // Both rows are the same model, so every counter doubles.
    #expect(flash.inputTokens == 500_000)
    #expect(flash.cacheWriteTokens == 0)
    #expect(flash.cacheReadTokens == 1_000_000)
    #expect(flash.outputTokens == 160_000)
    #expect(flash.reasoningTokens == 40_000)
    #expect(flash.promptTokens == 1_500_000)
    #expect(flash.cacheHitRatio == 1_000_000.0 / 1_500_000.0)
    #expect(summary.cacheHitRatio == flash.cacheHitRatio)

    // The peak record keeps the peak price: cost is a property of the row, not of the import.
    #expect(
      try fixture.store.summary(since: peak, until: peak.addingTimeInterval(1)).spendUSD
        == Decimal.parse("0.198"))
    #expect(
      try fixture.store.summary(since: offPeak, until: offPeak.addingTimeInterval(1)).spendUSD
        == Decimal.parse("0.099"))
  }

  @Test("a summary with no prompt tokens reports no cache-hit ratio instead of zero")
  func cacheRatioIsNilWithoutPromptTokens() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let completionOnly = UsageRecord(
      timestamp: instant("2026-09-28T02:00:00Z"),
      source: .csv,
      provider: .deepseek,
      model: "deepseek-flash",
      usage: TokenUsage(
        promptTokens: 0, completionTokens: 10, cacheHitTokens: 0, cacheMissTokens: 0),
      costUSD: Decimal.parse("0.000012"),
      sessionID: "ses_completion_only"
    )
    #expect(try fixture.store.insert([completionOnly]) { $0.sessionID ?? "" } == 1)

    let summary = try fixture.store.summary(since: allTime.since, until: allTime.until)
    #expect(summary.requestCount == 1)
    #expect(summary.promptTokens == 0)
    #expect(summary.cacheHitRatio == nil)
    #expect(summary.models.first?.cacheHitRatio == nil)
  }

  @Test("the summary filters by provider and by time range")
  func summaryFilters() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(at: instant("2026-09-28T02:00:00Z"), provider: .deepseek, sessionID: "ses_d1"),
      simpleRecord(at: instant("2026-09-28T03:00:00Z"), provider: .kilo, sessionID: "ses_k1"),
      simpleRecord(at: instant("2026-09-29T02:00:00Z"), provider: .deepseek, sessionID: "ses_d2"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 3)

    let deepseek = try fixture.store.summary(
      since: allTime.since, until: allTime.until, provider: .deepseek)
    #expect(deepseek.requestCount == 2)
    #expect(deepseek.models.map(\.model) == ["deepseek-flash"])

    let oneDay = try fixture.store.summary(
      since: instant("2026-09-28T00:00:00Z"), until: instant("2026-09-29T00:00:00Z"))
    #expect(oneDay.requestCount == 2)
    // Half-open: the row exactly at `since` counts, the one exactly at `until` does not.
    #expect(
      try fixture.store.summary(
        since: instant("2026-09-29T02:00:00Z"), until: instant("2026-09-29T02:00:00Z")
      ).requestCount == 0)
    #expect(
      (try fixture.store.summary(
        since: instant("2026-09-29T02:00:00Z"), until: instant("2026-09-29T02:00:01Z")
      )).requestCount == 1)

    // Order is by provider then model, independent of the amounts.
    let all = try fixture.store.summary(since: allTime.since, until: allTime.until)
    #expect(all.models.map(\.provider) == [.deepseek, .kilo])
  }

  @Test("daily rollups equal a direct aggregate over request, and rebuilding twice changes nothing")
  func rollupsMatchDirectAggregate() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(
        at: instant("2026-09-27T22:00:00Z"), provider: .deepseek, costUSD: Decimal.parse("0.01"),
        sessionID: "ses_a"),
      simpleRecord(
        at: instant("2026-09-27T23:59:59Z"), provider: .deepseek, costUSD: Decimal.parse("0.02"),
        sessionID: "ses_b"),
      simpleRecord(
        at: instant("2026-09-28T02:00:00Z"), provider: .kilo, model: "kilo-auto",
        costUSD: Decimal.parse("0.03"), sessionID: "ses_c"),
      simpleRecord(
        at: instant("2026-09-28T03:00:00Z"), provider: .deepseek, costUSD: Decimal.parse("0.04"),
        sessionID: "ses_d"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 4)

    let raw = try RawLedger(url: fixture.url)
    let original = try raw.strings(dailyDump)
    #expect(original.count == 3)  // (27th, deepseek), (28th, deepseek), (28th, kilo)
    #expect(original == (try raw.strings(requestAggregateDump)))

    try fixture.store.rebuildDailyRollups()
    #expect(try raw.strings(dailyDump) == original)
    try fixture.store.rebuildDailyRollups()
    #expect(try raw.strings(dailyDump) == original)
  }

  @Test("prune drops whole UTC days of raw rows and leaves the rollups holding their totals")
  func pruneKeepsRollups() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let old = instant("2025-08-10T09:00:00Z")
    let recent = instant("2026-09-20T09:00:00Z")
    let records = [
      simpleRecord(at: old, costUSD: Decimal.parse("1.50"), sessionID: "ses_old"),
      simpleRecord(at: recent, costUSD: Decimal.parse("0.25"), sessionID: "ses_recent"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 2)

    let raw = try RawLedger(url: fixture.url)
    let dailyBefore = try raw.strings(dailyDump)
    #expect(dailyBefore.count == 2)

    #expect(
      try fixture.store.pruneRawRequests(olderThanDays: 40, now: instant("2026-09-28T12:00:00Z"))
        == 1)
    #expect(try raw.strings("SELECT COUNT(*) FROM request") == ["1"])
    // The pruned day's totals survive in the rollup, and a rebuild does not drop them.
    #expect(try raw.strings(dailyDump) == dailyBefore)
    try fixture.store.rebuildDailyRollups()
    #expect(try raw.strings(dailyDump) == dailyBefore)

    // What is gone is the raw-row view of that day.
    #expect(try fixture.store.summary(since: old, until: recent).requestCount == 0)
    #expect(
      try fixture.store.summary(
        since: recent, until: instant("2026-09-21T00:00:00Z")
      ).spendUSD == Decimal.parse("0.25"))
  }

  @Test("the prune cutoff is floored to a UTC day so a day is never half-pruned")
  func pruneCutoffIsDayFloored() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(at: instant("2026-09-26T23:00:00Z"), sessionID: "ses_before"),
      simpleRecord(at: instant("2026-09-27T00:30:00Z"), sessionID: "ses_on_cutoff_day"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 2)

    // `now` is 12:00 on the 28th, so one day back floors to 2026-09-27T00:00Z.
    #expect(
      try fixture.store.pruneRawRequests(olderThanDays: 1, now: instant("2026-09-28T12:00:00Z"))
        == 1)
    let raw = try RawLedger(url: fixture.url)
    #expect(try raw.strings("SELECT COUNT(*) FROM request") == ["1"])
    let kept = Int64(instant("2026-09-27T00:30:00Z").timeIntervalSince1970)
    #expect(try raw.strings("SELECT ts FROM request") == ["\(kept)"])
  }

  @Test(
    "a CSV export imported into a fresh ledger reproduces the summary, and a second import is a no-op"
  )
  func csvRoundTrips() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(at: instant("2026-09-27T22:00:00Z"), provider: .deepseek, sessionID: "ses_a"),
      // A comma in a session id has to be quoted, or the columns shift.
      record(
        at: instant("2026-09-28T02:00:00Z"), provider: .kilo, model: "kilo-auto",
        usage: TokenUsage(
          promptTokens: 2_000, completionTokens: 200, cacheHitTokens: 1_500, cacheMissTokens: 500,
          reasoningTokens: 50),
        costUSD: Decimal.parse("0.000789"), sessionID: "ses_with,comma"),
      record(
        at: instant("2026-09-28T03:00:00Z"), provider: .deepseek, model: "deepseek-v4-pro",
        usage: TokenUsage(
          promptTokens: 3_000, completionTokens: 400, cacheHitTokens: 0, cacheMissTokens: 3_000),
        costUSD: Decimal.parse("0.123456"), sessionID: "ses_c"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 3)
    let before = try fixture.store.summary(since: allTime.since, until: allTime.until)

    let csvURL = fixture.directory.appending(path: "export/ledger.csv")
    // The export writes one file at a path whose folder must already exist; the caller owns that.
    try FileManager.default.createDirectory(
      at: csvURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fixture.store.exportCSV(to: csvURL)

    let text = try String(contentsOf: csvURL, encoding: .utf8)
    #expect(
      text.hasPrefix(
        "ts,source,provider,model,input,output,reasoning,cache_read,cache_write,cost_usd,session_id,raw_hash\n"
      ))
    #expect(text.contains("\"ses_with,comma\""))

    let fresh = try LedgerFixture()
    defer { fresh.destroy() }
    #expect(try fresh.store.importCSV(from: csvURL) == 3)
    let after = try fresh.store.summary(since: allTime.since, until: allTime.until)
    #expect(after == before)
    // Costs survive to the micro-dollar: 0.123456 exports and re-imports without drift.
    #expect(after.spendUSD == before.spendUSD)

    #expect(try fresh.store.importCSV(from: csvURL) == 0)
    #expect(try fresh.store.summary(since: allTime.since, until: allTime.until) == after)
  }

  @Test("a malformed CSV row is reported with its line and leaves the ledger untouched")
  func malformedCSVIsReported() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }
    let csvURL = fixture.directory.appending(path: "broken.csv")

    let header = LedgerCSV.headerLine
    let goodRow = "1787878800,opencode,deepseek,deepseek-flash,10,20,0,30,0,0.000123,ses_ok,hash_ok"

    // 1: an unparsable timestamp on the third line.
    try write(
      "\(header)\n\(goodRow)\nyesterday,opencode,deepseek,deepseek-flash,10,20,0,30,0,0.0001,ses,hash\n",
      to: csvURL)
    var error = #expect(throws: LedgerError.self) { try fixture.store.importCSV(from: csvURL) }
    guard case .malformedCSV(let line, let reason) = error else {
      Issue.record("expected a malformedCSV error, got \(String(describing: error))")
      return
    }
    #expect(line == 3)
    #expect(reason.contains("ts"))
    #expect(try RawLedger(url: fixture.url).strings("SELECT COUNT(*) FROM request") == ["0"])

    // 2: a missing dedupe key is malformed, not a row that counts twice.
    try write(
      "\(header)\n1787878800,opencode,deepseek,deepseek-flash,10,20,0,30,0,0.000123,ses_ok,\n",
      to: csvURL)
    error = #expect(throws: LedgerError.self) { try fixture.store.importCSV(from: csvURL) }
    guard case .malformedCSV(let line, let reason) = error else {
      Issue.record("expected a malformedCSV error, got \(String(describing: error))")
      return
    }
    #expect(line == 2)
    #expect(reason.contains("raw_hash"))

    // 3: an unterminated quote must not silently swallow the rest of the file.
    try write("\(header)\n\(goodRow)\n1,opencode,deepseek,\"unclosed\n", to: csvURL)
    error = #expect(throws: LedgerError.self) { try fixture.store.importCSV(from: csvURL) }
    guard case .malformedCSV(let line, let reason) = error else {
      Issue.record("expected a malformedCSV error, got \(String(describing: error))")
      return
    }
    #expect(line == 3)
    #expect(reason.contains("never closed"))

    // 4: a file with no header at all.
    try write("", to: csvURL)
    error = #expect(throws: LedgerError.self) { try fixture.store.importCSV(from: csvURL) }
    guard case .malformedCSV(let line, _) = error else {
      Issue.record("expected a malformedCSV error, got \(String(describing: error))")
      return
    }
    #expect(line == 1)

    #expect(try RawLedger(url: fixture.url).strings("SELECT COUNT(*) FROM request") == ["0"])
  }

  @Test("importing a file that is not there reports the path")
  func missingCSVIsReported() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }
    let missing = fixture.directory.appending(path: "nope.csv")

    #expect(throws: LedgerError.fileMissing(path: missing.path)) {
      try fixture.store.importCSV(from: missing)
    }
  }
}

// MARK: - Concurrency

@Suite("Ledger locking")
struct LedgerLockingTests {
  @Test("a write while another connection holds the lock reports .busy, and reads keep working")
  func busyLedgerReportsBusy() throws {
    let fixture = try LedgerFixture(busyTimeout: 0.05)
    defer { fixture.destroy() }

    let first = simpleRecord(at: instant("2026-09-28T02:00:00Z"), sessionID: "ses_a")
    #expect(try fixture.store.insert([first]) { $0.sessionID ?? "" } == 1)

    let raw = try RawLedger(url: fixture.url)
    try raw.execute("BEGIN IMMEDIATE")
    // WAL: a reader is never blocked by a writer.
    #expect(try fixture.store.summary(since: allTime.since, until: allTime.until).requestCount == 1)

    // Every write path reports the lock instead of trapping, however often it is tried.
    let second = simpleRecord(at: instant("2026-09-28T03:00:00Z"), sessionID: "ses_b")
    for _ in 0..<5 {
      let error = #expect(throws: LedgerError.self) {
        try fixture.store.insert([second]) { $0.sessionID ?? "" }
      }
      #expect(error == .busy)
    }
    #expect(throws: LedgerError.busy) { try fixture.store.rebuildDailyRollups() }
    #expect(throws: LedgerError.busy) { try fixture.store.pruneRawRequests(olderThanDays: 400) }
    // A rejected write is now also a rejected transaction: a later read sees one row, not two.
    #expect(try fixture.store.summary(since: allTime.since, until: allTime.until).requestCount == 1)

    // The failed write left nothing behind and the store is still usable.
    try raw.execute("ROLLBACK")
    #expect(try fixture.store.insert([second]) { $0.sessionID ?? "" } == 1)
    #expect(try fixture.store.summary(since: allTime.since, until: allTime.until).requestCount == 2)
  }
}

// MARK: - Watermarks

@Suite("Ledger watermarks")
struct LedgerWatermarkTests {
  @Test("the watermark round-trips through meta, is per source, and never moves backwards")
  func watermarkRoundTrips() throws {
    let fixture = try LedgerFixture()
    defer { fixture.destroy() }
    let raw = try RawLedger(url: fixture.url)

    #expect(try fixture.store.importWatermark(for: .opencode) == nil)

    // Stored as epoch milliseconds in `meta`, not as a local date and not as a whole second.
    let metaKey = "'import_watermark.opencode'"
    let newest = instant("2026-09-28T12:00:00Z")
    try fixture.store.recordImportWatermark(newest, for: .opencode)
    let expectedMilliseconds = Int64((newest.timeIntervalSince1970 * 1_000).rounded())
    #expect(
      try raw.strings("SELECT value FROM meta WHERE key = \(metaKey)")
        == ["\(expectedMilliseconds)"])
    let stored = try #require(try fixture.store.importWatermark(for: .opencode))
    #expect(stored == newest)

    // Milliseconds survive: whole-second storage would show up as a 123 ms error below.
    let subSecond = newest.addingTimeInterval(1_234.123)
    try fixture.store.recordImportWatermark(subSecond, for: .opencode)
    let withMillis = try #require(try fixture.store.importWatermark(for: .opencode))
    #expect(abs(withMillis.timeIntervalSince1970 - subSecond.timeIntervalSince1970) < 0.001)

    // A stale import must not rewind the watermark.
    try fixture.store.recordImportWatermark(subSecond.addingTimeInterval(-600), for: .opencode)
    #expect(try fixture.store.importWatermark(for: .opencode) == withMillis)

    // A different source keeps its own.
    #expect(try fixture.store.importWatermark(for: .proxy) == nil)
    try fixture.store.recordImportWatermark(newest, for: .proxy)
    #expect(try fixture.store.importWatermark(for: .opencode) == withMillis)
    #expect(try fixture.store.importWatermark(for: .proxy) == newest)

    // And it is on disk, not in memory.
    let reopened = try fixture.reopen()
    #expect(try reopened.importWatermark(for: .opencode) == withMillis)
  }
}

private func write(_ text: String, to url: URL) throws {
  try Data(text.utf8).write(to: url)
}
