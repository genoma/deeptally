// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore
@testable import deeptally

// MARK: - Fixtures

/// A ledger in a throwaway folder. The commands take the ledger path as an argument, so nothing here
/// can reach the developer's real ledger even by accident.
private final class CLILedger {
  let directory: URL
  let url: URL
  let store: LedgerStore

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-cli-tests-\(UUID().uuidString)")
    url = directory.appending(path: "Application Support/DeepTally/ledger.sqlite")
    store = try LedgerStore(url: url)
  }

  /// One row, stored at the cost the caller names. `model` defaults to a model the shipped table
  /// prices — taken from the table itself rather than spelled here, because the table is data.
  @discardableResult
  func addRow(
    model: String,
    at timestamp: Date = Date(timeIntervalSince1970: 1_790_000_000),
    costUSD: Decimal = .zero,
    sessionID: String
  ) throws -> Int {
    let usage = TokenUsage(
      promptTokens: 1_000_000, completionTokens: 0, cacheHitTokens: 0, cacheMissTokens: 1_000_000,
      reasoningTokens: 0)
    return try store.insert([
      UsageRecord(
        timestamp: timestamp, source: .opencode, provider: .deepseek, model: model, usage: usage,
        costUSD: costUSD, sessionID: sessionID)
    ]) { $0.sessionID ?? "" }
  }

  func destroy() { try? FileManager.default.removeItem(at: directory) }
}

/// A model id from the shipped table, so a test never hardcodes a price-table entry.
private func shippedModel() throws -> String {
  try #require(try CLI.pricing().table.models.first).model
}

private func missingLedgerURL() -> URL {
  FileManager.default.temporaryDirectory
    .appending(path: "deeptally-cli-tests-\(UUID().uuidString)/ledger.sqlite")
}

/// A hand-built outcome, for the two report tests: the rendering is a pure function of it, so the
/// tests do not need a ledger to say what the text should be.
private func baselineOutcome(
  rowsChanged: Int = 4,
  rowsUnpriced: Int = 2_750,
  unpricedModels: [UnpricedModel] = [
    UnpricedModel(model: "deepseek/deepseek-v4-flash-vision-exp", rows: 2_750, spendUSD: .zero)
  ],
  previousPriceTableVersion: String? = "2026-09-24"
) -> RepriceOutcome {
  RepriceOutcome(
    rowsExamined: 5_275,
    rowsChanged: rowsChanged,
    rowsUnpriced: rowsUnpriced,
    unpricedModels: unpricedModels,
    spendBeforeUSD: Decimal.parse("3.754373"),
    spendAfterUSD: Decimal.parse("4.121900"),
    priceTableVersion: "2026-09-24",
    previousPriceTableVersion: previousPriceTableVersion
  )
}

// MARK: - ledger reprice

@Suite("CLI ledger reprice")
struct LedgerRepriceCommandTests {
  @Test("reprices a stored row end to end, from the same prices the app would bill with")
  func repricesEndToEnd() throws {
    let ledger = try CLILedger()
    defer { ledger.destroy() }
    let model = try shippedModel()
    let table = try CLI.pricing().table
    try ledger.addRow(model: model, sessionID: "ses_cli")

    let outcome = try CLI.reprice(ledgerURL: ledger.url)

    #expect(outcome.rowsExamined == 1)
    #expect(outcome.rowsChanged == 1)
    #expect(outcome.spendBeforeUSD == .zero)
    #expect(outcome.spendAfterUSD > .zero)
    #expect(outcome.priceTableVersion == table.version)

    // Nothing left to repair: the same command again reports it.
    let again = try CLI.reprice(ledgerURL: ledger.url)
    #expect(again.madeNoChanges)
    #expect(again.spendAfterUSD == outcome.spendAfterUSD)
  }

  @Test("exits 0 whether or not anything changed, and 1 for a usage error")
  func exitCodes() async throws {
    let ledger = try CLILedger()
    defer { ledger.destroy() }

    // An empty ledger, a ledger nothing can be found in, and an argument error: the first two are
    // success (the answer is "nothing to do"), the third is a failure.
    #expect(await CLI.run(["ledger", "reprice", "--json"], ledgerURL: ledger.url) == 0)
    #expect(await CLI.run(["ledger", "reprice"], ledgerURL: ledger.url) == 0)
    #expect(await CLI.run(["ledger", "reprice", "--nonsense"], ledgerURL: ledger.url) == 1)
    #expect(await CLI.run(["ledger", "unprice"], ledgerURL: ledger.url) == 1)
  }

  @Test("a ledger that is not a database is a real failure: exit 1")
  func unreadableLedgerFails() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-cli-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "ledger.sqlite")
    try Data("not a database".utf8).write(to: url)

    #expect(await CLI.run(["ledger", "reprice", "--json"], ledgerURL: url) == 1)
  }

  @Test("the plain report names the counts, both totals and the ids still without a price")
  func plainReport() throws {
    let text = CLI.renderText(baselineOutcome(), currency: "USD")

    #expect(text.contains("Repriced 5,275 rows"))
    #expect(text.contains("4 rows changed"))
    #expect(text.contains("2026-09-24"))
    #expect(text.contains("spend before: 3.754373"))
    #expect(text.contains("spend after:  4.121900"))
    #expect(text.contains("2,750 rows the table does not price"))
    #expect(text.contains("deepseek/deepseek-v4-flash-vision-exp"))
    #expect(text.contains("deeptally ledger reprice"))
  }

  @Test("a pass that changed nothing says so, and a clean ledger reports no unpriced rows")
  func plainReportOfANoOp() throws {
    let text = CLI.renderText(
      baselineOutcome(rowsChanged: 0, rowsUnpriced: 0, unpricedModels: []), currency: "USD")

    #expect(text.contains("nothing changed"))
    #expect(text.contains("The costs already came from this table."))
    #expect(text.contains("unpriced:     none"))
    #expect(!text.contains("the table does not price"))
  }

  @Test("--json is machine-readable: counts as numbers, money as six-decimal strings")
  func jsonReport() throws {
    let json = try CLI.renderJSON(baselineOutcome(), currency: "USD")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

    #expect(object["currency"] as? String == "USD")
    #expect(object["rowsExamined"] as? Int == 5_275)
    #expect(object["rowsChanged"] as? Int == 4)
    #expect(object["rowsUnpriced"] as? Int == 2_750)
    #expect(object["spendBefore"] as? String == "3.754373")
    #expect(object["spendAfter"] as? String == "4.121900")
    #expect(object["spendDelta"] as? String == "0.367527")
    #expect(object["priceTableVersion"] as? String == "2026-09-24")
    #expect(object["previousPriceTableVersion"] as? String == "2026-09-24")

    let unpriced = try #require(object["unpricedModels"] as? [[String: Any]])
    #expect(unpriced.count == 1)
    #expect(unpriced[0]["model"] as? String == "deepseek/deepseek-v4-flash-vision-exp")
    #expect(unpriced[0]["rows"] as? Int == 2_750)
    #expect(unpriced[0]["spend"] as? String == "0.000000")
  }

  @Test("an outcome with no previous table omits that key rather than inventing a version")
  func jsonReportWithoutAPreviousVersion() throws {
    let json = try CLI.renderJSON(
      baselineOutcome(previousPriceTableVersion: nil), currency: "USD")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

    #expect(object["previousPriceTableVersion"] == nil)
    #expect(object["priceTableVersion"] as? String == "2026-09-24")
  }

  @Test("plain usage warns about unpriced rows, and stays silent when there is no gap")
  func usageWarning() throws {
    // No ledger on disk: nothing to warn about, and no file created by looking.
    let missing = missingLedgerURL()
    #expect(try CLI.unpricedWarning(ledgerURL: missing) == nil)
    #expect(!FileManager.default.fileExists(atPath: missing.path))

    let ledger = try CLILedger()
    defer { ledger.destroy() }
    #expect(try CLI.unpricedWarning(ledgerURL: ledger.url) == nil)

    try ledger.addRow(model: "deepseek-v4-flash-vision-exp", sessionID: "ses_unpriced")

    let warning = try #require(try CLI.unpricedWarning(ledgerURL: ledger.url))
    #expect(warning.contains("1 of 1 ledger rows have no price"))
    #expect(warning.contains("deepseek-v4-flash-vision-exp 1"))
    #expect(warning.contains("deeptally ledger reprice"))
  }

  @Test("row counts are grouped the same way on every machine")
  func numberFormattingIsPinned() {
    #expect(CLI.grouped(5_275) == "5,275")
    #expect(CLI.grouped(23) == "23")
    #expect(CLI.money(Decimal.parse("3.754373")) == "3.754373")
    #expect(CLI.money(.zero) == "0.000000")
    #expect(CLI.money(Decimal.parse("0.000001")) == "0.000001")
  }
}
