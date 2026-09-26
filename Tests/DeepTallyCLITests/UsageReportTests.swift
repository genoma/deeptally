// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import deeptally

/// The two parts of `deeptally usage` that are worth asserting without a database: the local-day
/// boundaries (the ledger's rollups are UTC-keyed, so getting these wrong is an off-by-one-day bug)
/// and the report's numbers and JSON keys.
@Suite("Usage report")
struct UsageReportTests {
  // MARK: - Windows

  @Test("headline windows are local days ending with today")
  func headlineWindows() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    // 2026-09-25 07:30 in Tokyo, which is still 2026-09-24 in UTC: the whole point of the test.
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-24T22:30:00Z"))

    let windows = UsageWindows.headline(now: now, calendar: calendar)

    #expect(windows.map(\.key) == ["today", "last_7_days", "last_30_days"])
    #expect(windows.map(\.label) == ["today", "last 7 days", "last 30 days"])
    #expect(windows[0].start == instant("2026-09-24T15:00:00Z"))
    #expect(windows[0].end == instant("2026-09-25T15:00:00Z"))
    #expect(windows[1].start == instant("2026-09-18T15:00:00Z"))
    #expect(windows[2].start == instant("2026-08-26T15:00:00Z"))
    for window in windows {
      #expect(window.start < window.end)
      #expect(window.start == calendar.startOfDay(for: window.start))
    }
  }

  @Test("a selected window of N days starts N-1 local days before today")
  func selectedWindow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-24T22:30:00Z"))

    let five = UsageWindows.selected(days: 5, now: now, calendar: calendar)
    #expect(five.key == "last_5_days")
    #expect(five.label == "last 5 days")
    #expect(five.start == instant("2026-09-20T15:00:00Z"))

    let today = UsageWindows.selected(days: 1, now: now, calendar: calendar)
    #expect(today.key == "today")
    #expect(today.label == "today")
    #expect(today.start == instant("2026-09-24T15:00:00Z"))
  }

  @Test("a DST day is a whole local day, not 24 hours")
  func dstDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    // 2026-03-08 is the US spring-forward day: midnight is EST (UTC-5) and the next midnight is EDT
    // (UTC-4), so the day is 23 hours long. Adding 86 400 seconds would land inside the wrong day.
    let now = try #require(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z"))

    let window = UsageWindows.selected(days: 1, now: now, calendar: calendar)

    #expect(window.start == instant("2026-03-08T05:00:00Z"))
    #expect(window.end == instant("2026-03-09T04:00:00Z"))
    #expect(window.end.timeIntervalSince(window.start) == 23 * 3_600)
  }

  @Test("a cache-hit rate keeps one decimal and 0 is not the same as unknown")
  func percent() {
    #expect(UsageReport.percent(2.0 / 3.0) == 66.7)
    #expect(UsageReport.percent(1) == 100)
    #expect(UsageReport.percent(0) == 0)
    #expect(UsageReport.percent(nil) == nil)
  }

  // MARK: - JSON

  @Test("JSON keeps stable keys, decimal-string money and a null cache-hit rate")
  func jsonContract() throws {
    let summary = LedgerSummary(models: [
      model(spend: "0.421300", input: 200, output: 50, cacheRead: 800, requests: 3)
    ])
    let root = try jsonObject(report(windows: summary, selected: summary, rowCount: 3).jsonText())

    #expect(root["schema"] as? Int == 1)
    #expect(root["currency"] as? String == "USD")
    #expect(root["days"] as? Int == 30)
    #expect(root["timezone"] as? String == "Europe/Rome")
    #expect(root["generated_at"] as? String == "2025-08-24T01:46:40Z")

    let windows = try #require(root["windows"] as? [[String: Any]])
    #expect(windows.count == 3)
    #expect(windows.map { $0["key"] as? String } == ["today", "last_7_days", "last_30_days"])
    // Bounds carry the local offset, so a boundary reads as the local midnight it is.
    #expect(windows[0]["from"] as? String == "2025-08-24T00:00:00+02:00")
    #expect(windows[0]["until"] as? String == "2025-08-25T00:00:00+02:00")
    // Money is a string, never a float.
    #expect(windows[0]["spend"] as? String == "0.421300")
    #expect(windows[0]["requests"] as? Int == 3)
    #expect(windows[0]["tokens"] as? Int == 1_050)
    #expect(windows[0]["prompt_tokens"] as? Int == 1_000)
    #expect(windows[0]["completion_tokens"] as? Int == 50)
    #expect(windows[0]["cache_read_tokens"] as? Int == 800)
    #expect(windows[0]["cache_hit_pct"] as? Double == 80)

    let models = try #require(root["models"] as? [[String: Any]])
    #expect(models.count == 1)
    #expect(models[0]["provider"] as? String == "deepseek")
    #expect(models[0]["model"] as? String == "deepseek-v4-pro")
    #expect(models[0]["spend"] as? String == "0.421300")
  }

  @Test("an empty ledger answers with zeros, a null cache-hit rate and no models")
  func emptyLedgerJSON() throws {
    let empty = LedgerSummary(models: [])
    let root = try jsonObject(report(windows: empty, selected: empty, rowCount: 0).jsonText())

    let windows = try #require(root["windows"] as? [[String: Any]])
    #expect(windows[0]["spend"] as? String == "0.000000")
    #expect(windows[0]["requests"] as? Int == 0)
    #expect(windows[0]["tokens"] as? Int == 0)
    // A key that is present and null: `0` would claim a cache-hit rate of zero, which is a lie.
    #expect(windows[0].keys.contains("cache_hit_pct"))
    #expect(windows[0]["cache_hit_pct"] is NSNull)
    #expect((root["models"] as? [Any])?.isEmpty == true)
  }

  @Test("every window carries its rollup day count and the days it could not answer for")
  func rollupKeys() throws {
    let summary = LedgerSummary(models: [
      model(spend: "0.421300", input: 200, output: 50, cacheRead: 800, requests: 3)
    ])
    let report = report(
      windows: summary, selected: summary, rowCount: 3, rollupDays: 2,
      unavailableDays: ["2026-08-01"])
    let root = try jsonObject(report.jsonText())

    let windows = try #require(root["windows"] as? [[String: Any]])
    #expect(windows.allSatisfy { $0["rollupDays"] as? Int == 2 })
    #expect(windows.allSatisfy { $0["unavailableDays"] as? [String] == ["2026-08-01"] })
    #expect((root["selected"] as? [String: Any])?["rollupDays"] as? Int == 2)
    #expect((root["selected"] as? [String: Any])?["unavailableDays"] as? [String] == ["2026-08-01"])
    // Every existing key keeps its name and its value.
    #expect(windows[0]["key"] as? String == "today")
    #expect(windows[0]["from"] as? String == "2025-08-24T00:00:00+02:00")
    #expect(windows[0]["until"] as? String == "2025-08-25T00:00:00+02:00")
    #expect(windows[0]["spend"] as? String == "0.421300")
    #expect(windows[0]["requests"] as? Int == 3)
    #expect(windows[0]["cache_hit_pct"] as? Double == 80)
  }

  // MARK: - Human output

  @Test("the human report prints spend, requests, tokens and the cache-hit rate")
  func humanNumbers() throws {
    let summary = LedgerSummary(models: [
      model(spend: "9.8871", input: 300, output: 200, cacheRead: 700, requests: 240)
    ])
    let text = report(windows: summary, selected: summary, rowCount: 240).humanText()

    #expect(text.contains("$9.8871"))
    #expect(text.contains("240"))
    #expect(text.contains("1,200"))
    #expect(text.contains("70.0%"))
    #expect(text.contains("per model, last 30 days:"))
    #expect(text.contains("deepseek-v4-pro"))
    #expect(text.contains("ledger: /tmp/ledger.sqlite — 240 raw rows"))
    #expect(!text.contains("No rows in the ledger yet"))
  }

  @Test("an empty ledger prints zeros and one hint line, never an error")
  func emptyLedgerText() throws {
    let empty = LedgerSummary(models: [])
    let text = report(windows: empty, selected: empty, rowCount: 0).humanText()

    #expect(text.contains("$0.00"))
    let hint = "No rows in the ledger yet — import local usage with `deeptally import`."
    #expect(text.contains(hint))
    #expect(text.contains("0 raw rows"))
    #expect(!text.contains("per model"))
    // The empty hint already says there is nothing; the n/a footnote would be noise.
    #expect(!text.contains("no prompt tokens in that range"))
  }

  @Test("no prompt tokens says n/a rather than 0%")
  func unknownCacheHitText() throws {
    let summary = LedgerSummary(models: [
      model(spend: "0.001", input: 0, output: 10, cacheRead: 0, requests: 1)
    ])
    let text = report(windows: summary, selected: summary, rowCount: 1).humanText()

    #expect(text.contains("n/a"))
    #expect(text.contains("no prompt tokens in that range"))
    #expect(!text.contains("0.0%"))
  }

  @Test("a report with no rollup days and nothing unavailable reads exactly as it did")
  func noRollupNotes() throws {
    let summary = LedgerSummary(models: [
      model(spend: "0.421300", input: 200, output: 50, cacheRead: 800, requests: 3)
    ])
    let text = report(windows: summary, selected: summary, rowCount: 3).humanText()

    #expect(!text.contains("daily rollup table"))
    #expect(!text.contains("partly inside"))
  }

  @Test("a rollup day gets one calm note, and a partial day is named, with its totals left out")
  func rollupNotes() throws {
    let summary = LedgerSummary(models: [
      model(spend: "0.421300", input: 200, output: 50, cacheRead: 800, requests: 3)
    ])
    let text = report(
      windows: summary, selected: summary, rowCount: 3, rollupDays: 2,
      unavailableDays: ["2026-08-01"]
    ).humanText()

    #expect(
      text.contains(
        "note: 2 days in these windows come from the daily rollup table, which is keyed by whole UTC days."
      ))
    #expect(
      text.contains(
        "2026-08-01 is only partly inside these windows, so its partial totals are not included."))
    // The tables are unchanged: the note is a footnote, not a new column.
    #expect(text.contains("per model, last 30 days:"))
    #expect(text.contains("ledger: /tmp/ledger.sqlite — 3 raw rows"))
  }

  @Test("several rolled-up days, and several partial dates, read as sentences")
  func rollupNotePlural() throws {
    let empty = LedgerSummary(models: [])
    let text = report(
      windows: empty, selected: empty, rowCount: 0, rollupDays: 1,
      unavailableDays: ["2026-07-31", "2026-08-01"]
    ).humanText()

    #expect(
      text.contains(
        "note: 1 day in these windows comes from the daily rollup table, which is keyed by whole UTC days."
      ))
    #expect(
      text.contains(
        "2026-07-31 and 2026-08-01 are only partly inside these windows, so their partial totals are not included."
      ))
  }

  // MARK: - Fixtures

  private func report(
    windows: LedgerSummary, selected: LedgerSummary, rowCount: Int, rollupDays: Int = 0,
    unavailableDays: [String] = []
  ) -> UsageReport {
    UsageReport(
      windows: [
        window(
          key: "today", label: "today", summary: windows, rollupDays: rollupDays,
          unavailableDays: unavailableDays),
        window(
          key: "last_7_days", label: "last 7 days", summary: windows, rollupDays: rollupDays,
          unavailableDays: unavailableDays),
        window(
          key: "last_30_days", label: "last 30 days", summary: windows, rollupDays: rollupDays,
          unavailableDays: unavailableDays),
      ],
      selected: window(
        key: "last_30_days", label: "last 30 days", summary: selected, rollupDays: rollupDays,
        unavailableDays: unavailableDays),
      days: 30,
      generatedAt: fixtureInstant,
      timeZone: fixtureTimeZone,
      currency: "USD",
      ledgerRowCount: rowCount,
      ledgerPath: "/tmp/ledger.sqlite")
  }

  private func window(
    key: String, label: String, summary: LedgerSummary, rollupDays: Int = 0,
    unavailableDays: [String] = []
  ) -> UsageReport.Window {
    UsageReport.Window(
      key: key,
      label: label,
      start: fixtureDayStart,
      end: fixtureDayStart.addingTimeInterval(86_400),
      summary: summary,
      rollupDays: rollupDays,
      unavailableDays: unavailableDays)
  }

  private func model(
    spend: String, input: Int, output: Int, cacheRead: Int, requests: Int
  ) -> LedgerModelTotals {
    LedgerModelTotals(
      provider: .deepseek,
      model: "deepseek-v4-pro",
      spendUSD: Decimal(string: spend, locale: Locale(identifier: "en_US_POSIX"))!,
      inputTokens: input,
      outputTokens: output,
      reasoningTokens: 0,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: 0,
      requestCount: requests)
  }

  private func jsonObject(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  private func instant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  /// 2025-08-24T01:46:40Z, which is 03:46 in Rome (CEST, +02:00) — inside a local day, never on a
  /// boundary, so the window assertions stay about the boundaries and not about the instant.
  private var fixtureInstant: Date { Date(timeIntervalSince1970: 1_756_000_000) }

  /// Local midnight in Rome on 2025-08-24, as the ledger would receive it from `Calendar`:
  /// 2025-08-23T22:00:00Z, exactly 3h 46m 40s before ``fixtureInstant``.
  private var fixtureDayStart: Date { Date(timeIntervalSince1970: 1_756_000_000 - 13_600) }

  private var fixtureTimeZone: TimeZone { TimeZone(identifier: "Europe/Rome")! }
}
