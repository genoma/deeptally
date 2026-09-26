// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation

/// One half-open range of local days, `[start, end)`, in the calendar that built it.
struct UsageWindow: Equatable {
  /// Machine-stable name: `today`, `last_7_days`, `last_30_days`.
  let key: String
  /// What a person reads: `today`, `last 7 days`, `last 30 days`.
  let label: String
  let start: Date
  let end: Date
}

/// The windows `deeptally usage` asks the ledger for.
///
/// "Today" is a question about the user's clock, and the ledger's `daily` rollups are keyed by **UTC**
/// date on purpose, so every window here is a run of consecutive *local* days that the caller turns
/// into a `ts` range. Building "today" out of the rollups would be off by a day for every user who is
/// not on UTC; ``LedgerStore/usageWindow(since:until:provider:)`` reads them only for whole days whose
/// raw rows are gone, and reports those days as the UTC days they are. Days are added through the
/// calendar, never as 86 400 seconds, so a DST day stays a whole local day.
enum UsageWindows {
  /// Today, the last 7 days and the last 30 days — each ending with today, so the three windows nest
  /// and the totals can only grow from left to right.
  static func headline(now: Date, calendar: Calendar) -> [UsageWindow] {
    [1, 7, 30].map { window(days: $0, now: now, calendar: calendar) }
  }

  /// The window the per-model breakdown covers. `days == 1` is today.
  static func selected(days: Int, now: Date, calendar: Calendar) -> UsageWindow {
    window(days: days, now: now, calendar: calendar)
  }

  /// `[start of the local day `days - 1` days ago, start of tomorrow)`.
  private static func window(days: Int, now: Date, calendar: Calendar) -> UsageWindow {
    let count = max(1, days)
    let today = calendar.startOfDay(for: now)
    // `date(byAdding:)` answers nil only for components this calendar cannot add. The fallbacks keep
    // the range anchored at today rather than trapping; Sources has no force-unwraps.
    let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
    let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    return UsageWindow(
      key: count == 1 ? "today" : "last_\(count)_days",
      label: count == 1 ? "today" : "last \(count) days",
      start: start,
      end: end
    )
  }
}

/// Everything `deeptally usage` prints, as a value: the command owns the queries, this type owns the
/// formatting, and a test can prove both the numbers and the JSON keys without a database.
struct UsageReport {
  /// One window's numbers.
  struct Window {
    let key: String
    let label: String
    let start: Date
    let end: Date
    let summary: LedgerSummary
    /// How many of these days the ledger answered from the `daily` rollup: their raw rows were pruned.
    /// They are whole UTC days, which is what the footnote under the tables says.
    let rollupDays: Int
    /// UTC dates (`YYYY-MM-DD`) the window only partly covers and whose raw rows are gone. Their
    /// partial totals are not included — a whole-day rollup cannot be sliced — so the report names
    /// them instead of quietly reporting a smaller window.
    let unavailableDays: [String]

    /// Prompt plus completion, where prompt already includes cache reads and completion already
    /// includes reasoning — the ledger's own definitions, added rather than re-derived.
    var tokenCount: Int { summary.promptTokens + summary.outputTokens + summary.reasoningTokens }
  }

  let windows: [Window]
  /// The window the per-model breakdown covers (`--days`, default 30).
  let selected: Window
  let days: Int
  let generatedAt: Date
  let timeZone: TimeZone
  /// The price table's currency: what the ledger's amounts were priced in.
  let currency: String
  /// Raw `request` rows in the whole ledger, not just these windows. 0 means nothing has ever been
  /// imported, which is what the one-line hint is for.
  let ledgerRowCount: Int
  let ledgerPath: String

  /// True when the ledger holds no rows at all — not merely none in the windows above.
  var isEmpty: Bool { ledgerRowCount == 0 }

  /// A cache-hit rate as a percentage with one decimal, or `nil` when the range held no prompt
  /// tokens. `nil` is not 0: a ratio with no denominator is unknown, and both outputs say so.
  static func percent(_ ratio: Double?) -> Double? {
    guard let ratio else { return nil }
    return (ratio * 1_000).rounded() / 10
  }

  // MARK: - Human output

  /// The report a person reads. An empty ledger prints zeros and one hint line — never an error.
  func humanText() -> String {
    var lines = ["Usage — local days (\(timeZone.identifier)), spend in \(currency).", ""]
    lines += Self.table(
      headers: ["", "spend", "requests", "tokens", "cache hit"],
      rows: windows.map { window in
        [window.label]
          + Self.cells(
            spend: window.summary.spendUSD,
            requests: window.summary.requestCount,
            tokens: window.tokenCount,
            cacheHit: window.summary.cacheHitRatio,
            currency: currency)
      },
      leadingColumns: 1)

    let models = selected.summary.models
    if !models.isEmpty {
      lines.append("")
      lines.append("per model, \(selected.label):")
      lines += Self.table(
        headers: ["provider", "model", "spend", "requests", "tokens", "cache hit"],
        rows: models.map { model in
          [model.provider.rawValue, model.model]
            + Self.cells(
              spend: model.spendUSD,
              requests: model.requestCount,
              tokens: model.promptTokens + model.outputTokens + model.reasoningTokens,
              cacheHit: model.cacheHitRatio,
              currency: currency)
        },
        leadingColumns: 2)
    }

    if isEmpty {
      lines.append("")
      lines.append("No rows in the ledger yet — import local usage with `deeptally import`.")
    } else if hasUnknownCacheHit {
      lines.append("")
      lines.append("n/a: no prompt tokens in that range, so there is no cache-hit rate to report.")
    }

    let notes = [rollupDaysNote, unavailableDaysNote].compactMap { $0 }
    if !notes.isEmpty {
      lines.append("")
      lines += notes
    }

    lines.append("")
    lines.append("ledger: \(ledgerPath) — \(CLI.grouped(ledgerRowCount)) raw rows")
    return lines.joined(separator: "\n")
  }

  /// Whether any cell above is `n/a`. The footnote is only worth printing when it explains something.
  private var hasUnknownCacheHit: Bool {
    if selected.summary.models.contains(where: { $0.cacheHitRatio == nil }) { return true }
    return (windows + [selected]).contains { $0.summary.cacheHitRatio == nil }
  }

  /// One calm line saying that some of the days above came from the `daily` rollup and that a rollup day
  /// is a whole UTC day, or `nil` when every day was read from its raw rows.
  ///
  /// The count is the largest ``Window/rollupDays`` of the reported windows, not their sum: the windows
  /// nest (today inside 7 days inside 30 days), so adding them would count one pruned day three times.
  private var rollupDaysNote: String? {
    let count = (windows + [selected]).map(\.rollupDays).max() ?? 0
    guard count > 0 else { return nil }
    let table = "the daily rollup table, which is keyed by whole UTC days."
    return count == 1
      ? "note: 1 day in these windows comes from \(table)"
      : "note: \(count) days in these windows come from \(table)"
  }

  /// One sentence naming every UTC date a window could not answer for, or `nil` when every day the
  /// windows touch is a whole day. The dates are deduplicated across the windows and named in order.
  private var unavailableDaysNote: String? {
    let days = Set((windows + [selected]).flatMap(\.unavailableDays)).sorted()
    guard !days.isEmpty else { return nil }
    let named =
      days.count == 1
      ? days[0] : days.dropLast().joined(separator: ", ") + " and " + days[days.count - 1]
    guard days.count > 1 else {
      return "\(named) is only partly inside these windows, so its partial totals are not included."
    }
    return
      "\(named) are only partly inside these windows, so their partial totals are not included."
  }

  /// One right-aligned column per number, two spaces between columns, no trailing blank cells.
  private static func table(
    headers: [String], rows: [[String]], leadingColumns: Int
  ) -> [String] {
    let all = [headers] + rows
    let widths = (0..<headers.count).map { column in
      all.map { $0[column].count }.max() ?? 0
    }
    return all.map { row in
      let cells = row.enumerated().map { index, cell in
        index < leadingColumns
          ? rightPad(cell, to: widths[index]) : leftPad(cell, to: widths[index])
      }
      return "  " + trimTrailingSpaces(cells.joined(separator: "  "))
    }
  }

  private static func cells(
    spend: Decimal, requests: Int, tokens: Int, cacheHit: Double?, currency: String
  ) -> [String] {
    [
      CLI.displayMoney(spend, currency: currency),
      CLI.grouped(requests),
      CLI.grouped(tokens),
      Self.percent(cacheHit).map { String(format: "%.1f%%", $0) } ?? "n/a",
    ]
  }

  private static func rightPad(_ text: String, to width: Int) -> String {
    text + String(repeating: " ", count: max(0, width - text.count))
  }

  private static func leftPad(_ text: String, to width: Int) -> String {
    String(repeating: " ", count: max(0, width - text.count)) + text
  }

  private static func trimTrailingSpaces(_ line: String) -> String {
    var text = line
    while text.hasSuffix(" ") { text.removeLast() }
    return text
  }

  // MARK: - JSON output

  /// One JSON document with the same numbers as ``humanText()``, stable key names and money as a
  /// decimal string, so a script can read spend without a float ever touching it.
  func jsonText() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(Document(report: self))
    return String(decoding: data, as: UTF8.self)
  }
}

// MARK: - JSON document

private struct Document: Encodable {
  let schema: Int
  let generatedAt: String
  let timeZone: String
  let currency: String
  let days: Int
  let selected: WindowDocument
  let windows: [WindowDocument]
  let models: [ModelDocument]

  enum CodingKeys: String, CodingKey {
    case schema
    case generatedAt = "generated_at"
    case timeZone = "timezone"
    case currency
    case days
    case selected
    case windows
    case models
  }

  init(report: UsageReport) {
    schema = 1
    generatedAt = Timestamps.utc(report.generatedAt)
    timeZone = report.timeZone.identifier
    currency = report.currency
    days = report.days
    selected = WindowDocument(window: report.selected, timeZone: report.timeZone)
    windows = report.windows.map { WindowDocument(window: $0, timeZone: report.timeZone) }
    models = report.selected.summary.models.map(ModelDocument.init)
  }
}

/// A window's identity plus its numbers, in one flat object.
private struct WindowDocument: Encodable {
  let key: String
  /// The window bounds are rendered in the report's own time zone (with the offset), so a boundary
  /// reads as the local midnight it is.
  let from: String
  let until: String
  /// How many of the window's days came from the `daily` rollup because their raw rows were pruned.
  let rollupDays: Int
  /// The `YYYY-MM-DD` UTC dates the window only partly covers and cannot answer for.
  let unavailableDays: [String]
  let numbers: Numbers

  enum CodingKeys: String, CodingKey {
    case key
    case from
    case until
    case rollupDays
    case unavailableDays
  }

  init(window: UsageReport.Window, timeZone: TimeZone) {
    key = window.key
    from = Timestamps.local(window.start, in: timeZone)
    until = Timestamps.local(window.end, in: timeZone)
    rollupDays = window.rollupDays
    unavailableDays = window.unavailableDays
    numbers = Numbers(summary: window.summary)
  }

  /// The numbers are merged into this object rather than nested under a `totals` key: a script should
  /// read `.windows[0].spend`. The key sets cannot collide — this type's own keys are exactly `key`,
  /// `from`, `until`, `rollupDays` and `unavailableDays`.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(from, forKey: .from)
    try container.encode(until, forKey: .until)
    try container.encode(rollupDays, forKey: .rollupDays)
    try container.encode(unavailableDays, forKey: .unavailableDays)
    try numbers.encode(to: encoder)
  }
}

private struct ModelDocument: Encodable {
  let provider: String
  let model: String
  let numbers: Numbers

  enum CodingKeys: String, CodingKey {
    case provider
    case model
  }

  init(model: LedgerModelTotals) {
    provider = model.provider.rawValue
    self.model = model.model
    numbers = Numbers(model: model)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(provider, forKey: .provider)
    try container.encode(model, forKey: .model)
    try numbers.encode(to: encoder)
  }
}

/// The seven numbers every window and every model row reports.
private struct Numbers: Encodable {
  let spend: String
  let requests: Int
  let tokens: Int
  let promptTokens: Int
  let completionTokens: Int
  let cacheReadTokens: Int
  let cacheHitPercent: Double?

  enum CodingKeys: String, CodingKey {
    case spend
    case requests
    case tokens
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case cacheReadTokens = "cache_read_tokens"
    case cacheHitPercent = "cache_hit_pct"
  }

  init(summary: LedgerSummary) {
    spend = CLI.money(summary.spendUSD)
    requests = summary.requestCount
    tokens = summary.promptTokens + summary.outputTokens + summary.reasoningTokens
    promptTokens = summary.promptTokens
    completionTokens = summary.outputTokens + summary.reasoningTokens
    cacheReadTokens = summary.cacheReadTokens
    cacheHitPercent = UsageReport.percent(summary.cacheHitRatio)
  }

  init(model: LedgerModelTotals) {
    spend = CLI.money(model.spendUSD)
    requests = model.requestCount
    tokens = model.promptTokens + model.outputTokens + model.reasoningTokens
    promptTokens = model.promptTokens
    completionTokens = model.outputTokens + model.reasoningTokens
    cacheReadTokens = model.cacheReadTokens
    cacheHitPercent = UsageReport.percent(model.cacheHitRatio)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(spend, forKey: .spend)
    try container.encode(requests, forKey: .requests)
    try container.encode(tokens, forKey: .tokens)
    try container.encode(promptTokens, forKey: .promptTokens)
    try container.encode(completionTokens, forKey: .completionTokens)
    try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
    // The key is always present, with JSON `null` when there is no ratio: a missing key is
    // indistinguishable from a typo in a script.
    if let cacheHitPercent {
      try container.encode(cacheHitPercent, forKey: .cacheHitPercent)
    } else {
      try container.encodeNil(forKey: .cacheHitPercent)
    }
  }
}

// MARK: - Formatting

// Money, counts and timestamps come from the CLI's one set of formatters (`CLI.money`,
// `CLI.grouped`, `CLI.displayMoney` and this type). The usage table and `ledger reprice` print the
// same digits because there is one implementation of each, not two.

/// Instant formatting for both reports: the usage JSON and the import watermark.
enum Timestamps {
  /// An instant in UTC: `2026-09-24T22:05:11Z`, or with milliseconds when asked — the ledger's
  /// watermark is stored at millisecond resolution and shown exactly, not rounded.
  static func utc(_ date: Date, fractionalSeconds: Bool = false) -> String {
    formatter(timeZone: .gmt, fractionalSeconds: fractionalSeconds).string(from: date)
  }

  /// An instant in the report's time zone, offset included: `2026-09-25T00:00:00+02:00`.
  static func local(_ date: Date, in timeZone: TimeZone) -> String {
    formatter(timeZone: timeZone, fractionalSeconds: false).string(from: date)
  }

  private static func formatter(
    timeZone: TimeZone, fractionalSeconds: Bool
  ) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions =
      fractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    formatter.timeZone = timeZone
    return formatter
  }
}
