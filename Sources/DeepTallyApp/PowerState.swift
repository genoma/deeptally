// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit.ps

/// The two power facts the refresh policy uses, behind one seam.
///
/// Injectable for the same reason as the clock: "on battery the backstop widens to an hour" has to be
/// provable without the test runner's power source deciding the outcome.
@MainActor
protocol PowerStateProviding: AnyObject {
  /// `true` while the machine is drawing from its battery rather than the power adapter.
  var isOnBattery: Bool { get }
  /// `true` while macOS is in Low Power Mode (macOS 12+), which the platform documents as pausing
  /// discretionary and background activity.
  var isLowPowerMode: Bool { get }
}

/// The shipping implementation. Low Power Mode is Foundation's documented surface; the power source is
/// the public IOKit power-sources API, which is the only supported way to tell a battery from an
/// adapter.
///
/// It is a snapshot read, not an observer: the app re-reads it from the 30-second tick and from the Low
/// Power Mode notification, so a power change is noticed within one tick without a second run loop
/// source.
@MainActor
final class SystemPowerState: PowerStateProviding {
  var isOnBattery: Bool { Self.providingSourceIsBattery() }
  var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

  /// The type of the source currently providing power, e.g. `Battery Power` or `AC Power`. A Mac
  /// without a battery (or a failed read) reports the adapter: widening the interval is the cautious
  /// direction, and a missing battery is not a reason to poll more.
  private static func providingSourceIsBattery() -> Bool {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue()
    else { return false }
    return (source as String) == (kIOPSBatteryPowerValue as String)
  }
}
