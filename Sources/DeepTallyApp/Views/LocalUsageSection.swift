// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The local-usage analytics: spend over today, 7 and 30 days, the cache-hit trend and the
/// per-model breakdown.
///
/// Values only — the section queries nothing. Every number arrives in a ``LocalUsageAnalytics``
/// that the ledger's actor built, so this view can be reasoned about (and previewed) without a
/// database, and the arithmetic that matters is tested in the actor and in ``TrendScale``.
struct LocalUsageSection: View {
  let analytics: LocalUsageAnalytics?
  let currency: String
  let isRefreshing: Bool
  /// The ledger's quiet caveat — not imported yet, or rows the price table cannot price. Shown
  /// here rather than only under the metric picker, because this is where a person looks at local
  /// usage; `nil` when there is nothing to say.
  let note: String?
  let onRefresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if let analytics, analytics.hasAnyUsage {
        windows(analytics.windows)
        if !analytics.days.isEmpty {
          trend(analytics.days)
        }
        if !analytics.models.isEmpty {
          models(analytics.models, windowLabel: analytics.windows.last?.label ?? "30 days")
        }
      } else {
        emptyState
      }
      ForEach(Array(notes.enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Text("Local usage")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      if isRefreshing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Reading local usage")
      }
      Button {
        onRefresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .font(.caption)
      .disabled(isRefreshing)
      .accessibilityLabel("Import and re-read local usage now")
      .help("Import new opencode rows and re-read the ledger now.")
    }
  }

  // MARK: - Windows

  /// Today, 7 days and 30 days in three columns. Nothing is drawn for a window the ledger has no
  /// number for — an em dash is honest, and the note below explains why the ledger is quiet.
  private func windows(_ windows: [LocalUsageAnalytics.Window]) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text("")
          .frame(width: Self.labelWidth, alignment: .leading)
        Text("spend")
          .frame(maxWidth: .infinity, alignment: .trailing)
        Text("cache")
          .frame(width: Self.cacheWidth, alignment: .trailing)
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .accessibilityHidden(true)

      ForEach(windows, id: \.key) { window in
        HStack(spacing: 8) {
          Text(window.label)
            .font(.caption)
            .frame(width: Self.labelWidth, alignment: .leading)
          Text(MetricFormatting.spend(window.spendUSD, currency: currency))
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .trailing)
          Text(MetricFormatting.cacheHitPercent(window.cacheHitRatio))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: Self.cacheWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(window.label): \(MetricFormatting.spend(window.spendUSD, currency: currency)), "
            + "cache hit \(MetricFormatting.cacheHitPercent(window.cacheHitRatio))")
      }
    }
  }

  // MARK: - Trend

  /// One bar per UTC day that recorded usage, scaled against 0–100%: a rate is not a race, and a
  /// 55% day must not reach the ceiling just because every other day was lower.
  ///
  /// Bars are capped at ``TrendScale/maximumBarWidth`` and left-aligned. Without the cap, a series
  /// with one or two days stretches each bar across the panel and the pair reads as one wide blue
  /// pill — a button that does nothing (found on a real two-day ledger).
  private func trend(_ days: [LocalUsageAnalytics.DayPoint]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Cache hit, \(days.count) \(days.count == 1 ? "day" : "days")")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer(minLength: 8)
        Text("100%")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      GeometryReader { proxy in
        let spacing = Self.trendBarSpacing
        let width = TrendScale.barWidth(
          available: proxy.size.width, spacing: spacing, count: days.count)
        HStack(alignment: .bottom, spacing: spacing) {
          ForEach(days, id: \.date) { day in
            let height = TrendScale.cacheHit.height(day.cacheHitRatio)
            Capsule()
              .fill(height == nil ? Color.secondary.opacity(0.25) : Color.accentColor.opacity(0.75))
              .frame(width: width, height: height.map { max(2, $0 * 22) } ?? 2)
              .accessibilityLabel(
                "\(day.date): \(MetricFormatting.cacheHitPercent(day.cacheHitRatio))"
              )
              .help("\(day.date) · \(MetricFormatting.cacheHitPercent(day.cacheHitRatio))")
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      }
      .frame(height: 24)
    }
  }

  private static let trendBarSpacing: CGFloat = 2

  // MARK: - Per model

  private func models(_ models: [LocalUsageAnalytics.ModelRow], windowLabel: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Per model, last \(windowLabel.lowercased())")
        .font(.caption2)
        .foregroundStyle(.tertiary)
      ForEach(models, id: \.model) { row in
        HStack(spacing: 8) {
          Text(row.model)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .help("\(row.provider.rawValue) · \(row.model)")
          Spacer(minLength: 8)
          Text(MetricFormatting.spend(row.spendUSD, currency: currency))
            .font(.caption.monospacedDigit())
          Text(MetricFormatting.cacheHitPercent(row.cacheHitRatio))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: Self.cacheWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(row.model): \(MetricFormatting.spend(row.spendUSD, currency: currency)), "
            + "cache hit \(MetricFormatting.cacheHitPercent(row.cacheHitRatio))")
      }
    }
  }

  // MARK: - Empty state and notes

  private var emptyState: some View {
    Text(
      analytics == nil
        ? "No local usage reading yet."
        : "No local usage in the last 30 days — import from opencode or a CSV file."
    )
    .font(.caption2)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The provenance line and the caveat, each at most once. Two different facts, so both are shown
  /// when both are true: the rollup note explains where old numbers came from, the caveat explains
  /// what is missing.
  private var notes: [String] {
    var lines: [String] = []
    if let rollupNote = analytics?.rollupNote { lines.append(rollupNote) }
    if let note { lines.append(note) }
    return lines
  }

  private static let labelWidth: CGFloat = 52
  private static let cacheWidth: CGFloat = 40
}

// Previews use `PreviewProvider` rather than `#Preview`: the `#Preview` macro needs the
// `PreviewsMacros` plugin, which ships with Xcode and not with Command Line Tools (AGENTS.md §9.13).
struct LocalUsageSectionPreviews: PreviewProvider {
  private static let sample: LocalUsageAnalytics = {
    let month: [(String, Double, String)] = [
      ("2026-08-28", 0.42, "0.10"), ("2026-08-29", 0.38, "0.18"), ("2026-08-30", 0.51, "0.06"),
      ("2026-08-31", 0.61, "0.22"), ("2026-09-01", 0.44, "0.14"), ("2026-09-02", 0.58, "0.09"),
    ]
    let days = month.map {
      LocalUsageAnalytics.DayPoint(
        date: $0.0, spendUSD: Decimal(string: $0.2) ?? 0, requestCount: 12, cacheHitRatio: $0.1)
    }
    return LocalUsageAnalytics(
      windows: [
        .init(
          key: "today", label: "Today", spendUSD: 0.42, requestCount: 9, tokenCount: 21_400,
          cacheHitRatio: 0.62, rollupDays: 0, unavailableDays: []),
        .init(
          key: "last_7_days", label: "7 days", spendUSD: 3.10, requestCount: 71,
          tokenCount: 190_400,
          cacheHitRatio: 0.58, rollupDays: 1, unavailableDays: []),
        .init(
          key: "last_30_days", label: "30 days", spendUSD: 12.40, requestCount: 402,
          tokenCount: 1_180_000, cacheHitRatio: 0.6, rollupDays: 4, unavailableDays: ["2026-08-12"]),
      ],
      models: [
        .init(
          provider: .deepseek, model: "deepseek-flash", spendUSD: 9.10, requestCount: 380,
          cacheHitRatio: 0.71),
        .init(
          provider: .deepseek, model: "deepseek-v4-pro", spendUSD: 3.30, requestCount: 22,
          cacheHitRatio: 0.44),
      ],
      days: days)
  }()

  static var previews: some View {
    VStack(alignment: .leading, spacing: 20) {
      LocalUsageSection(
        analytics: sample, currency: "USD", isRefreshing: false,
        note: nil, onRefresh: {})
      LocalUsageSection(
        analytics: nil, currency: "USD", isRefreshing: true,
        note: "3 rows in the ledger have no price.", onRefresh: {})
    }
    .padding(14)
    .frame(width: 320)
  }
}
