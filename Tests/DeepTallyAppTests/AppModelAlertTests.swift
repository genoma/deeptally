// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The low-balance alert — the P1 the independent Step 3 review blocked the gate on. The rule under
/// test is one sentence: only an alert macOS accepted may consume the cooldown, so a denial or a
/// failed post is retried instead of silencing the user.
@Suite("App model low-balance alerts", .serialized)
@MainActor
struct AppModelAlertTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.alerts"

  /// A balance below the default $2.00 threshold.
  private static let lowBalance = StubBalanceFetcher.Outcome.balance(usdBalance("1.50"))

  /// A threshold above the balance, so the alert path is the one being exercised.
  private static var lowBalanceSettings: AppSettings {
    var settings = AppSettings.default
    settings.lowBalanceThreshold = 100
    return settings
  }

  @Test("a healthy balance is never announced")
  func healthyBalanceIsNotAnnounced() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults, outcome: .balance(usdBalance("12.34")))
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)
      await drainPendingEffects()
      #expect(model.balanceState?.isLow == false)
      #expect(fixture.alerts.posts.isEmpty)

      // Non-vacuity control: the same model, in the same test, does post once the balance is low.
      fixture.fetcher.setOutcome(Self.lowBalance)
      model.refresh()
      await waitUntil("the low balance to be announced") { fixture.alerts.posts.count == 1 }
    }
  }

  @Test("an accepted alert is posted once and stamps the persisted cooldown")
  func acceptedAlertStampsTheCooldown() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults, outcome: Self.lowBalance)
      let model = fixture.model

      model.refresh()
      await waitUntil("the alert") { fixture.alerts.posts.count == 1 }
      await settleRefresh(model)

      #expect(fixture.alerts.postedAmounts == ["$1.50"])
      #expect(fixture.alerts.postedThresholds == ["$2.00"])
      #expect(model.alertAuthorization == .authorized)
      #expect(!model.alertsUnavailable)
      // Stamped, and persisted: the cooldown survives a relaunch, and only a delivered alert may
      // consume it.
      #expect(LaunchStateStore(defaults: defaults).loadLastNotified() == fixture.clock.now)

      // The next poll inside the cooldown says nothing more.
      fixture.clock.advance(20 * 60)
      model.refresh()
      await settleRefresh(model)
      await drainPendingEffects()
      #expect(fixture.alerts.posts.count == 1)
    }
  }

  @Test("an alert macOS denied is not stamped, so the next refresh tries again")
  func deniedAlertIsRetried() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults, outcome: Self.lowBalance)
      fixture.alerts.authorizationStatus = .denied
      fixture.alerts.acceptsPosts = false
      let model = fixture.model

      model.refresh()
      await waitUntil("the refused alert") { fixture.alerts.posts.count == 1 }
      await settleRefresh(model)

      // The user was not told, so nothing may be remembered as delivered.
      #expect(LaunchStateStore(defaults: defaults).loadLastNotified() == nil)
      #expect(model.alertAuthorization == .denied)
      #expect(model.alertsUnavailable)

      // The next poll tries again — and this time macOS accepts, so the cooldown is stamped.
      fixture.alerts.authorizationStatus = .authorized
      fixture.alerts.acceptsPosts = true
      model.refresh()
      await waitUntil("the retried alert") { fixture.alerts.posts.count == 2 }
      #expect(LaunchStateStore(defaults: defaults).loadLastNotified() == fixture.clock.now)
    }
  }

  @Test("a post that fails although alerts are allowed is retried on the next refresh")
  func failedPostIsRetried() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults, outcome: Self.lowBalance)
      fixture.alerts.acceptsPosts = false
      let model = fixture.model

      model.refresh()
      await waitUntil("the failed post") { fixture.alerts.posts.count == 1 }
      await settleRefresh(model)
      #expect(LaunchStateStore(defaults: defaults).loadLastNotified() == nil)

      fixture.alerts.acceptsPosts = true
      model.refresh()
      await waitUntil("the retried post") { fixture.alerts.posts.count == 2 }

      #expect(LaunchStateStore(defaults: defaults).loadLastNotified() == fixture.clock.now)
    }
  }

  @Test("alerts switched off post nothing and never ask macOS for permission")
  func disabledAlertsPostNothing() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      var settings = AppSettings.default
      settings.notificationsEnabled = false
      let fixture = makeFixture(defaults: defaults, outcome: Self.lowBalance, settings: settings)
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await settleRefresh(model)
      await drainPendingEffects()

      #expect(model.balanceState?.isLow == true)
      #expect(fixture.alerts.posts.isEmpty)
      #expect(fixture.alerts.authorizationRequests == 0)
      #expect(model.alertAuthorization == nil)
      #expect(!model.alertsUnavailable)
    }
  }

  @Test("turning alerts on asks macOS once and delivers the alert the policy was holding back")
  func enablingAlertsDeliversThePendingAlert() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      var settings = AppSettings.default
      settings.lowBalanceThreshold = 100
      settings.notificationsEnabled = false
      let fixture = makeFixture(defaults: defaults, outcome: Self.lowBalance, settings: settings)
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)
      await drainPendingEffects()
      #expect(fixture.alerts.posts.isEmpty)

      // The user switches alerts on: the answer can arrive long after the fetch that made the balance
      // low, so a grant re-runs the policy and the first alert is delivered then.
      fixture.alerts.authorizationStatus = .notAsked
      fixture.alerts.grantsAuthorization = true
      model.settings.notificationsEnabled = true

      await waitUntil("the alert after the grant") { fixture.alerts.posts.count == 1 }
      #expect(fixture.alerts.authorizationRequests == 1)
      #expect(model.alertAuthorization == .authorized)
      #expect(!model.alertsUnavailable)
      #expect(LaunchStateStore(defaults: defaults).loadLastNotified() == fixture.clock.now)
    }
  }

  @Test("the threshold is rendered the way the account renders the balance")
  func alertTextUsesTheAccountAmountShape() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(
        defaults: defaults, outcome: .balance(Self.cnyBalance("1.50")),
        settings: Self.lowBalanceSettings)
      let model = fixture.model

      model.refresh()
      await waitUntil("the alert") { fixture.alerts.posts.count == 1 }

      let post = try #require(fixture.alerts.posts.first)
      // Money stays `Decimal` end to end, and the amount and the threshold are both rendered the way
      // the panel renders the balance: currency prefix from the account, never a conversion.
      #expect(post.amount == "¥1.50")
      #expect(post.threshold == "¥100.00")
      #expect(fixture.alerts.postedAmounts.count == 1)
    }
  }

  /// A CNY reading, so the alert's threshold has to take its prefix from the account currency rather
  /// than from a hardcoded symbol or an exchange rate.
  private static func cnyBalance(_ amount: String) -> Balance {
    let total = decimal(amount)
    return Balance(
      isAvailable: true,
      infos: [
        BalanceInfo(
          currency: "CNY", totalBalance: total, grantedBalance: .zero, toppedUpBalance: total)
      ])
  }
}
