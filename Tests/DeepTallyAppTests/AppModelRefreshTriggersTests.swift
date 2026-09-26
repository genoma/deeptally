// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The refresh policy as the app applies it: opening the popover is a look worth a request, system
/// events are recovery checks, the backstop follows the power state, and the scheduler receives the
/// tolerance the policy computed.
@Suite("App model refresh triggers", .serialized)
@MainActor
struct AppModelRefreshTriggersTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.triggers"

  @Test("opening the popover refreshes only when the reading is older than a minute")
  func presentationRefreshRespectsFreshness() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      model.refresh()
      await settleRefresh(model)
      #expect(fixture.fetcher.callCount == 1)

      // Opening the panel right after the fetch shares the reading: browsing is not a request storm.
      model.refreshOnPresentation()
      await drainPendingEffects()
      #expect(fixture.fetcher.callCount == 1)

      // A minute and a second later, looking again is worth a request.
      fixture.clock.advance(61)
      model.refreshOnPresentation()
      await settleRefresh(model)
      #expect(fixture.fetcher.callCount == 2)
    }
  }

  @Test("recovery triggers wait five minutes, and retry immediately after a failed attempt")
  func recoveryFreshnessAndFailureRetry() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      model.refresh()
      await settleRefresh(model)
      #expect(fixture.fetcher.callCount == 1)

      // A wake four minutes after a good reading is not worth another request…
      fixture.clock.advance(240)
      model.refreshIfStale(.recovery)
      await drainPendingEffects()
      #expect(fixture.fetcher.callCount == 1)

      // …but one past five minutes is.
      fixture.clock.advance(61)
      model.refreshIfStale(.recovery)
      await settleRefresh(model)
      #expect(fixture.fetcher.callCount == 2)

      // A failed attempt is always retried on a recovery event, however fresh the last success was:
      // the event is exactly when a retry is cheap and likely to work.
      fixture.fetcher.setOutcome(.failure(.transport("offline")))
      model.refresh()
      await settleRefresh(model)
      #expect(fixture.fetcher.callCount == 3)

      model.refreshIfStale(.recovery)
      await settleRefresh(model)
      #expect(fixture.fetcher.callCount == 4)
    }
  }

  @Test("the backstop is the user's interval on the adapter and at least an hour on battery")
  func backstopFollowsPowerState() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      // Adapter: the default 30 minutes, with the documented 10% tolerance.
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      model.refresh()
      await settleRefresh(model)
      #expect(fixture.scheduling.lastRefreshDelay == 1800)
      #expect(fixture.scheduling.lastRefreshTolerance == 180)

      // Battery: the same setting is widened to the hour floor, never narrowed, and the tolerance
      // follows the widened interval.
      fixture.power.isOnBattery = true
      model.settings.refreshIntervalMinutes = 15
      #expect(fixture.scheduling.lastRefreshDelay == 3600)
      #expect(fixture.scheduling.lastRefreshTolerance == 360)

      // Low Power Mode behaves like battery.
      fixture.power.isOnBattery = false
      fixture.power.isLowPowerMode = true
      model.settings.refreshIntervalMinutes = 5
      #expect(fixture.scheduling.lastRefreshDelay == 3600)
    }
  }

  @Test("a short interval keeps the 30-second tolerance floor")
  func shortIntervalKeepsTheToleranceFloor() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      model.settings.refreshIntervalMinutes = 5
      #expect(fixture.scheduling.lastRefreshDelay == 300)
      #expect(fixture.scheduling.lastRefreshTolerance == 30)
    }
  }

  @Test("the tick notices a power-source change, re-arms the backstop and widens the stale window")
  func tickNoticesPowerChange() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      model.start(observingSystemEvents: false)
      await settleRefresh(model)
      #expect(fixture.scheduling.lastRefreshDelay == 1800)

      // A hundred seconds is inside the recovery freshness window, so the power change re-arms the
      // schedule without a request.
      fixture.clock.advance(100)
      fixture.power.isOnBattery = true
      fixture.scheduling.fireTick()
      #expect(fixture.scheduling.lastRefreshDelay == 3600)
      #expect(fixture.fetcher.callCount == 1)

      // The stale window follows the power state: four thousand seconds is past the old 30-minute
      // cadence's hour, but inside the battery cadence's two hours.
      fixture.clock.advance(3900)
      fixture.scheduling.fireTick()
      #expect(model.balanceState?.isStale == false)
      #expect(fixture.fetcher.callCount == 1)
    }
  }

  @Test("a request already in flight satisfies a presentation trigger instead of stacking onto it")
  func inflightRequestSatisfiesPresentationTrigger() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      fixture.fetcher.holdRequestsOpen()

      model.refresh()
      await waitUntil("the first request to arrive") { fixture.fetcher.callCount == 1 }

      // The reading is nil, so without the in-flight guard this would queue a second request. The
      // request already running is the refresh the user is about to read.
      model.refreshOnPresentation()
      fixture.fetcher.release()
      await settleRefresh(model)
      #expect(fixture.fetcher.callCount == 1)
    }
  }

  @Test("the per-install jitter is drawn once, reused, and repaired when out of range")
  func persistedJitterFractionIsStable() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let store = LaunchStateStore(defaults: defaults)
      let first = store.persistedJitterFraction()
      #expect((0...1).contains(first))
      #expect(store.persistedJitterFraction() == first)

      // A hand-edited preference outside the range is replaced, not trusted.
      defaults.set(5.0, forKey: "io.github.genoma.deeptally.jitter-fraction")
      let repaired = store.persistedJitterFraction()
      #expect((0...1).contains(repaired))
      #expect(repaired != 5.0)
      #expect(store.persistedJitterFraction() == repaired)
    }
  }
}
