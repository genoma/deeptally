// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The CSV transfer surfaced in the popover: the file that comes out, the rows that go back in, the
/// sentences the section shows, and the one thing a failed transfer must never do — touch the ledger.
@Suite("Ledger CSV transfer", .serialized)
@MainActor
struct LedgerTransferTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.transfer"

  /// A fresh directory under the system temporary directory: the panels are bypassed, so the test
  /// owns the paths and the directories they need.
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-transfer-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// One importable row on the fixture's clock, so it falls inside the fixture's local (UTC) day.
  private func record(in fixture: AppModelFixture, cost: String) -> OpenCodeImporter.ImportedRecord
  {
    importedRecord(at: fixture.clock.now, costUSD: decimal(cost))
  }

  @Test("an export writes the header and every stored row, and says how many")
  func exportWritesEveryRow() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([
        record(in: fixture, cost: "0.42"), record(in: fixture, cost: "0.18"),
      ])
      let model = fixture.model
      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }

      let url = try temporaryDirectory().appending(path: "usage.csv")
      model.exportLedger(to: url)
      // The flag flips synchronously, so a second transfer cannot start behind this one.
      #expect(model.isTransferringLedger)
      await waitUntil("the export to finish") { !model.isTransferringLedger }

      #expect(model.ledgerTransferMessage == "Exported 2 rows to usage.csv.")
      let text = try String(contentsOf: url, encoding: .utf8)
      let lines = text.split(separator: "\n").filter { !$0.isEmpty }
      #expect(lines.count == 3, "one header plus the two stored rows")
      #expect(lines[0].hasPrefix("ts,source,provider,model,"))
    }
  }

  @Test("an export of an empty ledger is a header and zero rows, not an error")
  func exportOfEmptyLedger() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      let url = try temporaryDirectory().appending(path: "empty.csv")

      model.exportLedger(to: url)
      await waitUntil("the export to finish") { !model.isTransferringLedger }

      #expect(model.ledgerTransferMessage == "Exported 0 rows to empty.csv.")
      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(text.split(separator: "\n").count == 1)
    }
  }

  @Test("an exported file imports into a fresh ledger, re-reads the metrics, and dedupes")
  func importRoundTripsAndDeduplicates() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      // Source: two rows the app imported and then exported.
      let sourceFixture = makeFixture(defaults: defaults)
      sourceFixture.usageSource.offer([
        record(in: sourceFixture, cost: "0.42"), record(in: sourceFixture, cost: "0.18"),
      ])
      let sourceModel = sourceFixture.model
      sourceModel.start(observingSystemEvents: false)
      await waitUntil("the source ledger pass") { sourceModel.localUsage != nil }

      let csv = try temporaryDirectory().appending(path: "usage.csv")
      sourceModel.exportLedger(to: csv)
      await waitUntil("the export to finish") { !sourceModel.isTransferringLedger }

      // Target: a fresh ledger, no opencode rows at all.
      let targetFixture = makeFixture(defaults: defaults)
      let targetModel = targetFixture.model
      targetModel.importLedger(from: csv)
      await waitUntil("the import to finish") { !targetModel.isTransferringLedger }
      #expect(targetModel.ledgerTransferMessage == "Imported 2 rows from usage.csv.")

      // The successful import re-reads the metrics, so the number on screen is the imported one.
      await waitUntil("the metrics to be re-read") { targetModel.localUsage != nil }
      #expect(targetModel.localUsage?.todaySpendUSD == decimal("0.60"))

      targetModel.importLedger(from: csv)
      await waitUntil("the second import to finish") { !targetModel.isTransferringLedger }
      #expect(
        targetModel.ledgerTransferMessage
          == "Imported nothing new from usage.csv; every row was already stored.")
    }
  }

  @Test("a malformed CSV is refused whole, with one sentence and no ledger write")
  func malformedCSVIsRefused() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      let bad = try temporaryDirectory().appending(path: "bad.csv")
      try Data("not,a,valid,header\n".utf8).write(to: bad)

      model.importLedger(from: bad)
      await waitUntil("the import to fail") { !model.isTransferringLedger }
      await drainPendingEffects()

      let message = try #require(model.ledgerTransferMessage)
      #expect(message.hasPrefix("That CSV cannot be imported:"))
      #expect(message.hasSuffix("(line 1)."))
      // Nothing was written, so no pass ever had a number to read: the metrics stay unset rather
      // than becoming a false zero.
      #expect(model.localUsage == nil)
    }
  }

  @Test("the suggested export name is dated in the caller's timezone, with grouping in sentences")
  func namesAndCounts() {
    let instant = Date(timeIntervalSince1970: 1_770_000_000)
    #expect(
      LedgerPanels.suggestedExportName(now: instant, timeZone: TimeZone(identifier: "UTC")!)
        == "DeepTally-usage-2026-02-02.csv")
    #expect(MetricFormatting.groupedCount(5_275) == "5,275")
    #expect(MetricFormatting.groupedCount(0) == "0")
  }
}
