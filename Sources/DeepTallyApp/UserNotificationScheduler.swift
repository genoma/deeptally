// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UserNotifications

/// The one place that talks to the notification centre.
///
/// Authorization was measured to work for the ad-hoc bundle (docs/SPIKES.md S4: the system prompt
/// appeared and returned `granted: true`), but denial is a normal outcome, not an error: nothing here
/// throws, nothing retries, and the popover's own low-balance notice is the fallback. A notification
/// carries the amount and the threshold and nothing else — never a key (AGENTS.md §5).
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

  /// Posts the low-balance alert. Both strings are display text the caller already formatted in the
  /// account currency; a failed post is ignored, because there is nothing for the user to do about it
  /// and the popover says the same thing.
  func postLowBalance(amountText: String, threshold: String) async {
    let content = UNMutableNotificationContent()
    content.title = "DeepSeek balance is low"
    content.body = "Balance \(amountText) is below your \(threshold) threshold."
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: Self.lowBalanceIdentifier, content: content, trigger: nil)
    try? await center.add(request)
  }
}
