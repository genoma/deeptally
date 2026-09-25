// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import deeptally

/// A source that hands back canned rows, so the coverage counters are asserted without opencode.
private struct StubSource: UsageImporting {
  let source: UsageSource = .opencode
  let records: [OpenCodeImporter.ImportedRecord]

  func importAll(since: Date?) throws -> OpenCodeImporter.ImportResult {
    OpenCodeImporter.ImportResult(
      records: records, latestSeen: records.map(\.record.timestamp).max())
  }
}

/// `PricingCoverage` exists because the costing closure cannot answer "which offered rows have no
/// price": the importer calls it for candidates the union dedupes and the watermark filter drops.
@Suite("Pricing coverage")
struct PricingCoverageTests {
  @Test("a table that covers every offered model produces no warning")
  func fullyPricedIsSilent() throws {
    let coverage = coverage(records: ["deepseek-flash", "deepseek-flash"])

    _ = try coverage.importAll(since: nil)

    #expect(coverage.warning == nil)
  }

  @Test("an offered row with no price is counted, with its model named once")
  func namesUnpricedModels() throws {
    let coverage = coverage(records: [
      "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash", "deepseek-v4-flash",
    ])

    _ = try coverage.importAll(since: nil)

    let warning = try #require(coverage.warning)
    #expect(
      warning
        == "warning: 3 offered rows use a model the price table does not list (deepseek-v4-flash);"
        + " they were recorded with a cost of 0.")
  }

  @Test("one unpriced row reads as a singular sentence")
  func singularSentence() throws {
    let coverage = coverage(records: ["deepseek-v3"])

    _ = try coverage.importAll(since: nil)

    #expect(
      try #require(coverage.warning)
        == "warning: 1 offered row uses a model the price table does not list (deepseek-v3);"
        + " it was recorded with a cost of 0.")
  }

  // MARK: - Fixtures

  private func coverage(records models: [String]) -> PricingCoverage {
    PricingCoverage(wrapping: StubSource(records: models.map(record)), table: table)
  }

  private let table = PriceTable(
    version: "test",
    currency: "USD",
    effectiveFrom: "2026-09-24",
    offPeakMultiplier: Decimal(string: "0.5")!,
    peakWindowsUTC: [],
    holidays: [],
    models: [
      ModelPrice(
        model: "deepseek-flash",
        cacheHitUSDPerMillion: Decimal(string: "0.006")!,
        cacheMissUSDPerMillion: Decimal(string: "0.30")!,
        outputUSDPerMillion: Decimal(string: "1.20")!)
    ])

  private func record(model: String) -> OpenCodeImporter.ImportedRecord {
    let usage = TokenUsage(
      promptTokens: 1_000, completionTokens: 100, cacheHitTokens: 800, cacheMissTokens: 200)
    return OpenCodeImporter.ImportedRecord(
      record: UsageRecord(
        timestamp: Date(timeIntervalSince1970: 1_756_000_000),
        source: .opencode,
        provider: .deepseek,
        model: model,
        usage: usage,
        costUSD: Decimal(string: "0.001")!,
        sessionID: "s1"),
      rawHash: "hash-\(model)")
  }
}
