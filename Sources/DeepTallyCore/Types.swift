// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Provenance

/// Where a usage record came from. Billing trust differs per source, so this is stored, not inferred.
public enum UsageSource: String, Codable, Sendable, CaseIterable {
  case proxy
  case opencode
  case csv
  case manual
}

/// Which gateway actually served a request. Only `.deepseek` maps to the account balance.
public enum Provider: String, Codable, Sendable, CaseIterable {
  case deepseek
  case kilo
  case openrouter
  case unknown
}

// MARK: - Balance

/// One currency entry of `GET /user/balance`. Amounts arrive as strings and are kept as `Decimal`.
public struct BalanceInfo: Sendable, Equatable, Codable {
  public let currency: String
  public let totalBalance: Decimal
  public let grantedBalance: Decimal
  public let toppedUpBalance: Decimal

  public init(
    currency: String, totalBalance: Decimal, grantedBalance: Decimal, toppedUpBalance: Decimal
  ) {
    self.currency = currency
    self.totalBalance = totalBalance
    self.grantedBalance = grantedBalance
    self.toppedUpBalance = toppedUpBalance
  }

  private enum CodingKeys: String, CodingKey {
    case currency
    case totalBalance = "total_balance"
    case grantedBalance = "granted_balance"
    case toppedUpBalance = "topped_up_balance"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    currency = try container.decode(String.self, forKey: .currency)
    totalBalance = Decimal.parse(try container.decode(String.self, forKey: .totalBalance))
    grantedBalance = Decimal.parse(try container.decode(String.self, forKey: .grantedBalance))
    toppedUpBalance = Decimal.parse(try container.decode(String.self, forKey: .toppedUpBalance))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(currency, forKey: .currency)
    try container.encode("\(totalBalance)", forKey: .totalBalance)
    try container.encode("\(grantedBalance)", forKey: .grantedBalance)
    try container.encode("\(toppedUpBalance)", forKey: .toppedUpBalance)
  }

}

extension Decimal {
  /// Every monetary value in this project is a JSON **string** — DeepSeek returns amounts as strings
  /// and `PriceTable.json` follows the same convention to avoid float drift. Parse them here, once.
  static func parse(_ raw: String) -> Decimal {
    Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) ?? .zero
  }
}

public struct Balance: Sendable, Equatable, Codable {
  public let isAvailable: Bool
  public let infos: [BalanceInfo]

  public init(isAvailable: Bool, infos: [BalanceInfo]) {
    self.isAvailable = isAvailable
    self.infos = infos
  }

  /// First entry wins; DeepSeek returns a single entry in practice.
  public var primary: BalanceInfo? { infos.first }

  private enum CodingKeys: String, CodingKey {
    case isAvailable = "is_available"
    case infos = "balance_infos"
  }
}

// MARK: - Models

public struct ModelInfo: Sendable, Equatable, Codable {
  public let id: String
  public let ownedBy: String?

  public init(id: String, ownedBy: String? = nil) {
    self.id = id
    self.ownedBy = ownedBy
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case ownedBy = "owned_by"
  }
}

// MARK: - Token usage

/// Per-response usage as returned by DeepSeek's chat completions.
/// `promptTokens == cacheHitTokens + cacheMissTokens`.
public struct TokenUsage: Sendable, Equatable, Codable {
  public let promptTokens: Int
  public let completionTokens: Int
  public let totalTokens: Int
  public let cacheHitTokens: Int
  public let cacheMissTokens: Int
  public let reasoningTokens: Int

  public init(
    promptTokens: Int,
    completionTokens: Int,
    totalTokens: Int? = nil,
    cacheHitTokens: Int,
    cacheMissTokens: Int,
    reasoningTokens: Int = 0
  ) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens ?? (promptTokens + completionTokens)
    self.cacheHitTokens = cacheHitTokens
    self.cacheMissTokens = cacheMissTokens
    self.reasoningTokens = reasoningTokens
  }

  /// Cache-hit ratio in `0...1`, or `nil` when the request had no prompt tokens to classify.
  public var cacheHitRatio: Double? {
    let denominator = cacheHitTokens + cacheMissTokens
    guard denominator > 0 else { return nil }
    return Double(cacheHitTokens) / Double(denominator)
  }

  private enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
    case cacheHitTokens = "prompt_cache_hit_tokens"
    case cacheMissTokens = "prompt_cache_miss_tokens"
    case completionTokensDetails = "completion_tokens_details"
  }

  private struct CompletionDetails: Sendable, Codable {
    let reasoningTokens: Int

    private enum CodingKeys: String, CodingKey {
      case reasoningTokens = "reasoning_tokens"
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
    completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
    cacheHitTokens = try container.decodeIfPresent(Int.self, forKey: .cacheHitTokens) ?? 0
    cacheMissTokens = try container.decodeIfPresent(Int.self, forKey: .cacheMissTokens) ?? 0
    totalTokens =
      try container.decodeIfPresent(Int.self, forKey: .totalTokens)
      ?? (promptTokens + completionTokens)
    let details = try container.decodeIfPresent(
      CompletionDetails.self, forKey: .completionTokensDetails)
    reasoningTokens = details?.reasoningTokens ?? 0
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(promptTokens, forKey: .promptTokens)
    try container.encode(completionTokens, forKey: .completionTokens)
    try container.encode(totalTokens, forKey: .totalTokens)
    try container.encode(cacheHitTokens, forKey: .cacheHitTokens)
    try container.encode(cacheMissTokens, forKey: .cacheMissTokens)
    try container.encode(
      CompletionDetails(reasoningTokens: reasoningTokens), forKey: .completionTokensDetails)
  }
}

/// A single observed request, ready for the ledger.
public struct UsageRecord: Sendable, Equatable, Codable {
  public let timestamp: Date
  public let source: UsageSource
  public let provider: Provider
  public let model: String
  public let usage: TokenUsage
  public let costUSD: Decimal
  public let sessionID: String?

  public init(
    timestamp: Date,
    source: UsageSource,
    provider: Provider,
    model: String,
    usage: TokenUsage,
    costUSD: Decimal,
    sessionID: String? = nil
  ) {
    self.timestamp = timestamp
    self.source = source
    self.provider = provider
    self.model = model
    self.usage = usage
    self.costUSD = costUSD
    self.sessionID = sessionID
  }
}

// MARK: - Pricing and peak / off-peak

/// A daily UTC window (start inclusive, end exclusive) in which peak prices apply.
public struct PeakWindow: Sendable, Equatable, Codable {
  public let startHourUTC: Int
  public let endHourUTC: Int

  public init(startHourUTC: Int, endHourUTC: Int) {
    self.startHourUTC = startHourUTC
    self.endHourUTC = endHourUTC
  }

  private enum CodingKeys: String, CodingKey {
    case startHourUTC = "start_hour_utc"
    case endHourUTC = "end_hour_utc"
  }
}

public enum RatePeriod: String, Sendable, Codable {
  case peak
  case offPeak
}

/// What the account is paying *right now*, plus when that changes.
public struct RateSnapshot: Sendable, Equatable {
  public let period: RatePeriod
  /// 1.0 in peak, `offPeakMultiplier` (0.5) off-peak.
  public let multiplier: Decimal
  public let nextTransition: Date?
  public let isHoliday: Bool

  public init(period: RatePeriod, multiplier: Decimal, nextTransition: Date?, isHoliday: Bool) {
    self.period = period
    self.multiplier = multiplier
    self.nextTransition = nextTransition
    self.isHoliday = isHoliday
  }
}

/// Peak prices in USD per 1M tokens. Off-peak is derived via `PriceTable.offPeakMultiplier`.
public struct ModelPrice: Sendable, Equatable, Codable {
  public let model: String
  public let cacheHitUSDPerMillion: Decimal
  public let cacheMissUSDPerMillion: Decimal
  public let outputUSDPerMillion: Decimal

  public init(
    model: String,
    cacheHitUSDPerMillion: Decimal,
    cacheMissUSDPerMillion: Decimal,
    outputUSDPerMillion: Decimal
  ) {
    self.model = model
    self.cacheHitUSDPerMillion = cacheHitUSDPerMillion
    self.cacheMissUSDPerMillion = cacheMissUSDPerMillion
    self.outputUSDPerMillion = outputUSDPerMillion
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case cacheHitUSDPerMillion = "cache_hit_usd_per_million"
    case cacheMissUSDPerMillion = "cache_miss_usd_per_million"
    case outputUSDPerMillion = "output_usd_per_million"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try container.decode(String.self, forKey: .model)
    cacheHitUSDPerMillion = Decimal.parse(
      try container.decode(String.self, forKey: .cacheHitUSDPerMillion))
    cacheMissUSDPerMillion = Decimal.parse(
      try container.decode(String.self, forKey: .cacheMissUSDPerMillion))
    outputUSDPerMillion = Decimal.parse(
      try container.decode(String.self, forKey: .outputUSDPerMillion))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode("\(cacheHitUSDPerMillion)", forKey: .cacheHitUSDPerMillion)
    try container.encode("\(cacheMissUSDPerMillion)", forKey: .cacheMissUSDPerMillion)
    try container.encode("\(outputUSDPerMillion)", forKey: .outputUSDPerMillion)
  }
}

/// Versioned data, not code. `Resources/PriceTable.json` is the shipped default and users may override it.
public struct PriceTable: Sendable, Equatable, Codable {
  public let version: String
  public let currency: String
  public let effectiveFrom: String
  public let offPeakMultiplier: Decimal
  public let peakWindowsUTC: [PeakWindow]
  /// `YYYY-MM-DD` dates (Asia/Shanghai) treated as full off-peak days.
  public let holidays: [String]
  public let models: [ModelPrice]

  public init(
    version: String,
    currency: String,
    effectiveFrom: String,
    offPeakMultiplier: Decimal,
    peakWindowsUTC: [PeakWindow],
    holidays: [String],
    models: [ModelPrice]
  ) {
    self.version = version
    self.currency = currency
    self.effectiveFrom = effectiveFrom
    self.offPeakMultiplier = offPeakMultiplier
    self.peakWindowsUTC = peakWindowsUTC
    self.holidays = holidays
    self.models = models
  }

  public func price(forModel model: String) -> ModelPrice? {
    models.first { $0.model == model }
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case currency
    case effectiveFrom = "effective_from"
    case offPeakMultiplier = "off_peak_multiplier"
    case peakWindowsUTC = "peak_windows_utc"
    case holidays
    case models
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(String.self, forKey: .version)
    currency = try container.decode(String.self, forKey: .currency)
    effectiveFrom = try container.decode(String.self, forKey: .effectiveFrom)
    offPeakMultiplier = Decimal.parse(try container.decode(String.self, forKey: .offPeakMultiplier))
    peakWindowsUTC = try container.decode([PeakWindow].self, forKey: .peakWindowsUTC)
    holidays = try container.decodeIfPresent([String].self, forKey: .holidays) ?? []
    models = try container.decodeIfPresent([ModelPrice].self, forKey: .models) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(currency, forKey: .currency)
    try container.encode(effectiveFrom, forKey: .effectiveFrom)
    try container.encode("\(offPeakMultiplier)", forKey: .offPeakMultiplier)
    try container.encode(peakWindowsUTC, forKey: .peakWindowsUTC)
    try container.encode(holidays, forKey: .holidays)
    try container.encode(models, forKey: .models)
  }
}
