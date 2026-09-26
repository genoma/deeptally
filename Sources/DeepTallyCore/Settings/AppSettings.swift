// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which number the menu bar title shows while the popover is closed.
public enum MenuBarMetric: String, Codable, Sendable, CaseIterable {
  case balance
  case todaySpend
  case cacheHitRate
}

/// Everything the user can change, with a default for every field.
///
/// A stored blob may have been written by an older build or edited by hand, so `validated()` is the
/// only state the rest of the app should see. Nothing here is a secret: the API key lives in the
/// Keychain, never in `UserDefaults` (AGENTS.md §5).
public struct AppSettings: Codable, Sendable, Equatable {
  public var refreshIntervalMinutes: Int
  public var lowBalanceThreshold: Decimal
  public var menuBarMetric: MenuBarMetric
  public var notificationsEnabled: Bool
  public var notificationCooldownMinutes: Int
  public var showSecondaryMetric: Bool
  /// Whether the opt-in loopback usage proxy listens. Off by default: it is the only part of the app
  /// that accepts a connection, so it is never on because of an update.
  public var proxyEnabled: Bool
  /// The port the proxy binds on loopback. Never a privileged port.
  public var proxyPort: Int

  public init(
    refreshIntervalMinutes: Int = 20,
    lowBalanceThreshold: Decimal = 2,
    menuBarMetric: MenuBarMetric = .balance,
    notificationsEnabled: Bool = true,
    notificationCooldownMinutes: Int = 720,
    showSecondaryMetric: Bool = false,
    proxyEnabled: Bool = false,
    proxyPort: Int = 8787
  ) {
    self.refreshIntervalMinutes = refreshIntervalMinutes
    self.lowBalanceThreshold = lowBalanceThreshold
    self.menuBarMetric = menuBarMetric
    self.notificationsEnabled = notificationsEnabled
    self.notificationCooldownMinutes = notificationCooldownMinutes
    self.showSecondaryMetric = showSecondaryMetric
    self.proxyEnabled = proxyEnabled
    self.proxyPort = proxyPort
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
  /// The ports the proxy may bind: everything from the top of the privileged range to the top of the
  /// port space, so a typo can never ask macOS for a port the app cannot have.
  public static let proxyPortRange = 1024...65_535

  /// The same settings with every numeric field pulled into its supported range.
  public func validated() -> AppSettings {
    var settings = self
    settings.refreshIntervalMinutes = Self.clamp(
      refreshIntervalMinutes, to: Self.refreshIntervalRange)
    settings.lowBalanceThreshold = Self.clamp(
      lowBalanceThreshold, to: Self.lowBalanceThresholdRange)
    settings.notificationCooldownMinutes = Self.clamp(
      notificationCooldownMinutes, to: Self.notificationCooldownRange)
    // A nonsense port is pulled into the range like every other numeric field, rather than resetting
    // the whole blob: a hand-edited 1 becomes 1024, and the rest of the settings survive it.
    settings.proxyPort = Self.clamp(proxyPort, to: Self.proxyPortRange)
    return settings
  }

  private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
    min(max(value, range.lowerBound), range.upperBound)
  }

  // MARK: - Codable

  private enum CodingKeys: String, CodingKey {
    case refreshIntervalMinutes
    case lowBalanceThreshold
    case menuBarMetric
    case notificationsEnabled
    case notificationCooldownMinutes
    case showSecondaryMetric
    case proxyEnabled
    case proxyPort
  }

  /// Tolerant by design: a missing key, a value of the wrong type, or a `menuBarMetric` string this
  /// build does not know falls back to `AppSettings.default` for **that field only**. Unknown keys
  /// are ignored, so a blob written by a newer build stays readable here.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = AppSettings.default
    refreshIntervalMinutes =
      (try? container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes))
      ?? fallback.refreshIntervalMinutes
    lowBalanceThreshold = Self.decodeThreshold(from: container) ?? fallback.lowBalanceThreshold
    menuBarMetric =
      (try? container.decodeIfPresent(MenuBarMetric.self, forKey: .menuBarMetric))
      ?? fallback.menuBarMetric
    notificationsEnabled =
      (try? container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled))
      ?? fallback.notificationsEnabled
    notificationCooldownMinutes =
      (try? container.decodeIfPresent(Int.self, forKey: .notificationCooldownMinutes))
      ?? fallback.notificationCooldownMinutes
    showSecondaryMetric =
      (try? container.decodeIfPresent(Bool.self, forKey: .showSecondaryMetric))
      ?? fallback.showSecondaryMetric
    proxyEnabled =
      (try? container.decodeIfPresent(Bool.self, forKey: .proxyEnabled))
      ?? fallback.proxyEnabled
    proxyPort =
      (try? container.decodeIfPresent(Int.self, forKey: .proxyPort))
      ?? fallback.proxyPort
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(refreshIntervalMinutes, forKey: .refreshIntervalMinutes)
    try container.encode("\(lowBalanceThreshold)", forKey: .lowBalanceThreshold)
    try container.encode(menuBarMetric, forKey: .menuBarMetric)
    try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
    try container.encode(notificationCooldownMinutes, forKey: .notificationCooldownMinutes)
    try container.encode(showSecondaryMetric, forKey: .showSecondaryMetric)
    try container.encode(proxyEnabled, forKey: .proxyEnabled)
    try container.encode(proxyPort, forKey: .proxyPort)
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
