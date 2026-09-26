// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Everything the user can change, with a default for every field.
///
/// A stored blob may have been written by an older build or edited by hand, so `validated()` is the
/// only state the rest of the app should see. Nothing here is a secret: the API key lives in the
/// Keychain, never in `UserDefaults` (AGENTS.md §5).
public struct AppSettings: Codable, Sendable, Equatable {
  public var refreshIntervalMinutes: Int
  public var lowBalanceThreshold: Decimal
  public var notificationsEnabled: Bool
  public var notificationCooldownMinutes: Int

  public init(
    refreshIntervalMinutes: Int = 30,
    lowBalanceThreshold: Decimal = 2,
    notificationsEnabled: Bool = true,
    notificationCooldownMinutes: Int = 720
  ) {
    self.refreshIntervalMinutes = refreshIntervalMinutes
    self.lowBalanceThreshold = lowBalanceThreshold
    self.notificationsEnabled = notificationsEnabled
    self.notificationCooldownMinutes = notificationCooldownMinutes
  }

  /// What a fresh install starts from, and the fallback for anything unreadable.
  /// (Backticks are required on the declaration only — callers write `AppSettings.default`.)
  public static let `default` = AppSettings()

  /// The supported range of each clamped field. Public so UI controls can stop at the same limits
  /// instead of letting a value be clamped behind the user's back; `validated()` stays the single
  /// enforcement point.
  public static let refreshIntervalRange = 5...240
  public static let lowBalanceThresholdRange: ClosedRange<Decimal> = 0...1000
  public static let notificationCooldownRange = 15...10_080

  /// The same settings with every numeric field pulled into its supported range.
  public func validated() -> AppSettings {
    var settings = self
    settings.refreshIntervalMinutes = Self.clamp(
      refreshIntervalMinutes, to: Self.refreshIntervalRange)
    settings.lowBalanceThreshold = Self.clamp(
      lowBalanceThreshold, to: Self.lowBalanceThresholdRange)
    settings.notificationCooldownMinutes = Self.clamp(
      notificationCooldownMinutes, to: Self.notificationCooldownRange)
    return settings
  }

  private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
    min(max(value, range.lowerBound), range.upperBound)
  }

  // MARK: - Codable

  private enum CodingKeys: String, CodingKey {
    case refreshIntervalMinutes
    case lowBalanceThreshold
    case notificationsEnabled
    case notificationCooldownMinutes
  }

  /// Tolerant by design: a missing key, a value of the wrong type, or a key a build no longer has
  /// (the removed menu-bar metric and proxy settings) falls back to `AppSettings.default` for **that
  /// field only**. Unknown keys are ignored, so a blob written by an older or a newer build stays
  /// readable here instead of resetting every setting.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = AppSettings.default
    refreshIntervalMinutes =
      (try? container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes))
      ?? fallback.refreshIntervalMinutes
    lowBalanceThreshold = Self.decodeThreshold(from: container) ?? fallback.lowBalanceThreshold
    notificationsEnabled =
      (try? container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled))
      ?? fallback.notificationsEnabled
    notificationCooldownMinutes =
      (try? container.decodeIfPresent(Int.self, forKey: .notificationCooldownMinutes))
      ?? fallback.notificationCooldownMinutes
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(refreshIntervalMinutes, forKey: .refreshIntervalMinutes)
    try container.encode("\(lowBalanceThreshold)", forKey: .lowBalanceThreshold)
    try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
    try container.encode(notificationCooldownMinutes, forKey: .notificationCooldownMinutes)
  }

  /// Money is a JSON **string** in this project (`Decimal.parse` in `Types.swift`), which is what
  /// `encode(to:)` writes; a hand-edited number is accepted rather than thrown away.
  private static func decodeThreshold(
    from container: KeyedDecodingContainer<CodingKeys>
  ) -> Decimal? {
    if let raw = try? container.decodeIfPresent(String.self, forKey: .lowBalanceThreshold) {
      return Decimal.parse(raw)
    }
    return try? container.decodeIfPresent(Decimal.self, forKey: .lowBalanceThreshold)
  }
}
