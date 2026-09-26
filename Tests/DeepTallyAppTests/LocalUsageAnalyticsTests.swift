// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The parts of the analytics panel that are arithmetic rather than layout: the trend scale and the
/// one sentence that says where a window's days came from.
@Suite("Usage analytics display")
struct LocalUsageAnalyticsTests {
  private func window(
    rollupDays: Int = 0,
    unavailableDays: [String] = [],
    requestCount: Int = 5
  ) -> LocalUsageAnalytics.Window {
    LocalUsageAnalytics.Window(
      key: "last_30_days", label: "30 days", spendUSD: 1.23, requestCount: requestCount,
      tokenCount: 1_000, cacheHitRatio: 0.5, rollupDays: rollupDays,
      unavailableDays: unavailableDays)
  }

  // MARK: - Trend scale

  @Test("a cache-hit trend is drawn against 100%, never against its own maximum")
  func cacheHitScaleIsAbsolute() {
    let scale = TrendScale.cacheHit
    #expect(scale.height(0.62) == 0.62)
    #expect(scale.height(0) == 0)
    #expect(scale.height(1) == 1)
    // A rate cannot exceed 1, but a clamped scale is what keeps a bad row from drawing outside the
    // box instead of tripping an assertion in a release build.
    #expect(scale.height(1.4) == 1)
    // No prompt tokens: no bar at all, rather than a zero-height bar that reads as 0%.
    #expect(scale.height(nil) == nil)
  }

  // MARK: - Provenance note

  @Test("a window answered entirely from raw rows needs no note")
  func noNoteWhenNothingCameFromRollups() {
    let analytics = LocalUsageAnalytics(windows: [window()], models: [], days: [])
    #expect(analytics.rollupNote == nil)
    #expect(analytics.hasAnyUsage)
  }

  @Test("the rollup note counts UTC days and pluralises")
  func rollupNoteCountsDays() {
    let singular = LocalUsageAnalytics(windows: [window(rollupDays: 1)], models: [], days: [])
    #expect(singular.rollupNote == "1 day from the daily rollups (UTC days).")
    // The windows nest (today inside 7 days inside 30 days), so the note reports the largest one's
    // count rather than adding the same pruned day three times.
    let plural = LocalUsageAnalytics(
      windows: [window(rollupDays: 12), window(rollupDays: 3)], models: [], days: [])
    #expect(plural.rollupNote == "12 days from the daily rollups (UTC days).")
  }

  @Test("a partly pruned day is named as not counted, and both facts can be true at once")
  func unavailableDaysAreNamed() {
    let only = LocalUsageAnalytics(
      windows: [window(unavailableDays: ["2026-08-12"])], models: [], days: [])
    #expect(only.rollupNote == "1 partly pruned day not counted.")
    let both = LocalUsageAnalytics(
      windows: [window(rollupDays: 4, unavailableDays: ["2026-08-12", "2026-08-13"])],
      models: [], days: [])
    #expect(
      both.rollupNote
        == "4 days from the daily rollups (UTC days); 2 partly pruned not counted.")
    // The same partial day can be outside two nested windows; it is one day, not two.
    let shared = LocalUsageAnalytics(
      windows: [
        window(unavailableDays: ["2026-08-12"]), window(unavailableDays: ["2026-08-12"]),
      ], models: [], days: [])
    #expect(shared.rollupNote == "1 partly pruned day not counted.")
  }

  @Test("an empty ledger has no usage, a ledger with only missing days has none either")
  func hasAnyUsageIsAboutRequests() {
    let empty = LocalUsageAnalytics(windows: [window(requestCount: 0)], models: [], days: [])
    #expect(!empty.hasAnyUsage)
  }
}
