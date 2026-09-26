// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One rendered balance reading: everything the menu bar label and the popover need, with no
/// formatting left to the UI layer.
public struct BalanceState: Sendable, Equatable {
  /// `"$13.49"`, `"¥98.00"`, `"CHF 12.00"` for a currency without a known symbol; `nil` with no data.
  public let amountText: String?
  /// The account currency, as DeepSeek returned it. Never converted.
  public let currency: String?
  /// DeepSeek's `is_available` flag; `false` whenever there is no data to show.
  public let isAvailable: Bool
  /// Strictly below the monitor's threshold, so `1.99 < 2` is low and `2.00` is not.
  public let isLow: Bool
  /// The last successful fetch is more than `staleAfter` behind `now`.
  public let isStale: Bool
  /// `"as of 22:41"` while the reading is under an hour old, `"3h 12m old"` from then on, `nil`
  /// without a timestamp.
  public let ageText: String?
  /// One-line summary for the popover.
  public let statusText: String
}

/// Turns the raw `/user/balance` response plus the time of the last successful fetch into a
/// ``BalanceState``. Pure logic: no timers, no I/O, no notifications.
public struct BalanceMonitor: Sendable {
  /// The balance below which the account counts as low. The comparison is strict.
  public let lowBalanceThreshold: Decimal
  /// How long a reading stays fresh. `now - lastSuccess <= staleAfter` is fresh.
  public let staleAfter: TimeInterval

  public init(lowBalanceThreshold: Decimal = 2, staleAfter: TimeInterval = 3600) {
    self.lowBalanceThreshold = lowBalanceThreshold
    self.staleAfter = staleAfter
  }

  /// `balance` is the last reading, `lastSuccess` the instant it was fetched. Both may be `nil`:
  /// a fresh install has fetched nothing yet.
  public func evaluate(balance: Balance?, lastSuccess: Date?, now: Date) -> BalanceState {
    let info = balance?.primary
    let elapsed = lastSuccess.map { now.timeIntervalSince($0) }
    let isStale = elapsed.map { $0 > staleAfter } ?? false
    let isLow = info.map { $0.totalBalance < lowBalanceThreshold } ?? false
    let isAvailable = balance?.isAvailable ?? false

    return BalanceState(
      amountText: Self.amountText(for: info),
      currency: info?.currency,
      isAvailable: isAvailable,
      isLow: isLow,
      isStale: isStale,
      ageText: Self.ageText(elapsed: elapsed, fetchedAt: lastSuccess),
      statusText: Self.statusText(
        hasBalance: balance != nil,
        hasInfo: info != nil,
        hasTimestamp: lastSuccess != nil,
        isAvailable: isAvailable,
        isLow: isLow,
        isStale: isStale
      )
    )
  }

  // MARK: - Formatting

  /// The currency prefix is the account currency, never a conversion: `"$"`, `"¥"`, or the code and
  /// a space for anything else, so an unexpected currency still reads as an amount.
  private static func currencyPrefix(_ currency: String) -> String {
    switch currency {
    case "USD": return "$"
    case "CNY": return "¥"
    default: return currency + " "
    }
  }

  /// Two decimals, decimal separator `.`, no grouping separator: `en_US_POSIX` makes the amount
  /// text identical on every machine instead of following the user's locale.
  private static func amount(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.roundingMode = .halfUp
    return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
  }

  private static func amountText(for info: BalanceInfo?) -> String? {
    guard let info else { return nil }
    return currencyPrefix(info.currency) + amount(info.totalBalance)
  }

  /// Under an hour the fetch clock time is the most useful thing to show; from an hour on it is the
  /// reading's age (`"27h 4m old"` — days stay in hours), floored to whole minutes.
  private static func ageText(elapsed: TimeInterval?, fetchedAt: Date?) -> String? {
    guard let elapsed, let fetchedAt else { return nil }
    guard elapsed >= 3600 else { return "as of \(clockTime(fetchedAt))" }
    return relativeAge(elapsed)
  }

  /// Whole minutes behind, floored. Clamped: a non-finite or absurd interval is not worth trapping
  /// over in `Int(_:)`, and anything beyond a century already reads as "not current".
  private static func relativeAge(_ elapsed: TimeInterval) -> String {
    let seconds = elapsed.isFinite ? min(max(elapsed, 0), 3_155_760_000) : 0
    let minutes = Int((seconds / 60).rounded(.down))
    return "\(minutes / 60)h \(minutes % 60)m old"
  }

  /// Instants are compared in UTC but *displayed* in the user's time zone (AGENTS.md §9.9).
  private static func clockTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }

  /// Exactly one line, in decreasing order of what the user has to do about it.
  private static func statusText(
    hasBalance: Bool,
    hasInfo: Bool,
    hasTimestamp: Bool,
    isAvailable: Bool,
    isLow: Bool,
    isStale: Bool
  ) -> String {
    guard hasBalance else {
      return hasTimestamp ? "No balance data." : "Nothing fetched yet."
    }
    guard hasInfo else { return "No balance details returned." }
    if isLow { return "Low balance — top up to keep requests running." }
    if !isAvailable { return "Balance unavailable — top up to keep requests running." }
    if isStale { return "Balance is not up to date." }
    guard hasTimestamp else { return "Balance loaded, fetch time unknown." }
    return "Balance is up to date."
  }
}
