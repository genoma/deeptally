// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Security
import Testing

@testable import DeepTallyApp

/// The refresh state machine: what one fetch publishes, what a failure leaves behind, the schedule it
/// arms afterwards, and the promise that two refreshes never run at once.
@Suite("App model refresh", .serialized)
@MainActor
struct AppModelRefreshTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.refresh"

  @Test("a successful refresh publishes the monitor's state and clears the error")
  func successPublishesMonitorState() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(
        defaults: defaults, key: testKeySource(.environment(testEnvironmentKey)))
      let model = fixture.model

      model.refresh()
      // Set synchronously, before the request leaves: the popover relies on this to show "Refreshing…".
      #expect(model.isRefreshing)
      await settleRefresh(model)

      let state = try #require(model.balanceState)
      #expect(state.amountText == "$12.34")
      #expect(state.currency == "USD")
      #expect(state.isAvailable)
      #expect(!state.isLow)
      #expect(!state.isStale)
      #expect(state.statusText == "Balance is up to date.")
      #expect(model.lastSuccess == fixture.clock.now)
      // The menu bar reads the same derived value the popover does.
      #expect(model.menuBarLabel == "$12.34")
      #expect(model.menuBarPresentation.title == "$12.34")
      #expect(!model.menuBarPresentation.showsLowBalanceWarning)
      #expect(model.menuBarPresentation.tooltip == nil)
      #expect(model.keyOrigin == .environment)
      #expect(model.banners.isEmpty)
      #expect(fixture.fetcher.keysUsed == [testEnvironmentKey])
    }
  }

  @Test("a failed refresh keeps the last reading and reports the API's own sentence")
  func failureKeepsLastReadingAndReportsTheError() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)
      let firstSuccess = try #require(model.lastSuccess)

      fixture.fetcher.setOutcome(.failure(.http(status: 401, message: "")))
      fixture.clock.advance(2 * 3600)
      model.refresh()
      await settleRefresh(model)

      let banner = try #require(model.banners.first { $0.id == "refresh" })
      #expect(banner.kind == .error)
      #expect(banner.message == "Authentication failed (401). Check the API key.")
      // A failed poll is not a reason to blank the panel: the last good reading stays, with the age
      // the monitor computes from the fetch that produced it.
      #expect(model.balanceState?.amountText == "$12.34")
      #expect(model.lastSuccess == firstSuccess)
      #expect(model.balanceState?.isStale == true)
      #expect(model.balanceState?.statusText == "Balance is not up to date.")
      #expect(!model.isRefreshing)
    }
  }

  @Test("a successful refresh after a failure removes the error banner")
  func successAfterFailureClearsTheError() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(
        defaults: defaults, outcome: .failure(.http(status: 429, message: "")))
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)
      #expect(model.banners.map(\.id) == ["refresh"])

      fixture.fetcher.setOutcome(.balance(usdBalance("9.99")))
      model.refresh()
      await settleRefresh(model)

      #expect(model.banners.isEmpty)
      #expect(model.balanceState?.amountText == "$9.99")
    }
  }

  @Test("each consecutive failure doubles the wait, the cap holds, and one success resets it")
  func backoffDoublesPerFailureAndASuccessResetsIt() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(
        defaults: defaults, outcome: .failure(.transport("offline")))
      let model = fixture.model

      // The default interval is 20 minutes; `PollingPlan` doubles the wait per failed attempt and caps
      // it at an hour, so even the first failure already waits twice the interval.
      for expected in [2400.0, 3600.0, 3600.0, 3600.0] {
        model.refresh()
        await settleRefresh(model)
        #expect(fixture.scheduling.lastRefreshDelay == expected)
      }

      // One success resets the schedule to the configured interval.
      fixture.fetcher.setOutcome(.balance(usdBalance("12.34")))
      model.refresh()
      await settleRefresh(model)
      #expect(fixture.scheduling.lastRefreshDelay == 1200)
      #expect(fixture.scheduling.refreshDelays == [2400, 3600, 3600, 3600, 1200])

      // And the callback the model handed over is the one that refreshes.
      fixture.scheduling.fireScheduledRefresh()
      await settleRefresh(model)
      #expect(fixture.fetcher.callCount == 6)
    }
  }

  @Test("a refresh requested while one is in flight runs after it, never at the same time")
  func queuedRefreshNeverRunsConcurrently() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      fixture.fetcher.holdRequestsOpen()

      model.refresh()
      await waitUntil("the first request to arrive") { fixture.fetcher.callCount == 1 }

      // The import-during-poll case: the caller's refresh must be remembered, not dropped.
      model.refresh()
      #expect(model.isRefreshing)

      fixture.fetcher.release()
      await waitUntil("the queued refresh to run") {
        fixture.fetcher.callCount == 2 && !model.isRefreshing
      }

      #expect(fixture.fetcher.maximumConcurrentCalls == 1)
      // Both requests used the key the refresh resolved, and only one reading was recorded.
      #expect(fixture.fetcher.keysUsed == [testEnvironmentKey, testEnvironmentKey])
    }
  }

  @Test("a Keychain that cannot be read still uses the environment key and says why")
  func keychainProblemStillUsesTheEnvironmentKey() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(
        defaults: defaults,
        key: testKeySource(.keychainProblem(errSecAuthFailed, environment: testEnvironmentKey)))
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)

      #expect(model.keyOrigin == .environment)
      #expect(model.keyOriginLabel == "API key: DEEPSEEK_API_KEY")
      let problem = try #require(model.keychainProblem)
      #expect(problem.contains("\(errSecAuthFailed)"))
      let banner = try #require(model.banners.first { $0.id == "keychain-problem" })
      #expect(banner.kind == .warning)
      #expect(banner.message.contains("Using DEEPSEEK_API_KEY instead."))
      #expect(fixture.fetcher.keysUsed == [testEnvironmentKey])
      #expect(model.balanceState?.amountText == "$12.34")
    }
  }

  @Test("a Keychain problem with no fallback key still surfaces the problem")
  func keychainProblemWithoutFallbackKey() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(
        defaults: defaults, key: testKeySource(.keychainProblem(errSecAuthFailed, environment: nil))
      )
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)

      #expect(model.keyOrigin == .none)
      #expect(model.keychainProblem != nil)
      #expect(fixture.fetcher.callCount == 0)
      #expect(model.banners.map(\.id).sorted() == ["keychain-problem", "no-key"])
    }
  }

  @Test("with no key at all the app fetches nothing and offers the import banner")
  func noKeySkipsTheRequest() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(
        defaults: defaults, outcome: .failure(.http(status: 401, message: "")),
        key: testKeySource(.none))
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)

      #expect(!model.isRefreshing)
      #expect(fixture.fetcher.callCount == 0)
      #expect(model.keyOrigin == .none)
      #expect(model.keyOriginLabel == "API key: none")
      #expect(model.keychainProblem == nil)
      // No key is not a network failure: the banner names the fix, and no error can be attributed to
      // a request that was never made.
      #expect(model.banners.map(\.id) == ["no-key"])
      #expect(model.balanceState == nil)
    }
  }
}
