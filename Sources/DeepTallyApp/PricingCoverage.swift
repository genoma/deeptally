// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation

/// A usage source that also knows which of the rows it offered the price table cannot price.
///
/// The app's counterpart to the CLI's `PricingCoverage`, separate only because the two live in
/// different targets. The costing closure alone cannot answer the question: the importer calls it for
/// candidate rows that the union dedupes and the watermark filter then drops, so counting there
/// over-reports. This wrapper inspects exactly the records `importAll(since:)` offered, which is the
/// set that can end up in the ledger.
///
/// A row the table cannot price is stored with a cost of zero and stays that way — `raw_hash` makes a
/// re-import a duplicate, so only `ledger reprice` can repair it. Without this note the app's spend
/// metric would under-report real usage with nothing on screen saying so.
final class PricingCoverage: UsageImporting {
  private let wrapped: any UsageImporting
  private let table: PriceTable

  private var unpricedRows = 0
  private var unpricedModels: Set<String> = []

  init(wrapping wrapped: any UsageImporting, table: PriceTable) {
    self.wrapped = wrapped
    self.table = table
  }

  var source: UsageSource { wrapped.source }

  func importAll(since: Date?) throws -> OpenCodeImporter.ImportResult {
    let result = try wrapped.importAll(since: since)
    for imported in result.records where table.price(forModel: imported.record.model) == nil {
      unpricedRows += 1
      unpricedModels.insert(imported.record.model)
    }
    return result
  }

  /// One calm sentence when the offered rows used a model the table does not list, or `nil` when
  /// every offered row had a price. The model ids are capped the way the CLI caps them: a note that
  /// names thirty ids is not a note.
  var pricingNote: String? {
    guard unpricedRows > 0 else { return nil }
    let named = unpricedModels.sorted().prefix(3).joined(separator: ", ")
    let remaining = unpricedModels.count - 3
    let more = remaining > 0 ? ", +\(remaining) more" : ""
    let subject = unpricedRows == 1 ? "1 local row uses" : "\(unpricedRows) local rows use"
    let pronoun = unpricedRows == 1 ? "it was" : "they were"
    return "\(subject) a model the price table does not list (\(named)\(more));"
      + " \(pronoun) recorded at zero cost."
  }
}
