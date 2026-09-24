// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// Launch and the ticker: what the app adopts from a previous run, and what the 30-second tick does —
/// and, just as importantly, what it does not do.
@Suite("App model lifecycle", .serialized)
@MainActor
struct AppModelLifecycleTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.lifecycle"

  /// A threshold above the balance these tests use, so "the ticker does not alert" is a claim about a
  /// balance the policy would otherwise alert on.
  private static var lowBalanceSettings: AppSettings {
    var settings = AppSettings.default
    settings.lowBalanceThreshold = 100
    return settings
  }

  @Test(
    "the ticker re-evaluates staleness and re-reads the login item without fetching or alerting")
  func tickerReevaluatesWithoutFetching() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(
        defaults: defaults, outcome: .balance(usdBalance("1.50")),
        settings: Self.lowBalanceSettings)
      // macOS refuses the alert, so nothing stamps the cooldown: a tick that notified would post
      // again, which is what makes "the ticker does not notify" a real assertion.
      fixture.alerts.acceptsPosts = false
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await settleRefresh(model)
      await waitUntil("the first alert attempt") { fixture.alerts.posts.count == 1 }

      #expect(model.balanceState?.isLow == true)
      #expect(model.balanceState?.isStale == false)
      #expect(model.loginItemStatus == .notRegistered)
      #expect(fixture.fetcher.callCount == 1)
      #expect(fixture.scheduling.tickerInterval == 30)

      // An hour and a half later the reading is stale and macOS has changed its mind about the login
      // item; the tick is the only thing that runs.
      fixture.clock.advance(5400)
      fixture.loginItem.status = .requiresApproval
      fixture.scheduling.fireTick()

      #expect(model.balanceState?.isStale == true)
      // The tick re-renders the age text the popover shows, and the low-balance line keeps its
      // priority over the staleness line.
      #expect(model.balanceState?.ageText == "1h 30m old")
      #expect(model.balanceState?.statusText == "Low balance — top up to keep requests running.")
      #expect(model.loginItemStatus == .requiresApproval)
      #expect(model.launchAtLoginEnabled)
      #expect(
        model.loginItemStatusNote
          == "Waiting for approval in System Settings → General → Login Items.")
      #expect(fixture.fetcher.callCount == 1)
      #expect(fixture.alerts.posts.count == 1)

      model.stop()
      #expect(fixture.scheduling.cancels == 1)
    }
  }

  @Test("a reading from an earlier run is adopted at launch, with its true age")
  func storedReadingIsAdoptedAtLaunch() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fetchedAt = Date(timeIntervalSince1970: 1_770_000_000 - 7200)
      LaunchStateStore(defaults: defaults).saveReading(
        LaunchStateStore.Reading(balance: usdBalance("7.00"), fetchedAt: fetchedAt))

      let fixture = makeFixture(defaults: defaults, key: testKeySource(.none))
      let model = fixture.model
      model.start(observingSystemEvents: false)
      await settleRefresh(model)

      #expect(model.lastSuccess == fetchedAt)
      #expect(model.balanceState?.amountText == "$7.00")
      #expect(model.balanceState?.isStale == true)
      #expect(model.balanceState?.ageText == "2h 0m old")
      #expect(fixture.fetcher.callCount == 0)
    }
  }

  @Test("the login-item toggle records what macOS was asked to do")
  func loginItemToggle() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      model.start(observingSystemEvents: false)
      await settleRefresh(model)
      #expect(model.loginItemStatus == .notRegistered)
      #expect(!model.launchAtLoginEnabled)
      #expect(model.banners.isEmpty)

      model.setLaunchAtLogin(true)
      #expect(fixture.loginItem.registrations == 1)
      #expect(model.loginItemStatus == .enabled)
      #expect(model.launchAtLoginEnabled)
      #expect(model.loginItemStatusNote == nil)
      #expect(model.banners.isEmpty)

      model.setLaunchAtLogin(false)
      #expect(fixture.loginItem.unregistrations == 1)
      #expect(model.loginItemStatus == .notRegistered)
      #expect(!model.launchAtLoginEnabled)
      #expect(model.banners.isEmpty)
    }
  }

  @Test("a registration macOS refuses becomes a banner, not a thrown error")
  func loginItemFailureIsReported() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.loginItem.registerFailure = StubRegistrationError.refused
      let model = fixture.model

      model.setLaunchAtLogin(true)

      let banner = try #require(model.banners.first { $0.id == "login-item" })
      #expect(banner.kind == .error)
      #expect(banner.message.contains("Could not update the login item"))
      #expect(banner.message.contains("refused"))
      // The toggle reads the registration status, so it cannot show "on" for something macOS refused.
      #expect(model.loginItemStatus == .notRegistered)
      #expect(!model.launchAtLoginEnabled)
    }
  }
}

/// A stand-in for an `SMAppService` failure. The app only ever prints a description of one, and a
/// `String(describing:)` of this case is "refused".
private enum StubRegistrationError: Error {
  case refused
}
