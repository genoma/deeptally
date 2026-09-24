// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Prices token usage at whatever rate was in force when the request happened.
///
/// DeepSeek bills cache hits, cache misses and output. Cache *writes* are recorded upstream by the
/// ledger but are never billed, so they cannot appear in this formula.
public struct CostEngine: Sendable {
  /// The peak/off-peak decision this engine prices with.
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

  /// USD for one request: `(hit*hit + miss*miss + output*out) / 1M * multiplier`.
  ///
  /// Reasoning tokens are billed as output and are already inside `usage.completionTokens`. A model
  /// absent from the table (retired or renamed) costs `.zero`; callers that must tell "unpriced"
  /// from "free" should check `table.price(forModel:)` first.
  public func cost(model: String, usage: TokenUsage, at date: Date) -> Decimal {
    guard let price = table.price(forModel: model) else { return .zero }
    let peakCost =
      (Decimal(usage.cacheHitTokens) * price.cacheHitUSDPerMillion
        + Decimal(usage.cacheMissTokens) * price.cacheMissUSDPerMillion
        + Decimal(usage.completionTokens) * price.outputUSDPerMillion) / Self.tokensPerMillion
    return peakCost * peakOffPeak.multiplier(at: date)
  }

  /// The effective hit / miss / output prices in USD per 1M tokens right now, multiplier included.
  /// `.zero` for a model absent from the table, matching ``cost(model:usage:at:)``.
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

  private static let tokensPerMillion = Decimal(1_000_000)
}
