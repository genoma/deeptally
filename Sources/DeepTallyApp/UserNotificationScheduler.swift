// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UserNotifications

/// What macOS will do with the app's alerts, as reported by the notification settings.
///
/// `.notAsked` is kept apart from `.denied`: the system prompt may still be on screen, and the
/// popover must not claim alerts are off before the user has answered.
enum AlertAuthorization: Sendable, Equatable {
  /// Alerts will be delivered.
  case authorized
  /// The user declined, or notifications are switched off for the app in System Settings.
  case denied
  /// The user has not answered yet.
  case notAsked
  /// A status this build does not know.
  case unknown
}

/// The one place that talks to the notification centre.
///
/// Authorization was measured to work for the ad-hoc bundle (docs/SPIKES.md S4: the system prompt
/// appeared and returned `granted: true`), but denial is a normal outcome, not an error: nothing here
/// throws, nothing retries on its own, and the menu bar's warning glyph plus the popover's own line
/// are the fallback. A notification carries the amount and the threshold and nothing else — never a
/// key (AGENTS.md §5).
@MainActor
final class UserNotificationScheduler {
  private let center: UNUserNotificationCenter
  /// Reused so a second alert replaces the first instead of stacking in Notification Centre.
  private static let lowBalanceIdentifier = "io.github.genoma.deeptally.low-balance"

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  /// Asks once, at launch. `false` means alerts are off — denied, or not yet answered — and the app
  /// keeps working without them.
  @discardableResult
  func requestAuthorization() async -> Bool {
    (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
  }

  /// The authorization macOS reports right now. Read from the settings rather than remembered, so a
  /// change made in System Settings while the app runs is seen without a relaunch.
  func authorization() async -> AlertAuthorization {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: return .authorized
    case .denied: return .denied
    case .notDetermined: return .notAsked
    @unknown default: return .unknown
    }
  }

  /// Posts the low-balance alert and reports whether macOS **accepted** it for delivery.
  ///
  /// An unauthorized app never hands the request to the centre at all, so the caller can tell "not
  /// allowed" from "the post itself failed" by asking ``authorization()``. `false` always means the
  /// user was not told, which is what lets the caller retry instead of consuming the cooldown. Both
  /// strings are display text the caller already formatted in the account currency.
  func postLowBalance(amountText: String, threshold: String) async -> Bool {
    guard await authorization() == .authorized else { return false }
    let content = UNMutableNotificationContent()
    content.title = "DeepSeek balance is low"
    content.body = "Balance \(amountText) is below your \(threshold) threshold."
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: Self.lowBalanceIdentifier, content: content, trigger: nil)
    do {
      try await center.add(request)
      return true
    } catch {
      return false
    }
  }
}
