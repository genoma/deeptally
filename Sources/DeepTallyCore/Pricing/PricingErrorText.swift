// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Every sentence a ``PricingDataError`` becomes, defined once.
///
/// Three call sites used to spell these strings out for themselves — the app's banner, the CLI's
/// `deeptally rate` failure line and the override diagnostic in ``PriceTableLoader`` — so a new case
/// cost three edits in two targets and the compiler only reported the first target it rebuilt
/// (AGENTS.md §9.14). A case added now needs one line here and no call site changes: both renderings
/// of every case come from the one switch below.
extension PricingDataError {
  /// The sentence a user reads: the app shows it in the popover's banner slot, and `deeptally rate`
  /// prints it after `Could not load the pricing data:`. `detail` is kept — it names the offending
  /// field, which is the one thing a person editing the file can act on.
  public var userFacingSentence: String { wording.sentence }

  /// The reason half of ``PriceTableLoader/overrideProblem(at:error:)``, which wraps it in a sentence
  /// that already names the file — so this half never repeats the path.
  var overrideProblemReason: String { wording.reason }

  /// Both renderings of one case, so no case can arrive with half its text written. The clause is a
  /// fragment rather than a sentence, and drops the full stop the sentence ends on.
  private var wording: (sentence: String, reason: String) {
    switch self {
    case .resourceMissing(let name):
      return ("\(name) is missing or unreadable.", "the file is missing or unreadable")
    case .decodeFailed(let name, let detail):
      return (
        "\(name) is not valid JSON for its schema: \(detail)",
        "the file is not valid JSON for the price-table schema (\(Self.shortDetail(detail)))"
      )
    case .noModels:
      return ("the price table lists no models.", "the table lists no models")
    case .invalidOffPeakMultiplier(let value):
      let clause = "the off-peak multiplier \(value) is not in (0, 1]"
      return ("\(clause).", clause)
    case .invalidPrice(let model, let field, let value):
      let clause = "the \(field.rawValue) \(value) for \(model) is not greater than zero"
      return ("\(clause).", clause)
    case .invalidPeakWindow(let start, let end):
      let clause = "the peak window \(start)-\(end) UTC is not a valid hour range"
      return ("\(clause).", clause)
    case .duplicateAlias(let alias):
      let clause = "the alias \"\(alias)\" is listed on more than one model"
      return ("\(clause).", clause)
    }
  }

  /// A decode failure's detail can carry an entire `NSError` dump - `NSDebugDescription=`, a
  /// `UserInfo` dictionary, an error domain and code. That is developer noise in a user-facing
  /// banner, so keep the one clause a person editing the file can act on.
  private static func shortDetail(_ detail: String) -> String {
    var text = detail
    if let clause = text.range(of: "NSDebugDescription=") {
      text = String(text[clause.upperBound...])
      if let end = text.firstIndex(where: { $0 == "," || $0 == "}" }) {
        text = String(text[..<end])
      }
    } else if let clause = text.range(of: "Debug description: ") {
      // The `String(describing:)` form of a `DecodingError`. Everything before this marker is the
      // coding path; after it is the clause that names the field and the value to fix.
      text = String(text[clause.upperBound...])
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      return "the file could not be read"
    }
    return text.count > 160 ? String(text.prefix(157)) + "..." : text
  }
}
