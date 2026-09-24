// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

/// A source that hands out canned rows, so these tests exercise the watermark and idempotence rules
/// without a fixture database. The importer's own scanning is covered in `OpenCodeImporterTests`.
private struct FakeSource: UsageImporting {
  let source: UsageSource = .opencode
  /// Rows keyed by the instant the scan is asked to resume from (`nil` = a full scan).
  var bySince: [Date?: [OpenCodeImporter.ImportedRecord]] = [:]
  var failure: (any Error)?

  func importAll(since: Date?) throws -> OpenCodeImporter.ImportResult {
    if let failure { throw failure }
    let records = bySince[since] ?? bySince[nil] ?? []
    return OpenCodeImporter.ImportResult(
      records: records,
      latestSeen: records.map(\.record.timestamp).max()
    )
  }
}

@Suite("Ledger sync")
struct LedgerSyncTests {
  private func record(
    _ iso: String,
    model: String = "deepseek-flash",
    input: Int = 1_000,
    cacheRead: Int = 750,
    output: Int = 200,
    cost: Decimal = Decimal(string: "0.001")!
  ) throws -> OpenCodeImporter.ImportedRecord {
    let timestamp = try #require(ISO8601DateFormatter().date(from: iso))
    let usage = TokenUsage(
      promptTokens: input, completionTokens: output,
      cacheHitTokens: cacheRead, cacheMissTokens: input - cacheRead)
    return OpenCodeImporter.ImportedRecord(
      record: UsageRecord(
        timestamp: timestamp, source: .opencode, provider: .deepseek, model: model,
        usage: usage, costUSD: cost, sessionID: "s1"),
      rawHash: "\(model)-\(iso)"
    )
  }

  private func withLedger(_ body: (LedgerStore) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-ledgersync-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    try body(try LedgerStore(url: url))
  }

  @Test("the first sync inserts everything and advances the watermark")
  func firstSync() throws {
    try withLedger { ledger in
      let first = try record("2026-09-24T10:00:00Z", cost: Decimal(string: "0.001")!)
      let second = try record("2026-09-24T11:00:00Z", cost: Decimal(string: "0.002")!)
      let source = FakeSource(bySince: [nil: [first, second]])
      let sync = LedgerSync(ledger: ledger, source: source)

      let outcome = try sync.sync()

      #expect(outcome.inserted == 2)
      #expect(outcome.updated == 0)
      #expect(outcome.unchanged == 0)
      #expect(outcome.offered == 2)
      #expect(outcome.wasFullScan)
      #expect(outcome.watermark == second.record.timestamp)
      #expect(try ledger.schemaVersion() == 1)

      let day = try ledger.summary(
        since: Date(timeIntervalSince1970: 0),
        until: Date(timeIntervalSince1970: 4_000_000_000))
      #expect(day.requestCount == 2)
      #expect(day.spendUSD == Decimal(string: "0.003"))
    }
  }

  @Test("a second sync inserts nothing and does not move the watermark")
  func secondSyncIsIdempotent() throws {
    try withLedger { ledger in
      let first = try record("2026-09-24T10:00:00Z")
      let second = try record("2026-09-24T11:00:00Z")
      let source = FakeSource(bySince: [nil: [first, second]])
      let sync = LedgerSync(ledger: ledger, source: source)

      _ = try sync.sync()
      let again = try sync.sync()

      // The fake answers the watermark query with the same rows, which is exactly the worst case: the
      // ledger must absorb them as duplicates rather than double-counting the spend.
      #expect(again.offered == 2)
      #expect(again.inserted == 0)
      #expect(again.updated == 0)
      #expect(again.unchanged == 2)
      #expect(again.wasFullScan == false)

      let day = try ledger.summary(
        since: Date(timeIntervalSince1970: 0),
        until: Date(timeIntervalSince1970: 4_000_000_000))
      #expect(day.requestCount == 2)
    }
  }

  @Test("a full resync adds nothing the ledger already has")
  func fullResyncIsIdempotent() throws {
    try withLedger { ledger in
      let source = FakeSource(bySince: [nil: [try record("2026-09-24T10:00:00Z")]])
      let sync = LedgerSync(ledger: ledger, source: source)

      _ = try sync.sync()
      let resync = try sync.fullResync()

      #expect(resync.wasFullScan)
      #expect(resync.offered == 1)
      #expect(resync.inserted == 0)
      #expect(resync.updated == 0)
      #expect(resync.unchanged == 1)
    }
  }

  @Test("a full resync repairs a row whose counters and cost the source rewrote")
  func fullResyncRepairsRewrittenRow() throws {
    try withLedger { ledger in
      // One source row, twice: same model and instant, so the same `rawHash`, but the second copy is
      // what opencode holds after the completion finished streaming.
      let partial = try record(
        "2026-09-24T10:00:00Z", input: 1_000, cost: Decimal(string: "0.001")!)
      let complete = try record(
        "2026-09-24T10:00:00Z", input: 4_000, cost: Decimal(string: "0.004")!)
      #expect(partial.rawHash == complete.rawHash)

      _ = try LedgerSync(ledger: ledger, source: FakeSource(bySince: [nil: [partial]])).sync()
      let resync = try LedgerSync(
        ledger: ledger, source: FakeSource(bySince: [nil: [complete]])
      ).fullResync()

      #expect(resync.wasFullScan)
      #expect(resync.offered == 1)
      #expect(resync.inserted == 0)
      #expect(resync.updated == 1)
      #expect(resync.unchanged == 0)

      // Repaired in place: one request with the source's current counters and cost, not two rows and
      // not the partial ones the first import stored.
      let day = try ledger.summary(
        since: Date(timeIntervalSince1970: 0),
        until: Date(timeIntervalSince1970: 4_000_000_000))
      #expect(day.requestCount == 1)
      #expect(day.spendUSD == Decimal(string: "0.004"))
      #expect(day.promptTokens == 4_000)

      // The repair is what the ledger now holds, so the next resync changes nothing at all.
      let again = try LedgerSync(
        ledger: ledger, source: FakeSource(bySince: [nil: [complete]])
      ).fullResync()
      #expect(again.inserted == 0)
      #expect(again.updated == 0)
      #expect(again.unchanged == 1)
      #expect(
        try ledger.summary(
          since: Date(timeIntervalSince1970: 0),
          until: Date(timeIntervalSince1970: 4_000_000_000)) == day)
    }
  }

  @Test("the watermark never moves backwards")
  func watermarkIsMonotonic() throws {
    try withLedger { ledger in
      let newer = try record("2026-09-24T12:00:00Z")
      let older = try record("2026-09-24T09:00:00Z")
      let sync = LedgerSync(ledger: ledger, source: FakeSource(bySince: [nil: [newer]]))

      let first = try sync.sync()
      #expect(first.watermark == newer.record.timestamp)

      // A repair pass that legitimately sees an older maximum must not rewind the watermark; rewinding
      // would make every later incremental scan re-offer rows the ledger already has.
      let repair = LedgerSync(ledger: ledger, source: FakeSource(bySince: [nil: [older]]))
      let second = try repair.fullResync()

      #expect(second.inserted == 1)
      #expect(second.watermark == newer.record.timestamp)
      #expect(try ledger.importWatermark(for: .opencode) == newer.record.timestamp)
    }
  }

  @Test("a failing source writes nothing at all")
  func failureWritesNothing() throws {
    try withLedger { ledger in
      struct Boom: Error {}
      let sync = LedgerSync(
        ledger: ledger,
        source: FakeSource(bySince: [nil: [try record("2026-09-24T10:00:00Z")]], failure: Boom()))

      #expect(throws: Boom.self) { try sync.sync() }
      #expect(try ledger.importWatermark(for: .opencode) == nil)

      let day = try ledger.summary(
        since: Date(timeIntervalSince1970: 0),
        until: Date(timeIntervalSince1970: 4_000_000_000))
      #expect(day.requestCount == 0)
    }
  }
}
