// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decides whether a low-balance alert is worth showing *again*, so a 20-minute poll cannot turn
/// into a notification storm and a balance that stays low is re-raised at most once per cooldown.
/// Stateless: the caller owns `lastNotified` and the notification itself.
public struct NotificationPolicy: Sendable {
  /// How long an alert silences the next one. The default is 12 hours: a low balance deserves a
  /// reminder twice a day, not once per poll.
  public let cooldown: TimeInterval

  public init(cooldown: TimeInterval = 43200) {
    self.cooldown = cooldown
  }

  /// `true` when a low balance should be announced at `now`.
  ///
  /// Only `isLow` can trigger an alert. `isStale` is part of the call because the caller has it,
  /// but staleness is deliberately never consulted: a stale reading is not a reason to alert on its
  /// own, and it does not silence one either — an old reading that says "low" is still a low
  /// balance, and the cooldown already bounds how often the user hears about it. A reading exactly
  /// `cooldown` old is out of cooldown, so the alert fires.
  public func shouldNotify(isLow: Bool, isStale: Bool, lastNotified: Date?, now: Date) -> Bool {
    guard isLow else { return false }
    guard let lastNotified else { return true }
    return now.timeIntervalSince(lastNotified) >= cooldown
  }
}
