// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Rendering for the two ledger-backed menu bar metrics.
///
/// Deliberately the same shape as `BalanceMonitor`'s amount text: two decimals, `.` as the decimal
/// separator, no grouping separator, so switching the metric does not change the menu bar's width.
/// The currency is the price table's, **not** the account's: ledger costs are stored in the table's
/// currency and are never converted (docs/PLAN.md §1, "CNY handling: show as-is").
enum MetricFormatting {
  /// `"$0.42"`, `"¥0.42"`, `"CHF 0.42"` — the balance's currency-prefix behaviour applied to the
  /// ledger's currency. Zero renders as `"$0.00"`: "nothing recorded today" is a fact, not a gap.
  static func spend(_ amount: Decimal, currency: String) -> String {
    currencyPrefix(currency) + amountText(amount)
  }

  /// `"62%"`, or an em dash when the window had no prompt tokens to divide by. A rate with no
  /// denominator is unknown, not zero: `0%` would claim every prompt token missed the cache.
  static func cacheHitPercent(_ ratio: Double?) -> String {
    guard let ratio else { return "—" }
    return "\(Int((ratio * 100).rounded()))%"
  }

  /// The same three-case mapping `BalanceMonitor` uses, kept here because `Sources/DeepTallyCore`
  /// owns that one privately and the app layer cannot reach it.
  private static func currencyPrefix(_ currency: String) -> String {
    switch currency {
    case "USD": return "$"
    case "CNY": return "¥"
    default: return currency + " "
    }
  }

  /// `en_US_POSIX` so the text is identical on every machine instead of following the user's locale.
  private static func amountText(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.roundingMode = .halfUp
    return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
  }
}
