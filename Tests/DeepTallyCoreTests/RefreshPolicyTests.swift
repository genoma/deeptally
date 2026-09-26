// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

/// The refresh policy as arithmetic: cadence by power state, the stale window that scales with it, the
/// tolerance handed to the scheduler, and the freshness window each trigger class gets.
@Suite("Refresh policy")
struct RefreshPolicyTests {
  @Test("on the adapter the user's interval is the backstop, unchanged")
  func adapterUsesTheUsersInterval() {
    #expect(
      RefreshPolicy.backstopInterval(base: 1800, isOnBattery: false, isLowPowerMode: false) == 1800)
    #expect(
      RefreshPolicy.backstopInterval(base: 300, isOnBattery: false, isLowPowerMode: false) == 300)
  }

  @Test("battery and Low Power Mode widen the backstop to an hour, and never narrow a longer one")
  func batteryWidensTheBackstop() {
    #expect(
      RefreshPolicy.backstopInterval(base: 300, isOnBattery: true, isLowPowerMode: false) == 3600)
    #expect(
      RefreshPolicy.backstopInterval(base: 1800, isOnBattery: true, isLowPowerMode: false) == 3600)
    #expect(
      RefreshPolicy.backstopInterval(base: 300, isOnBattery: false, isLowPowerMode: true) == 3600)
    // A user who asked for four hours keeps four hours: the floor only ever raises.
    #expect(
      RefreshPolicy.backstopInterval(base: 14400, isOnBattery: true, isLowPowerMode: true) == 14400)
  }

  @Test("the stale window is twice the backstop interval")
  func staleWindowScalesWithTheBackstop() {
    #expect(RefreshPolicy.staleAfter(backstopInterval: 300) == 600)
    #expect(RefreshPolicy.staleAfter(backstopInterval: 1800) == 3600)
    #expect(RefreshPolicy.staleAfter(backstopInterval: 3600) == 7200)
  }

  @Test("the tolerance is a tenth of the interval with a 30-second floor")
  func toleranceIsTenPercentWithAFloor() {
    #expect(RefreshPolicy.tolerance(backstopInterval: 1800) == 180)
    #expect(RefreshPolicy.tolerance(backstopInterval: 3600) == 360)
    // 10% of five minutes is 30 seconds, which is exactly the floor; a very short interval still keeps
    // a leeway the system can coalesce with.
    #expect(RefreshPolicy.tolerance(backstopInterval: 300) == 30)
  }

  @Test("user intent gets a minute, recovery five, and the backstop always fetches")
  func freshnessWindows() {
    #expect(RefreshPolicy.freshnessWindow(for: .userIntent) == 60)
    #expect(RefreshPolicy.freshnessWindow(for: .recovery) == 300)
    #expect(RefreshPolicy.freshnessWindow(for: .backstop) == 0)
  }
}
