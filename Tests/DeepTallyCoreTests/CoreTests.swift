// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

@Suite("Balance decoding")
struct BalanceDecodingTests {
  @Test("decodes string amounts from the balance endpoint")
  func decodesStringAmounts() throws {
    let json = #"""
      {
        "is_available": true,
        "balance_infos": [
          {
            "currency": "USD",
            "total_balance": "42.50",
            "granted_balance": "1.25",
            "topped_up_balance": "41.25"
          }
        ]
      }
      """#

    let balance = try JSONDecoder().decode(Balance.self, from: Data(json.utf8))

    #expect(balance.isAvailable)
    #expect(balance.primary?.currency == "USD")
    #expect(balance.primary?.totalBalance == Decimal(string: "42.50"))
    #expect(balance.primary?.grantedBalance == Decimal(string: "1.25"))
    #expect(balance.primary?.toppedUpBalance == Decimal(string: "41.25"))
  }
}

@Suite("Price table")
struct PriceTableTests {
  @Test("loads the shipped placeholder without crashing")
  func loadsPlaceholder() throws {
    let json = #"""
      {
        "version": "test",
        "currency": "USD",
        "effective_from": "2026-09-24",
        "off_peak_multiplier": "0.5",
        "peak_windows_utc": [{ "start_hour_utc": 1, "end_hour_utc": 4 }],
        "holidays": ["2026-10-01"],
        "models": [
          {
            "model": "deepseek-flash",
            "cache_hit_usd_per_million": "0.006",
            "cache_miss_usd_per_million": "0.30",
            "output_usd_per_million": "1.20"
          }
        ]
      }
      """#

    let table = try JSONDecoder().decode(PriceTable.self, from: Data(json.utf8))

    #expect(table.offPeakMultiplier == Decimal(string: "0.5"))
    #expect(table.peakWindowsUTC.count == 1)
    #expect(
      table.price(forModel: "deepseek-flash")?.cacheHitUSDPerMillion == Decimal(string: "0.006"))
    #expect(table.price(forModel: "does-not-exist") == nil)
  }
}

@Suite("Shipped pricing + holiday data")
struct ShippedDataTests {
  private func instant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  private func engine() throws -> PeakOffPeakEngine {
    let table = try PriceTableLoader().loadBundled()
    let holidays = try HolidayCalendar.loadBundled()
      .merging(HolidayCalendar(source: "PriceTable.json", dates: table.holidays))
    return PeakOffPeakEngine(table: table, holidayCalendar: holidays)
  }

  @Test("a weekday inside a shipped public holiday is off-peak")
  func holidayOverridesWeekday() throws {
    // 2026-10-01 is a Thursday inside the 01:00-04:00Z peak window, but National Day in the
    // shipped State Council list, so it must price as off-peak.
    let snapshot = try engine().classify(instant("2026-10-01T02:00:00Z"))

    #expect(snapshot.isHoliday)
    #expect(snapshot.period == .offPeak)
    #expect(snapshot.multiplier == Decimal(string: "0.5"))
  }

  @Test("an ordinary weekday in the same window is peak")
  func ordinaryWeekdayIsPeak() throws {
    // 2026-09-24 is a Thursday and not a public holiday.
    let snapshot = try engine().classify(instant("2026-09-24T02:00:00Z"))

    #expect(!snapshot.isHoliday)
    #expect(snapshot.period == .peak)
    #expect(snapshot.multiplier == 1)
  }
}
