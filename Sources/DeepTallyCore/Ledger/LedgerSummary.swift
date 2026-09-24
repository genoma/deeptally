// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One model's share of a ``LedgerSummary``.
///
/// The token columns mirror `request`: `input` is the cache-miss prompt count (`cache_write` folded
/// in, see ``LedgerStore``), `output` excludes `reasoning`, and prompt tokens are the sum of all
/// three prompt-side columns.
public struct LedgerModelTotals: Sendable, Equatable {
  public let provider: Provider
  public let model: String
  /// Spend in the price table's currency (USD today), exact: it is a sum of micro-USD integers.
  public let spendUSD: Decimal
  public let inputTokens: Int
  public let outputTokens: Int
  public let reasoningTokens: Int
  public let cacheReadTokens: Int
  public let cacheWriteTokens: Int
  public let requestCount: Int

  public init(
    provider: Provider,
    model: String,
    spendUSD: Decimal,
    inputTokens: Int,
    outputTokens: Int,
    reasoningTokens: Int,
    cacheReadTokens: Int,
    cacheWriteTokens: Int,
    requestCount: Int
  ) {
    self.provider = provider
    self.model = model
    self.spendUSD = spendUSD
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.requestCount = requestCount
  }

  /// DeepSeek's prompt total: every prompt token, cached or not.
  public var promptTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens }

  /// Cache-hit tokens over prompt tokens, or `nil` when the rows carried no prompt tokens at all:
  /// a ratio with no denominator is not zero, it is unknown, and a menu bar that shows 0% for it
  /// would be lying.
  public var cacheHitRatio: Double? {
    let prompt = promptTokens
    guard prompt > 0 else { return nil }
    return Double(cacheReadTokens) / Double(prompt)
  }
}

/// What a range of the ledger adds up to, plus a per-model breakdown.
///
/// The totals are the sum of ``models``, so the breakdown and the headline can never disagree.
public struct LedgerSummary: Sendable, Equatable {
  /// One row per `(provider, model)`, ordered by provider then model — a stable order, independent
  /// of the amounts, so two runs and two machines print the same table.
  public let models: [LedgerModelTotals]

  public init(models: [LedgerModelTotals]) {
    self.models = models
  }

  /// Total spend in the price table's currency (USD today).
  public var spendUSD: Decimal { models.reduce(Decimal.zero) { $0 + $1.spendUSD } }

  public var inputTokens: Int { models.reduce(0) { $0 + $1.inputTokens } }
  public var outputTokens: Int { models.reduce(0) { $0 + $1.outputTokens } }
  public var reasoningTokens: Int { models.reduce(0) { $0 + $1.reasoningTokens } }
  public var cacheReadTokens: Int { models.reduce(0) { $0 + $1.cacheReadTokens } }
  public var cacheWriteTokens: Int { models.reduce(0) { $0 + $1.cacheWriteTokens } }
  public var requestCount: Int { models.reduce(0) { $0 + $1.requestCount } }

  /// Every prompt token in the range.
  public var promptTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens }

  /// The whole range's cache-hit ratio, or `nil` when no prompt tokens were recorded.
  public var cacheHitRatio: Double? {
    let prompt = promptTokens
    guard prompt > 0 else { return nil }
    return Double(cacheReadTokens) / Double(prompt)
  }
}
