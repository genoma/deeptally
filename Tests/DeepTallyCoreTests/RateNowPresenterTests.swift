// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

// MARK: - Fixtures

private func instant(_ iso8601: String) throws -> Date {
  try #require(
    ISO8601DateFormatter().date(from: iso8601), "fixture instant is not ISO-8601: \(iso8601)")
}

private func timeZone(_ identifier: String) throws -> TimeZone {
  try #require(TimeZone(identifier: identifier), "unknown time zone identifier: \(identifier)")
}

/// Model rows as JSON with string amounts, exactly like the shipped file.
private let proModelJSON = #"""
  {
    "model": "deepseek-v4-pro",
    "cache_hit_usd_per_million": "0.044",
    "cache_miss_usd_per_million": "1.32",
    "output_usd_per_million": "3.96"
  }
  """#

private let flashModelJSON = #"""
  {
    "model": "deepseek-flash",
    "cache_hit_usd_per_million": "0.006",
    "cache_miss_usd_per_million": "0.30",
    "output_usd_per_million": "1.20"
  }
  """#

/// The shipped windows: 01:00-04:00 and 06:00-10:00 UTC on weekdays.
private let peakWindowsJSON = #"""
  [
    { "start_hour_utc": 1, "end_hour_utc": 4 },
    { "start_hour_utc": 6, "end_hour_utc": 10 }
  ]
  """#

/// An inline table: these tests never read `Resources/PriceTable.json`, so a price change cannot
/// break them.
private func fixtureTable(
  models: [String] = [flashModelJSON, proModelJSON],
  peakWindows: String = peakWindowsJSON
) throws -> PriceTable {
  let json = """
    {
      "version": "test",
      "currency": "USD",
      "effective_from": "2026-09-24",
      "off_peak_multiplier": "0.5",
      "peak_windows_utc": \(peakWindows),
      "holidays": [],
      "models": [\(models.joined(separator: ","))]
    }
    """
  return try JSONDecoder().decode(PriceTable.self, from: Data(json.utf8))
}

private func makePresenter(
  table: PriceTable,
  timeZone: TimeZone,
  holidayCalendar: HolidayCalendar? = nil
) -> RateNowPresenter {
  let engine = PeakOffPeakEngine(
    table: table,
    holidayCalendar: holidayCalendar
      ?? HolidayCalendar(source: "PriceTable.json", dates: table.holidays)
  )
  return RateNowPresenter(table: table, engine: engine, timeZone: timeZone)
}

// MARK: - Local windows

@Suite("Rate-now local windows")
struct RateNowLocalWindowTests {
  /// 2026-09-24 is a Thursday, inside the 01:00-04:00 UTC peak window.
  @Test("a Thursday inside the UTC peak window reads peak, in Rome time")
  func romePeakWindow() throws {
    let table = try fixtureTable()
    let presenter = makePresenter(table: table, timeZone: try timeZone("Europe/Rome"))

    let display = presenter.display(at: try instant("2026-09-24T02:00:00Z"))

    #expect(display.periodLabel == "Peak")
    #expect(display.multiplierLabel == "full price")
    #expect(!display.isHoliday)
    #expect(display.holidayNote == nil)
    // The window closes at 04:00Z, which is 06:00 CEST, two hours away.
    #expect(display.windowEndsLocal == "06:00")
    #expect(display.nextTransitionLocal == "Thu 06:00")
    #expect(display.countdown == "2h 0m")
    #expect(
      display.models == [
        ModelRate(
          model: "deepseek-flash",
          cacheHit: Decimal.parse("0.006"),
          cacheMiss: Decimal.parse("0.30"),
          output: Decimal.parse("1.20")
        ),
        ModelRate(
          model: "deepseek-v4-pro",
          cacheHit: Decimal.parse("0.044"),
          cacheMiss: Decimal.parse("1.32"),
          output: Decimal.parse("3.96")
        ),
      ])
  }

  @Test("the same Thursday after the window reads off-peak at half price")
  func romeOffPeak() throws {
    let table = try fixtureTable()
    let presenter = makePresenter(table: table, timeZone: try timeZone("Europe/Rome"))

    let display = presenter.display(at: try instant("2026-09-24T12:00:00Z"))

    #expect(display.periodLabel == "Off-peak")
    #expect(display.multiplierLabel == "50% off")
    #expect(!display.isHoliday)
    // The next peak window opens Friday 01:00Z, which is 03:00 CEST.
    #expect(display.windowEndsLocal == "03:00")
    #expect(display.nextTransitionLocal == "Fri 03:00")
    #expect(display.countdown == "13h 0m")
    #expect(
      display.models == [
        ModelRate(
          model: "deepseek-flash",
          cacheHit: Decimal.parse("0.003"),
          cacheMiss: Decimal.parse("0.15"),
          output: Decimal.parse("0.60")
        ),
        ModelRate(
          model: "deepseek-v4-pro",
          cacheHit: Decimal.parse("0.022"),
          cacheMiss: Decimal.parse("0.66"),
          output: Decimal.parse("1.98")
        ),
      ])
  }

  @Test("one instant renders in each injected zone, never in the process default")
  func utcAndShanghaiWallClocks() throws {
    let table = try fixtureTable()
    // 2026-09-28 is a Monday; 03:30Z is mid-window for both zones.
    let now = try instant("2026-09-28T03:30:00Z")

    let utc = makePresenter(table: table, timeZone: try timeZone("UTC"))
      .display(at: now)
    #expect(utc.periodLabel == "Peak")
    #expect(utc.windowEndsLocal == "04:00")
    #expect(utc.nextTransitionLocal == "Mon 04:00")
    #expect(utc.countdown == "30m")

    let shanghai = makePresenter(table: table, timeZone: try timeZone("Asia/Shanghai"))
      .display(at: now)
    #expect(shanghai.periodLabel == "Peak")
    #expect(shanghai.windowEndsLocal == "12:00")
    #expect(shanghai.nextTransitionLocal == "Mon 12:00")
    #expect(shanghai.countdown == "30m")
  }

  @Test("the weekday label does not follow the process locale")
  func defaultLocaleIsPOSIX() throws {
    let table = try fixtureTable()
    // No `locale:` argument, so the presenter's own default has to be locale-independent.
    let presenter = RateNowPresenter(
      table: table,
      engine: PeakOffPeakEngine(table: table),
      timeZone: try timeZone("UTC")
    )

    let display = presenter.display(at: try instant("2026-09-28T03:30:00Z"))

    #expect(display.nextTransitionLocal == "Mon 04:00")
    #expect(display.windowEndsLocal == "04:00")
  }

  @Test("an off-peak table with no boundary reports no window instead of guessing")
  func noFurtherBoundary() throws {
    let table = try fixtureTable(models: [flashModelJSON], peakWindows: "[]")
    let presenter = makePresenter(table: table, timeZone: try timeZone("UTC"))

    let display = presenter.display(at: try instant("2026-09-28T12:00:00Z"))

    #expect(display.periodLabel == "Off-peak")
    #expect(display.multiplierLabel == "50% off")
    #expect(display.windowEndsLocal == "—")
    #expect(display.nextTransitionLocal == "—")
    #expect(display.countdown == "—")
  }
}

// MARK: - Holidays

@Suite("Rate-now holidays")
struct RateNowHolidayTests {
  @Test("a holiday inside the window reads off-peak with the holiday note")
  func holidayOverridesPeak() throws {
    let table = try fixtureTable()
    // 2026-09-28 is a Monday inside the 01:00-04:00 UTC window and an injected CN holiday.
    let presenter = makePresenter(
      table: table,
      timeZone: try timeZone("UTC"),
      holidayCalendar: HolidayCalendar(source: "fixture", dates: ["2026-09-28"])
    )

    let display = presenter.display(at: try instant("2026-09-28T02:30:00Z"))

    #expect(display.isHoliday)
    #expect(display.holidayNote == "CN public holiday")
    #expect(display.periodLabel == "Off-peak")
    #expect(display.multiplierLabel == "50% off")
    #expect(display.models.first?.cacheHit == Decimal.parse("0.003"))
    // The holiday covers the whole Shanghai day, so peak resumes Tuesday 01:00Z.
    #expect(display.windowEndsLocal == "01:00")
    #expect(display.nextTransitionLocal == "Tue 01:00")
    #expect(display.countdown == "22h 30m")
  }

  @Test("a non-holiday instant carries no note")
  func ordinaryDayHasNoNote() throws {
    let table = try fixtureTable()
    let presenter = makePresenter(
      table: table,
      timeZone: try timeZone("UTC"),
      holidayCalendar: HolidayCalendar(source: "fixture", dates: ["2026-10-01"])
    )

    let display = presenter.display(at: try instant("2026-09-28T02:30:00Z"))

    #expect(!display.isHoliday)
    #expect(display.holidayNote == nil)
  }
}

// MARK: - Countdown

@Suite("Rate-now countdown")
struct RateNowCountdownTests {
  private func countdown(from iso8601: String) throws -> String {
    let table = try fixtureTable()
    let presenter = makePresenter(table: table, timeZone: try timeZone("UTC"))
    return presenter.display(at: try instant(iso8601)).countdown
  }

  /// The peak window closes at 04:00Z on Monday 2026-09-28.
  @Test("60 seconds left floors to 1m")
  func sixtySeconds() throws {
    #expect(try countdown(from: "2026-09-28T03:59:00Z") == "1m")
  }

  @Test("59 seconds left floors to 0m")
  func fiftyNineSeconds() throws {
    #expect(try countdown(from: "2026-09-28T03:59:01Z") == "0m")
  }

  @Test("minutes are floored, not rounded")
  func floorsToWholeMinutes() throws {
    // 150 s and 119 s on either side of a whole minute.
    #expect(try countdown(from: "2026-09-28T03:57:30Z") == "2m")
    #expect(try countdown(from: "2026-09-28T03:58:01Z") == "1m")
  }

  @Test("an hour or more keeps the hours and the remainder")
  func hoursAndMinutes() throws {
    #expect(try countdown(from: "2026-09-28T01:46:00Z") == "2h 14m")
  }
}

// MARK: - Prices

@Suite("Rate-now prices")
struct RateNowPriceTests {
  /// 2026-09-28 02:30Z is peak, 12:00Z is off-peak, and both are Mondays.
  @Test("rows keep the table's order and off-peak is exactly half of peak")
  func orderAndHalves() throws {
    // Reversed order on purpose: the presenter must not sort or re-rank the table.
    let table = try fixtureTable(models: [proModelJSON, flashModelJSON])
    let presenter = makePresenter(table: table, timeZone: try timeZone("UTC"))

    let peak = presenter.display(at: try instant("2026-09-28T02:30:00Z"))
    let offPeak = presenter.display(at: try instant("2026-09-28T12:00:00Z"))

    #expect(peak.models.map(\.model) == ["deepseek-v4-pro", "deepseek-flash"])
    #expect(offPeak.models.map(\.model) == ["deepseek-v4-pro", "deepseek-flash"])
    #expect(peak.models.map(\.model) == table.models.map(\.model))

    let half = Decimal.parse("0.5")
    #expect(peak.models.count == offPeak.models.count)
    for (peakRate, offPeakRate) in zip(peak.models, offPeak.models) {
      #expect(offPeakRate.model == peakRate.model)
      #expect(offPeakRate.cacheHit == peakRate.cacheHit * half)
      #expect(offPeakRate.cacheMiss == peakRate.cacheMiss * half)
      #expect(offPeakRate.output == peakRate.output * half)
    }

    // The numbers the popover shows for the shipped flash row.
    #expect(offPeak.models.last?.cacheHit == Decimal.parse("0.003"))
    #expect(offPeak.models.last?.cacheMiss == Decimal.parse("0.15"))
  }
}
