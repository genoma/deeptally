// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

// MARK: - Fixtures

/// A ledger in a throwaway folder, one per test: the suite never touches the developer's real ledger and
/// can run in parallel.
private final class RollupFixture {
  let directory: URL
  let store: LedgerStore

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-rollup-tests-\(UUID().uuidString)")
    store = try LedgerStore(url: directory.appending(path: "ledger.sqlite"))
  }

  func destroy() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private func instant(_ iso8601: String) -> Date {
  let formatter = ISO8601DateFormatter()
  guard let date = formatter.date(from: iso8601) else {
    preconditionFailure("invalid fixture instant: \(iso8601)")
  }
  return date
}

/// Three consecutive UTC days, 2026-09-27 .. 2026-09-29, all in the past relative to any "now" that
/// matters here: the tests never use the current clock.
private let day1 = instant("2026-09-27T00:00:00Z")
private let day2 = instant("2026-09-28T00:00:00Z")
private let day3 = instant("2026-09-29T00:00:00Z")

private func record(
  at timestamp: Date,
  provider: Provider = .deepseek,
  model: String = "deepseek-flash",
  usage: TokenUsage,
  costUSD: String,
  sessionID: String
) -> UsageRecord {
  UsageRecord(
    timestamp: timestamp,
    source: .opencode,
    provider: provider,
    model: model,
    usage: usage,
    costUSD: Decimal.parse(costUSD),
    sessionID: sessionID
  )
}

/// A record with the counters a real import produces: 1,000 prompt of which 800 cached, 100 completion,
/// no reasoning.
private func simpleRecord(
  at timestamp: Date,
  provider: Provider = .deepseek,
  model: String = "deepseek-flash",
  costUSD: String = "0.10",
  sessionID: String
) -> UsageRecord {
  record(
    at: timestamp, provider: provider, model: model,
    usage: TokenUsage(
      promptTokens: 1_000, completionTokens: 100, cacheHitTokens: 800, cacheMissTokens: 200,
      reasoningTokens: 0),
    costUSD: costUSD, sessionID: sessionID)
}

/// 500k cached prompt, 250k uncached, 100k completion of which 20k is reasoning — the shape
/// `OpenCodeImporter` builds, where `cacheMissTokens` already includes any cache write.
private let importerShapedUsage = TokenUsage(
  promptTokens: 750_000,
  completionTokens: 100_000,
  cacheHitTokens: 500_000,
  cacheMissTokens: 250_000,
  reasoningTokens: 20_000
)

/// Prunes everything before the start of `day`, which is the whole-day cut `pruneRawRequests` makes.
private func pruneDaysBefore(_ day: Date, in store: LedgerStore) throws -> Int {
  try store.pruneRawRequests(olderThanDays: 0, now: day.addingTimeInterval(12 * 3_600))
}

// MARK: - Tests

@Suite("Ledger usage window")
struct LedgerRollupTests {
  @Test("a pruned day keeps its cost, requests and tokens, read from the rollup")
  func prunedDayKeepsItsTotals() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }

    let records = [
      record(
        at: day1.addingTimeInterval(9 * 3_600), model: "deepseek-flash",
        usage: importerShapedUsage, costUSD: "0.25", sessionID: "ses_a"),
      simpleRecord(
        at: day1.addingTimeInterval(20 * 3_600), model: "deepseek-v4-pro", costUSD: "0.75",
        sessionID: "ses_b"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 2)
    let before = try fixture.store.summary(since: day1, until: day2)
    #expect(before.requestCount == 2)

    #expect(try pruneDaysBefore(day2, in: fixture.store) == 2)
    // The raw path no longer sees the day at all, which is what the window exists to answer.
    #expect(try fixture.store.summary(since: day1, until: day2).requestCount == 0)

    let window = try fixture.store.usageWindow(since: day1, until: day2)

    #expect(window.rawDayCount == 0)
    #expect(window.rollupDayCount == 1)
    #expect(window.unavailableDays.isEmpty)
    #expect(window.days.count == 1)
    let day = try #require(window.days.first)
    #expect(day.source == .rollup)
    #expect(day.date == "2026-09-27")
    #expect(day.dayStart == day1)
    // Same cost, request count and token totals as the day had while its rows were there.
    #expect(day.summary == before)
    #expect(window.summary == before)
    #expect(window.summary.spendUSD == Decimal.parse("1.00"))
    #expect(window.summary.requestCount == 2)
    #expect(window.summary.promptTokens == before.promptTokens)
  }

  @Test("with nothing pruned, the window summary equals the raw summary exactly")
  func windowEqualsRawSummary() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(
        at: day1.addingTimeInterval(60), model: "deepseek-flash", costUSD: "0.10",
        sessionID: "ses_a"),
      simpleRecord(
        at: day1.addingTimeInterval(3_600), provider: .kilo, model: "kilo-auto", costUSD: "0.20",
        sessionID: "ses_b"),
      simpleRecord(
        at: day1.addingTimeInterval(7_200), model: "deepseek-v4-pro", costUSD: "0.30",
        sessionID: "ses_c"),
      simpleRecord(
        at: day2.addingTimeInterval(60), model: "deepseek-flash", costUSD: "0.40",
        sessionID: "ses_d"),
      simpleRecord(
        at: day2.addingTimeInterval(3_600), provider: .kilo, model: "kilo-auto", costUSD: "0.50",
        sessionID: "ses_e"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 5)

    let window = try fixture.store.usageWindow(since: day1, until: day3)

    // The whole value, not just the totals: models, their order, money, tokens and counts.
    #expect(window.summary == (try fixture.store.summary(since: day1, until: day3)))
    #expect(window.rawDayCount == 2)
    #expect(window.rollupDayCount == 0)
    #expect(window.unavailableDays.isEmpty)
    #expect(window.days.map(\.source) == [.rawRows, .rawRows])
    #expect(window.days.map(\.date) == ["2026-09-27", "2026-09-28"])
    #expect(window.days.map(\.dayStart) == [day1, day2])
    // Each day's summary is what a summary over that day says, and the days add up to the window.
    for day in window.days {
      let end = day.dayStart.addingTimeInterval(86_400)
      #expect(day.summary == (try fixture.store.summary(since: day.dayStart, until: end)))
    }
    #expect(window.summary.requestCount == window.days.reduce(0) { $0 + $1.summary.requestCount })
    #expect(window.summary.spendUSD == Decimal.parse("1.50"))
    // Order is the ledger's own: provider, then model.
    #expect(window.summary.models.map(\.provider) == [.deepseek, .deepseek, .kilo])
    #expect(
      window.summary.models.map(\.model) == ["deepseek-flash", "deepseek-v4-pro", "kilo-auto"])
  }

  @Test("one raw day and one pruned day add up, and the day counts partition the window")
  func mixedWindow() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(
        at: day1.addingTimeInterval(3_600), model: "deepseek-flash", costUSD: "0.25",
        sessionID: "ses_pruned_a"),
      simpleRecord(
        at: day1.addingTimeInterval(7_200), model: "deepseek-v4-pro", costUSD: "0.75",
        sessionID: "ses_pruned_b"),
      simpleRecord(
        at: day2.addingTimeInterval(3_600), model: "deepseek-flash", costUSD: "0.40",
        sessionID: "ses_raw"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 3)
    #expect(try pruneDaysBefore(day2, in: fixture.store) == 2)

    let window = try fixture.store.usageWindow(since: day1, until: day3)
    let prunedDaySpend = try fixture.store.usageWindow(since: day1, until: day2).summary.spendUSD

    #expect(window.days.map(\.source) == [.rollup, .rawRows])
    #expect(window.days.map(\.date) == ["2026-09-27", "2026-09-28"])
    #expect(window.rawDayCount == 1)
    #expect(window.rollupDayCount == 1)
    #expect(window.unavailableDays.isEmpty)
    // Two whole days were touched and both are accounted for.
    #expect(window.rawDayCount + window.rollupDayCount + window.unavailableDays.count == 2)
    // The pruned day's totals survive, and the raw day's are its own.
    #expect(prunedDaySpend == Decimal.parse("1.00"))
    #expect(window.summary.spendUSD == Decimal.parse("1.40"))
    #expect(window.summary.requestCount == 3)
    #expect(
      window.summary.spendUSD == window.days.reduce(Decimal.zero) { $0 + $1.summary.spendUSD })
    #expect(
      window.summary.requestCount == window.days.reduce(0) { $0 + $1.summary.requestCount })
  }

  @Test("a partly-inside day with no raw rows is named, contributes nothing and is not guessed at")
  func partialDayWithoutRawRows() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(
        at: day1.addingTimeInterval(9 * 3_600), costUSD: "0.25", sessionID: "ses_pruned"),
      // Inside the window's second half, and one outside it: only the half-inside row may count.
      simpleRecord(
        at: day2.addingTimeInterval(6 * 3_600), costUSD: "0.30", sessionID: "ses_inside"),
      simpleRecord(
        at: day2.addingTimeInterval(18 * 3_600), costUSD: "0.90", sessionID: "ses_outside"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 3)
    #expect(try pruneDaysBefore(day2, in: fixture.store) == 1)

    // Both days are only partly inside this range: day1 from noon, day2 until noon.
    let window = try fixture.store.usageWindow(
      since: day1.addingTimeInterval(12 * 3_600), until: day2.addingTimeInterval(12 * 3_600))

    #expect(window.unavailableDays == ["2026-09-27"])
    #expect(window.rawDayCount == 1)
    #expect(window.rollupDayCount == 0)
    #expect(window.days.map(\.date) == ["2026-09-28"])
    #expect(window.days.map(\.source) == [.rawRows])
    // The pruned day's rollup aggregate is not silently folded in, and neither is the row outside the
    // range: exactly the one row that is both intact and inside the range.
    #expect(window.summary.spendUSD == Decimal.parse("0.30"))
    #expect(window.summary.requestCount == 1)
    // The rollup for the pruned day is there to over-count with, which is the point of leaving it out.
    #expect(
      try fixture.store.usageWindow(since: day1, until: day2).summary.spendUSD
        == Decimal.parse("0.25"))
  }

  @Test("the provider filter narrows both stores, and the rollup path too")
  func providerFilter() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }

    let records = [
      simpleRecord(
        at: day1.addingTimeInterval(3_600), provider: .deepseek, model: "deepseek-flash",
        costUSD: "0.40", sessionID: "ses_deepseek_pruned"),
      simpleRecord(
        at: day1.addingTimeInterval(7_200), provider: .kilo, model: "kilo-auto", costUSD: "0.60",
        sessionID: "ses_kilo_pruned"),
      simpleRecord(
        at: day2.addingTimeInterval(3_600), provider: .deepseek, model: "deepseek-v4-pro",
        costUSD: "0.40", sessionID: "ses_deepseek_raw"),
      simpleRecord(
        at: day2.addingTimeInterval(7_200), provider: .kilo, model: "kilo-auto", costUSD: "0.60",
        sessionID: "ses_kilo_raw"),
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 4)
    #expect(try pruneDaysBefore(day2, in: fixture.store) == 2)

    let all = try fixture.store.usageWindow(since: day1, until: day3)
    #expect(all.summary.spendUSD == Decimal.parse("2.00"))
    #expect(all.rollupDayCount == 1)

    // Both days answer from their own store, and only the requested provider's rows come through: the
    // pruned day from `daily`, the raw day from `request`.
    let deepseek = try fixture.store.usageWindow(since: day1, until: day3, provider: .deepseek)
    #expect(deepseek.rollupDayCount == 1)
    #expect(deepseek.rawDayCount == 1)
    #expect(deepseek.days.map(\.source) == [.rollup, .rawRows])
    #expect(deepseek.summary.models.map(\.provider) == [.deepseek, .deepseek])
    #expect(deepseek.summary.models.map(\.model) == ["deepseek-flash", "deepseek-v4-pro"])
    #expect(deepseek.summary.spendUSD == Decimal.parse("0.80"))
    // With nothing pruned in it, a filtered window equals a filtered raw summary exactly.
    #expect(
      try fixture.store.usageWindow(since: day2, until: day3, provider: .deepseek).summary
        == (try fixture.store.summary(since: day2, until: day3, provider: .deepseek)))

    let kilo = try fixture.store.usageWindow(since: day1, until: day3, provider: .kilo)
    #expect(kilo.summary.spendUSD == Decimal.parse("1.20"))
    #expect(kilo.summary.models.map(\.model) == ["kilo-auto"])
    #expect(kilo.summary.requestCount == 2)
    #expect(kilo.summary.models.allSatisfy { $0.provider == .kilo })

    // A provider neither store has rows for: nothing is reported as spend, and nothing is called
    // unavailable. The day whose raw rows are intact is still *reported* — the store can answer for it,
    // the filter merely finds nothing in it — while the pruned day, which only `daily` could answer for,
    // has no rows for this provider and contributes nothing.
    let openrouter = try fixture.store.usageWindow(since: day1, until: day3, provider: .openrouter)
    #expect(openrouter.days.map(\.date) == ["2026-09-28"])
    #expect(openrouter.days.map(\.source) == [.rawRows])
    #expect(openrouter.days.allSatisfy { $0.summary == LedgerSummary(models: []) })
    #expect(openrouter.summary == LedgerSummary(models: []))
    #expect(openrouter.rawDayCount == 1)
    #expect(openrouter.rollupDayCount == 0)
    #expect(openrouter.unavailableDays.isEmpty)

    // A partial day is named only when the rollup holds rows for the provider being asked about: the
    // filter applies to that check exactly as it applies to the rollup read.
    let partialRange = (since: day1.addingTimeInterval(12 * 3_600), until: day2)
    let kiloPartial = try fixture.store.usageWindow(
      since: partialRange.since, until: partialRange.until, provider: .kilo)
    #expect(kiloPartial.unavailableDays == ["2026-09-27"])
    #expect(kiloPartial.days.isEmpty)
    #expect(kiloPartial.summary == LedgerSummary(models: []))

    let openrouterPartial = try fixture.store.usageWindow(
      since: partialRange.since, until: partialRange.until, provider: .openrouter)
    #expect(openrouterPartial.unavailableDays.isEmpty)
    #expect(openrouterPartial.days.isEmpty)
  }

  @Test("an importer-shaped record reads the same from the raw rows and from the rollup")
  func rollupMatchesRawForImporterShapedRecords() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }

    // Importer-shaped: `cacheMissTokens` folds in everything cache writes would have been, which is
    // what `LedgerStore` stores as `input`, and the rollup has no `cache_write` column to lose.
    let records = [
      record(
        at: day1.addingTimeInterval(3_600), model: "deepseek-v4-pro", usage: importerShapedUsage,
        costUSD: "0.421300", sessionID: "ses_a")
    ]
    #expect(try fixture.store.insert(records) { $0.sessionID ?? "" } == 1)

    let rawDay = try #require(try fixture.store.usageWindow(since: day1, until: day2).days.first)
    #expect(rawDay.source == .rawRows)
    #expect(rawDay.summary.cacheWriteTokens == 0)

    #expect(try pruneDaysBefore(day2, in: fixture.store) == 1)
    let rollupDay = try #require(try fixture.store.usageWindow(since: day1, until: day2).days.first)
    #expect(rollupDay.source == .rollup)

    #expect(rawDay.summary.promptTokens == rollupDay.summary.promptTokens)
    #expect(rawDay.summary.cacheHitRatio == rollupDay.summary.cacheHitRatio)
    #expect(rawDay.summary.promptTokens == 750_000)
    #expect(rawDay.summary.cacheHitRatio == 2.0 / 3.0)
    // Not just the two tokens the rollup can see: every counter and the money agree.
    #expect(rawDay.summary == rollupDay.summary)
  }

  @Test("a whole day with no usage anywhere contributes nothing and is not unavailable")
  func emptyWholeDay() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }

    #expect(
      try fixture.store.insert([
        simpleRecord(at: day2.addingTimeInterval(3_600), sessionID: "ses_b")
      ]) { $0.sessionID ?? "" } == 1)

    let window = try fixture.store.usageWindow(since: day1, until: day3)

    #expect(window.days.map(\.date) == ["2026-09-28"])
    #expect(window.rawDayCount == 1)
    #expect(window.rollupDayCount == 0)
    #expect(window.unavailableDays.isEmpty)
    // The caveat stated on `LedgerUsageWindow`: a whole day with nothing in either store is counted in
    // none of the three, because there is nothing missing from it. Two days were touched, one is
    // accounted for.
    #expect(window.rawDayCount + window.rollupDayCount + window.unavailableDays.count == 1)
  }

  @Test("a partly-inside day with nothing in either store is not listed")
  func partialDayWithNoUsage() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }
    #expect(
      try fixture.store.insert([
        simpleRecord(at: day2.addingTimeInterval(3_600), sessionID: "ses_a")
      ]) { $0.sessionID ?? "" } == 1)

    // Nothing was pruned and day1 holds nothing: the range cuts it in half, but there is no usage to
    // count, so the rollup cannot be over-counting anything and the day is not worth naming. This is the
    // noise the first version produced for a user whose local day is not the UTC day.
    let window = try fixture.store.usageWindow(
      since: day1.addingTimeInterval(12 * 3_600), until: day3)

    #expect(window.unavailableDays.isEmpty)
    #expect(window.days.map(\.date) == ["2026-09-28"])
    #expect(window.rawDayCount == 1)
    #expect(window.rollupDayCount == 0)
    #expect(window.summary.requestCount == 1)
    // Counted nowhere, like a whole day with no usage: there is nothing missing from it.
    #expect(window.rawDayCount + window.rollupDayCount + window.unavailableDays.count == 1)
  }

  @Test("an empty range touches no days")
  func emptyRange() throws {
    let fixture = try RollupFixture()
    defer { fixture.destroy() }
    #expect(
      try fixture.store.insert([simpleRecord(at: day2, sessionID: "ses_a")]) { $0.sessionID ?? "" }
        == 1)

    let window = try fixture.store.usageWindow(since: day2, until: day2)

    #expect(window.days.isEmpty)
    #expect(window.rawDayCount == 0)
    #expect(window.rollupDayCount == 0)
    #expect(window.unavailableDays.isEmpty)
    #expect(window.summary == LedgerSummary(models: []))
  }
}
