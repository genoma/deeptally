// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Schema of `Resources/ChinaHolidays.json`.
private struct ChinaHolidayList: Decodable {
  let source: String?
  let dates: [String]?
}

/// Chinese public holidays, keyed by the Asia/Shanghai calendar day.
///
/// Peak/off-peak classification is a UTC question, but "is this day a holiday" is a Chinese-calendar
/// question (AGENTS.md §9.9): ask this type, never local-time arithmetic.
public struct HolidayCalendar: Sendable, Equatable {
  /// Provenance for the UI and for diagnostics, e.g. the State Council announcement URL.
  public let source: String
  /// `YYYY-MM-DD` dates in Asia/Shanghai. Entries in any other shape simply never match.
  public let dates: [String]

  public init(source: String = "", dates: [String] = []) {
    self.source = source
    self.dates = dates
  }

  /// True when no dates are listed. An empty calendar treats every day as a working day.
  public var isEmpty: Bool { dates.isEmpty }

  /// True when the Asia/Shanghai calendar day containing `date` is listed.
  public func isHoliday(containing date: Date) -> Bool {
    guard !dates.isEmpty else { return false }
    return dates.contains(Self.shanghaiDay(for: date))
  }

  /// Union of two calendars: used to combine the shipped list with dates embedded in a price table.
  /// Duplicates are dropped; the sources are joined so provenance survives.
  public func merging(_ other: HolidayCalendar) -> HolidayCalendar {
    var merged = dates
    var seen = Set(dates)
    for date in other.dates where seen.insert(date).inserted {
      merged.append(date)
    }
    return HolidayCalendar(source: Self.joinedSource(source, other.source), dates: merged)
  }

  /// `Resources/ChinaHolidays.json`.
  public static func loadBundled() throws -> HolidayCalendar {
    let name = "ChinaHolidays.json"
    guard let url = Bundle.module.url(forResource: "ChinaHolidays", withExtension: "json") else {
      throw PricingDataError.resourceMissing(name: name)
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw PricingDataError.resourceMissing(name: name)
    }
    return try decode(data, name: name)
  }

  /// Decodes one holiday list. `name` only appears in thrown errors.
  static func decode(_ data: Data, name: String) throws -> HolidayCalendar {
    let list: ChinaHolidayList
    do {
      list = try JSONDecoder().decode(ChinaHolidayList.self, from: data)
    } catch {
      throw PricingDataError.decodeFailed(name: name, detail: String(describing: error))
    }
    return HolidayCalendar(source: list.source ?? "", dates: list.dates ?? [])
  }

  /// The Asia/Shanghai calendar day containing `date`, as `YYYY-MM-DD`.
  static func shanghaiDay(for date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = shanghaiTimeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  /// China Standard Time is UTC+8 all year (no DST), so a Shanghai day is UTC 16:00 → 16:00.
  static let shanghaiTimeZone =
    TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .current

  /// The UTC hour at which the Asia/Shanghai day rolls over.
  static let utcHourOfShanghaiMidnight = 16

  private static func joinedSource(_ lhs: String, _ rhs: String) -> String {
    if lhs.isEmpty { return rhs }
    if rhs.isEmpty { return lhs }
    return "\(lhs), \(rhs)"
  }
}
