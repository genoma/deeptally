// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Answers the peak/off-peak question and the effective prices the rate panel shows.
public struct CostEngine: Sendable {
  /// The peak/off-peak decision this engine resolves rates with.
  public let peakOffPeak: PeakOffPeakEngine

  private let table: PriceTable

  public init(table: PriceTable, holidayCalendar: HolidayCalendar) {
    self.table = table
    self.peakOffPeak = PeakOffPeakEngine(table: table, holidayCalendar: holidayCalendar)
  }

  /// Uses only the `holidays` embedded in the table; see `PeakOffPeakEngine.init(table:)`.
  public init(table: PriceTable) {
    self.init(
      table: table,
      holidayCalendar: HolidayCalendar(source: "PriceTable.json", dates: table.holidays)
    )
  }

  /// The effective hit / miss / output prices in USD per 1M tokens right now, multiplier included.
  /// `.zero` for a model absent from the table: an unpriced model has no rate to show, never a
  /// guessed one.
  public func currentRates(
    model: String,
    at date: Date
  ) -> (cacheHit: Decimal, cacheMiss: Decimal, output: Decimal) {
    guard let price = table.price(forModel: model) else { return (0, 0, 0) }
    let multiplier = peakOffPeak.multiplier(at: date)
    return (
      price.cacheHitUSDPerMillion * multiplier,
      price.cacheMissUSDPerMillion * multiplier,
      price.outputUSDPerMillion * multiplier
    )
  }
}
