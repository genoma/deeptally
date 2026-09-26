// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The analytics panel's load path: one ledger pass produces the windows, the per-model breakdown and
/// the daily series, and a pruned day keeps contributing to all three.
@Suite("Local usage analytics load", .serialized)
@MainActor
struct LocalUsageAnalyticsLoadTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.analytics"

  /// One importable row `daysAgo` whole days before the fixture's clock, on the fixture's calendar
  /// (UTC), so it falls inside that local day.
  private func record(
    in fixture: AppModelFixture,
    daysAgo: Int,
    cacheHitTokens: Int = 750,
    cacheMissTokens: Int = 250,
    cost: String
  ) -> OpenCodeImporter.ImportedRecord {
    importedRecord(
      at: fixture.clock.now.addingTimeInterval(-Double(daysAgo) * 86_400),
      cacheHitTokens: cacheHitTokens, cacheMissTokens: cacheMissTokens, costUSD: decimal(cost))
  }

  @Test("one pass fills the windows, the per-model breakdown and the daily series")
  func onePassFillsThePanel() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([record(in: fixture, daysAgo: 0, cost: "0.42")])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsageAnalytics != nil }

      let analytics = try #require(model.localUsageAnalytics)
      #expect(analytics.windows.count == 3)
      #expect(analytics.windows[0].key == "today")
      #expect(analytics.windows[0].spendUSD == decimal("0.42"))
      #expect(analytics.windows[0].requestCount == 1)
      #expect(analytics.windows[0].rollupDays == 0)
      #expect(analytics.windows[0].unavailableDays.isEmpty)
      // The three windows end with today, so today's spend cannot exceed the 7-day total.
      #expect(analytics.windows[1].spendUSD == decimal("0.42"))
      #expect(analytics.windows[2].spendUSD == decimal("0.42"))

      #expect(analytics.models.count == 1)
      #expect(analytics.models.first?.model == "deepseek-flash")
      #expect(analytics.models.first?.spendUSD == decimal("0.42"))
      #expect(analytics.models.first?.cacheHitRatio == 0.75)

      // The series is the 30-day window's days: one today, with the day's own rate.
      #expect(analytics.days.count == 1)
      #expect(analytics.days.first?.cacheHitRatio == 0.75)

      // The menu bar metrics and the panel come from the same read, so they cannot disagree.
      #expect(model.localUsage?.todaySpendUSD == analytics.windows[0].spendUSD)
      #expect(model.localUsage?.cacheHitRatio == analytics.windows[2].cacheHitRatio)
      #expect(model.todaySpendText == "$0.42")
    }
  }

  @Test("a pruned day keeps its spend in the panel and its rate in the menu bar")
  func prunedDaysKeepContributing() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([
        record(in: fixture, daysAgo: 0, cost: "0.10"),
        record(in: fixture, daysAgo: 3, cost: "0.20"),
        record(in: fixture, daysAgo: 5, cost: "0.30"),
      ])
      let model = fixture.model
      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsageAnalytics != nil }

      let before = try #require(model.localUsageAnalytics)
      #expect(before.windows[1].spendUSD == decimal("0.60"))
      #expect(before.windows[1].rollupDays == 0)
      #expect(before.days.count == 3)
      #expect(model.todaySpendText == "$0.10")
      let rateBefore = model.cacheHitRateText

      // Prune everything before yesterday, the way the menu command does, then let the app read the
      // ledger again. No new opencode rows are offered, so nothing can put the days back.
      let store = try LedgerStore(url: fixture.ledgerURL)
      #expect(try store.pruneRawRequests(olderThanDays: 1, now: fixture.clock.now) == 2)
      fixture.usageSource.offer([])

      model.refreshLocalUsage()
      await waitUntil("the pass after the prune") {
        model.localUsageAnalytics?.windows[1].rollupDays == 2
      }

      let after = try #require(model.localUsageAnalytics)
      // The two pruned days are still in the totals and still in the series, now marked as rollup days.
      #expect(after.windows[1].spendUSD == decimal("0.60"))
      #expect(after.windows[1].rollupDays == 2)
      #expect(after.days.count == 3)
      #expect(after.rollupNote == "2 days from the daily rollups (UTC days).")
      // The menu bar is read through the same path, so the rate has nothing to fall back to.
      #expect(model.cacheHitRateText == rateBefore)
      #expect(model.todaySpendText == "$0.10")
    }
  }
}
