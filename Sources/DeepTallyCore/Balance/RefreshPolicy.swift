// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What asked for a refresh. The distinction is what decides whether the request is allowed to
/// interrupt a fresh reading: a user looking at the app is always worth answering, while a system
/// event is only a reason to check if the reading may have gone stale.
public enum RefreshTrigger: Sendable, Equatable {
  /// The user opened the popover, pressed Refresh, or changed the key or a setting. Never skipped for
  /// freshness when it comes from an explicit action; the popover path applies
  /// ``RefreshPolicy/userIntentFreshness`` so re-opening twice in a minute does not poll twice.
  case userIntent
  /// The machine woke, the display woke, a user session came back, the network returned, or the power
  /// state changed. Cheap to check, so it is bounded by ``RefreshPolicy/recoveryFreshness``.
  case recovery
  /// The backstop timer. It runs on its own cadence and always fetches.
  case backstop
}

/// The refresh policy, as arithmetic: no timers, no I/O, no power source. The app computes with it and
/// ``AppScheduling`` waits for the result, which is what makes every number here an assertion instead
/// of an observation.
///
/// The policy follows the platform research recorded in `docs/PLAN.md` (Step 6.7): a user-visible value
/// is refreshed when the user looks at it, system events are recovery triggers, and the timer is a
/// deferrable backstop — never a freshness guarantee. Apple's own guidance asks apps not to poll for
/// state changes, to respond to events instead, and not to run discretionary network work when the
/// system is on battery (Energy Efficiency Guide for Mac Apps).
public struct RefreshPolicy: Sendable {
  /// On battery or in Low Power Mode the backstop is at least this long. Slowing the timer is the one
  /// lever the app has that does not reduce what the user sees when they ask for it.
  public static let batteryBackstopFloor: TimeInterval = 3600

  /// A reading older than this multiple of the backstop interval is shown as stale. The window scales
  /// with the cadence: a fixed hour would be wrong at both ends of the 5–240 minute setting.
  public static let staleIntervalMultiplier: Double = 2

  /// Apple's documented timer guideline is a tolerance of at least 10% of the interval, which lets the
  /// system coalesce the wake-up with other work instead of bringing the machine up for this poll.
  public static let toleranceFraction: Double = 0.10
  /// A floor so a 5-minute cadence still yields a leeway the system can actually use.
  public static let toleranceFloor: TimeInterval = 30

  /// Two popover openings inside this window share one request. Short enough that the number on screen
  /// is current when it matters, long enough that browsing the panel is not a request storm.
  public static let userIntentFreshness: TimeInterval = 60
  /// A wake, a display wake, a session switch or a returning network checks the balance only if the
  /// reading is older than this, so the events that tend to arrive together cause one request.
  public static let recoveryFreshness: TimeInterval = 300

  /// The backstop cadence for the current power state. The user's setting is the baseline; battery and
  /// Low Power Mode widen it, never narrow it.
  public static func backstopInterval(
    base: TimeInterval,
    isOnBattery: Bool,
    isLowPowerMode: Bool
  ) -> TimeInterval {
    guard isOnBattery || isLowPowerMode else { return base }
    return max(base, batteryBackstopFloor)
  }

  /// When a reading becomes stale, from the backstop interval it was fetched under.
  public static func staleAfter(backstopInterval: TimeInterval) -> TimeInterval {
    backstopInterval * staleIntervalMultiplier
  }

  /// The leeway handed to the scheduler for one backstop interval.
  public static func tolerance(backstopInterval: TimeInterval) -> TimeInterval {
    max(backstopInterval * toleranceFraction, toleranceFloor)
  }

  /// How old a reading may be before a trigger of this class is still worth a request. `backstop` is
  /// always 0: the timer exists to fetch.
  public static func freshnessWindow(for trigger: RefreshTrigger) -> TimeInterval {
    switch trigger {
    case .userIntent: return userIntentFreshness
    case .recovery: return recoveryFreshness
    case .backstop: return 0
    }
  }
}
