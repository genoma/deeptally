// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation

/// The analytics panel's whole input as values: three windows, a per-model breakdown and a daily
/// series, each already aggregated by the ledger.
///
/// Split from the loader deliberately. `LocalUsageLedger` owns the queries and the isolation domain;
/// this type owns the shape the view renders, so the formatting and the trend scale are testable
/// without a database, a popover or a clock.
struct LocalUsageAnalytics: Sendable, Equatable {
  /// One headline window: today, the last 7 days, the last 30 days. Each ends with today, so they
  /// nest and the three totals can only grow from left to right.
  struct Window: Sendable, Equatable {
    /// Machine-stable name: `today`, `last_7_days`, `last_30_days`.
    let key: String
    /// What a person reads: `Today`, `7 days`, `30 days`.
    let label: String
    let spendUSD: Decimal
    let requestCount: Int
    let tokenCount: Int
    /// Cache-read over prompt tokens, or `nil` when the window held no prompt tokens. `nil` is not
    /// zero: a rate with no denominator is unknown, and the panel prints an em dash for it.
    let cacheHitRatio: Double?
    /// Days in this window answered from the daily rollups because their raw rows were pruned, and
    /// days neither store could answer. Both are shown: a number that came from a rollup is a
    /// different kind of number, and a day that is simply missing must not look like a zero.
    let rollupDays: Int
    let unavailableDays: [String]
  }

  /// One model's share of the breakdown window.
  struct ModelRow: Sendable, Equatable {
    let provider: Provider
    let model: String
    let spendUSD: Decimal
    let requestCount: Int
    let cacheHitRatio: Double?
  }

  /// One UTC day of the trend series.
  struct DayPoint: Sendable, Equatable {
    /// UTC date, `YYYY-MM-DD`.
    let date: String
    let spendUSD: Decimal
    let requestCount: Int
    let cacheHitRatio: Double?
  }

  let windows: [Window]
  /// Per-model rows for the breakdown window (the last 30 days), ordered by provider then model.
  let models: [ModelRow]
  /// The trailing 30 UTC days that recorded usage, oldest first. Days with no usage are absent
  /// rather than zero: the ledger does not know whether nothing was used or nothing was imported.
  let days: [DayPoint]

  /// Whether any window recorded a request. An empty ledger and a ledger whose history is all
  /// outside the windows are different states, and the panel says so.
  var hasAnyUsage: Bool { windows.contains { $0.requestCount > 0 } }

  /// The one sentence that explains a window's provenance, or `nil` when every day came from raw
  /// rows. Both halves can be present: an old pruned day and a partly covered edge day.
  ///
  /// The rollup count is the **largest** window's, never the sum: the three windows end with today,
  /// so they nest and a pruned day inside all three would be counted three times. The unavailable
  /// dates are deduplicated for the same reason.
  var rollupNote: String? {
    let rollupDays = windows.map(\.rollupDays).max() ?? 0
    let unavailable = Set(windows.flatMap(\.unavailableDays)).sorted()
    switch (rollupDays, unavailable.isEmpty) {
    case (0, true): return nil
    case (let days, true):
      return "\(days) \(days == 1 ? "day" : "days") from the daily rollups (UTC days)."
    case (0, false):
      return
        "\(unavailable.count) partly pruned \(unavailable.count == 1 ? "day" : "days") not counted."
    case (let days, false):
      return
        "\(days) \(days == 1 ? "day" : "days") from the daily rollups (UTC days); "
        + "\(unavailable.count) partly pruned not counted."
    }
  }
}

/// How the trend bars map a value to a height.
///
/// Cache hit is drawn against 0–100%, never against the series' own maximum: a 55% rate reaching
/// the top of the box would read as a good day when it is a coin flip. The scale is a value type so
/// the arithmetic is testable without a view.
struct TrendScale: Equatable {
  /// What a height of 1.0 means, in the series' own units. 1 for a ratio.
  let maximum: Double

  /// The bar height for a value, clamped to 0...1, or `nil` when the day has no value at all.
  func height(_ value: Double?) -> Double? {
    guard let value, maximum > 0 else { return nil }
    return min(1, max(0, value / maximum))
  }

  /// The cache-hit trend's scale: always 0...100%.
  static let cacheHit = TrendScale(maximum: 1)
}
