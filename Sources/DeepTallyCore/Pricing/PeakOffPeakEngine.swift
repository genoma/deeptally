// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Answers "what am I paying right now?" for one price table.
///
/// The rules, in order:
/// 1. The declared windows (`peak_windows_utc`) are **UTC hours**, so the Monday–Friday test is
///    applied in UTC as well. A window's start is inclusive, its end exclusive.
/// 2. A date listed in `holidayCalendar` is off-peak for the whole Asia/Shanghai day, even when the
///    weekday and the window would say peak.
/// 3. Everything else is off-peak at the table's `off_peak_multiplier`.
public struct PeakOffPeakEngine: Sendable {
  public let table: PriceTable
  public let holidayCalendar: HolidayCalendar

  public init(table: PriceTable, holidayCalendar: HolidayCalendar) {
    self.table = table
    self.holidayCalendar = holidayCalendar
  }

  /// Uses only the `holidays` embedded in the table. The shipped file keeps that list empty; the
  /// State Council list lives in `ChinaHolidays.json` and is merged in by the caller.
  public init(table: PriceTable) {
    self.init(
      table: table,
      holidayCalendar: HolidayCalendar(source: "PriceTable.json", dates: table.holidays)
    )
  }

  /// Classifies one instant and reports the exact next boundary change.
  public func classify(_ date: Date) -> RateSnapshot {
    let period = period(at: date)
    return RateSnapshot(
      period: period,
      multiplier: multiplier(for: period),
      nextTransition: nextTransition(after: date),
      isHoliday: holidayCalendar.isHoliday(containing: date)
    )
  }

  func period(at date: Date) -> RatePeriod {
    if holidayCalendar.isHoliday(containing: date) { return .offPeak }
    guard isWeekdayUTC(date), isInPeakWindowUTC(date) else { return .offPeak }
    return .peak
  }

  /// The price factor in force at `date`. Cheaper than `classify(_:)`, which also searches for the
  /// next transition; the cost engine needs only this, once per ledger row.
  func multiplier(at date: Date) -> Decimal {
    multiplier(for: period(at: date))
  }

  /// The single place that maps a period to its price factor.
  private func multiplier(for period: RatePeriod) -> Decimal {
    period == .peak ? 1 : table.offPeakMultiplier
  }

  // MARK: - Lookups

  /// `Calendar` numbers weekdays 1 = Sunday … 7 = Saturday, in the calendar's time zone.
  private func isWeekdayUTC(_ date: Date) -> Bool {
    let weekday = Self.utcCalendar().component(.weekday, from: date)
    return weekday >= 2 && weekday <= 6
  }

  private func isInPeakWindowUTC(_ date: Date) -> Bool {
    let hour = Self.utcCalendar().component(.hour, from: date)
    return table.peakWindowsUTC.contains { window in
      hour >= window.startHourUTC && hour < window.endHourUTC
    }
  }

  // MARK: - Transitions

  /// The next instant at which `period(at:)` changes, or `nil` when none is found within
  /// ``transitionSearchDays`` — impossible with a weekly window pattern, but the signature does not
  /// have to pretend otherwise.
  ///
  /// The period depends only on three inputs: the UTC weekday, the UTC hour and the Asia/Shanghai
  /// day. Each of those changes only when the UTC clock crosses one of the boundary hours below, so
  /// the period is constant between two consecutive boundary instants and the first boundary with a
  /// different period is the exact transition.
  private func nextTransition(after date: Date) -> Date? {
    let current = period(at: date)
    var boundaryHours: Set<Int> = [0, HolidayCalendar.utcHourOfShanghaiMidnight]
    for window in table.peakWindowsUTC {
      boundaryHours.insert(window.startHourUTC)
      boundaryHours.insert(window.endHourUTC)
    }

    let currentHour = Int((date.timeIntervalSince1970 / 3600).rounded(.down))
    for offset in 1...(Self.transitionSearchDays * 24) {
      let hourIndex = currentHour + offset
      guard boundaryHours.contains(Self.utcHourOfDay(hourIndex)) else { continue }
      let instant = Date(timeIntervalSince1970: Double(hourIndex) * 3600)
      if period(at: instant) != current { return instant }
    }
    return nil
  }

  /// Unix time counts whole hours from a UTC midnight, so UTC hour boundaries need no calendar.
  private static func utcHourOfDay(_ hourIndex: Int) -> Int {
    ((hourIndex % 24) + 24) % 24
  }

  /// Two weeks of hourly candidates always contain a boundary change; the weekday, window and
  /// holiday pattern repeats within one week.
  private static let transitionSearchDays = 14

  private static func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
  }
}
