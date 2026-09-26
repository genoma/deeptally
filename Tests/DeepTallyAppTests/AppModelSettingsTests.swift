// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// Settings writes: validated, persisted, and acted on immediately. The interval feeds the schedule,
/// the threshold feeds the monitor and the cooldown feeds the alert policy, so the claim under test is
/// that a change rebuilds those collaborators rather than leaving the value they were built with.
@Suite("App model settings", .serialized)
@MainActor
struct AppModelSettingsTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.settings"

  @Test("a new refresh interval is the one the next poll is scheduled with")
  func refreshIntervalIsRescheduled() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      #expect(fixture.scheduling.refreshDelays.isEmpty)

      model.settings.refreshIntervalMinutes = 5
      #expect(fixture.scheduling.lastRefreshDelay == 300)
      #expect(SettingsStore(defaults: defaults).load().refreshIntervalMinutes == 5)

      // 240 minutes is the top of the range; `PollingPlan` caps the wait itself at an hour, so the
      // recorded delay says which of the two the app used.
      model.settings.refreshIntervalMinutes = 240
      #expect(fixture.scheduling.lastRefreshDelay == 3600)

      // Out of range is clamped before it is stored or used: 1 becomes the minimum, 5.
      model.settings.refreshIntervalMinutes = 1
      #expect(model.settings.refreshIntervalMinutes == 5)
      #expect(SettingsStore(defaults: defaults).load().refreshIntervalMinutes == 5)
      #expect(fixture.scheduling.lastRefreshDelay == 300)
    }
  }

  @Test("a new threshold is applied to the reading already on screen, without a fetch")
  func thresholdIsAppliedWithoutFetching() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults, outcome: .balance(usdBalance("12.34")))
      let model = fixture.model
      model.refresh()
      await settleRefresh(model)
      #expect(model.balanceState?.isLow == false)
      let fetchesBefore = fixture.fetcher.callCount

      model.settings.lowBalanceThreshold = 20
      #expect(model.balanceState?.isLow == true)
      #expect(model.menuBarPresentation.showsLowBalanceWarning)
      #expect(model.menuBarPresentation.tooltip == "DeepSeek balance $12.34 is low.")
      #expect(SettingsStore(defaults: defaults).load().lowBalanceThreshold == 20)

      model.settings.lowBalanceThreshold = 1
      #expect(model.balanceState?.isLow == false)
      #expect(!model.menuBarPresentation.showsLowBalanceWarning)
      #expect(model.menuBarPresentation.tooltip == nil)
      #expect(fixture.fetcher.callCount == fetchesBefore)
    }
  }

  @Test("a new cooldown is the one the next alert decision uses")
  func cooldownIsUsedByTheNextAlertDecision() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      var settings = AppSettings.default
      settings.lowBalanceThreshold = 100
      settings.notificationCooldownMinutes = 720
      let fixture = makeFixture(
        defaults: defaults, outcome: .balance(usdBalance("1.50")), settings: settings)
      let model = fixture.model

      model.refresh()
      await waitUntil("the first alert") { fixture.alerts.posts.count == 1 }
      await settleRefresh(model)

      // Sixteen minutes is inside the stored 12-hour cooldown: the policy the model was built with
      // would stay silent, so a second alert proves the new one is in use.
      model.settings.notificationCooldownMinutes = 15
      fixture.clock.advance(16 * 60)
      model.refresh()
      await waitUntil("the alert the new cooldown allows") { fixture.alerts.posts.count == 2 }
      #expect(SettingsStore(defaults: defaults).load().notificationCooldownMinutes == 15)
    }
  }

  @Test("an unchanged settings write does not re-validate or re-persist anything")
  func unchangedWriteIsIgnored() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      model.settings.refreshIntervalMinutes = 5
      let scheduled = fixture.scheduling.refreshDelays

      model.settings.refreshIntervalMinutes = 5
      #expect(fixture.scheduling.refreshDelays == scheduled)
      #expect(fixture.fetcher.callCount == 0)
    }
  }
}
