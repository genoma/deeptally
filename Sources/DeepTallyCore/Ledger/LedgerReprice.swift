// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What ``LedgerStore/reprice(costing:)`` prices stored rows with.
///
/// A row's cost is computed once, when the row is imported, and stored beside its tokens. A row whose
/// model id did not resolve at that moment stays at zero forever, because `raw_hash` makes a re-import
/// a duplicate: correct for counting, useless for repair. Repricing is the repair, and this protocol
/// is the whole of what the ledger needs from the pricing layer to perform one. ``CostEngine``
/// conforms.
public protocol RowCosting: Sendable {
  /// The table these costs come from. A reprice records it in `meta`, so a caller holding a
  /// ``PriceTable`` can compare versions and tell whether repricing is worthwhile. The empty string
  /// means "unnamed" and is not recorded.
  var priceTableVersion: String { get }

  /// USD for one row, or `nil` when this costing cannot price `model` at all.
  ///
  /// `nil` is not zero. It means the model id resolved to nothing, and the row's stored cost is left
  /// exactly as it is: a id the table has since dropped may well have been priced by an older table,
  /// and overwriting that measurement with zero would destroy it. The row is counted and reported as
  /// unpriced instead, and a human decides.
  func costIfPriced(model: String, usage: TokenUsage, at timestamp: Date) -> Decimal?
}

extension CostEngine: RowCosting {
  public var priceTableVersion: String { peakOffPeak.table.version }

  /// `cost(model:usage:at:)` answers `.zero` for a model the table does not list — indistinguishable
  /// from a genuinely free one — so "is this id priced?" is asked through `price(forModel:)`, which is
  /// the same resolution the engine then bills with.
  public func costIfPriced(model: String, usage: TokenUsage, at timestamp: Date) -> Decimal? {
    guard peakOffPeak.table.price(forModel: model) != nil else { return nil }
    return cost(model: model, usage: usage, at: timestamp)
  }
}

/// One model id the ledger holds rows for and the current price table cannot price.
///
/// Grouped by model id alone rather than by `(provider, model)`: pricing resolves on the id, so one id
/// is one line here no matter which gateway reported the request.
public struct UnpricedModel: Sendable, Equatable {
  /// The id exactly as the rows store it — the string to add to `PriceTable.json`.
  public let model: String
  public let rows: Int
  /// What those rows carry today, in the price table's currency (USD today). Zero is the measured
  /// failure mode: nothing resolved, so nothing was ever billed.
  public let spendUSD: Decimal

  public init(model: String, rows: Int, spendUSD: Decimal) {
    self.model = model
    self.rows = rows
    self.spendUSD = spendUSD
  }
}

/// What a scan of the raw rows found that the current price table does not explain.
public struct UnpricedSummary: Sendable, Equatable {
  /// Every raw row the scan read.
  public let rowsExamined: Int
  public let rowsUnpriced: Int
  /// Biggest gap first, ties by model id, so two runs over one ledger print the same list.
  public let models: [UnpricedModel]

  public init(rowsExamined: Int, rowsUnpriced: Int, models: [UnpricedModel]) {
    self.rowsExamined = rowsExamined
    self.rowsUnpriced = rowsUnpriced
    self.models = models
  }

  /// True when every row the scan saw has a price.
  public var isComplete: Bool { rowsUnpriced == 0 }
}

/// What one ``LedgerStore/reprice(costing:)`` pass did.
public struct RepriceOutcome: Sendable, Equatable {
  /// Every raw row the pass read.
  public let rowsExamined: Int
  /// Rows whose stored cost the pass rewrote. Rows already correct are not touched.
  public let rowsChanged: Int
  /// Rows no cost could be computed for. Their stored cost is unchanged, deliberately.
  public let rowsUnpriced: Int
  /// The model ids behind ``rowsUnpriced``, biggest gap first. Empty when nothing is unpriced.
  public let unpricedModels: [UnpricedModel]
  /// Total of the raw rows this pass examined, before it changed anything.
  public let spendBeforeUSD: Decimal
  /// The same total after the pass.
  public let spendAfterUSD: Decimal
  /// The price table the recomputed costs came from; `""` when the costing did not name one.
  public let priceTableVersion: String
  /// What `meta` recorded before this pass, or `nil` when the ledger had never been repriced — which
  /// is how a caller tells "the costs already come from this table" from "this is the first reprice".
  public let previousPriceTableVersion: String?

  public init(
    rowsExamined: Int,
    rowsChanged: Int,
    rowsUnpriced: Int,
    unpricedModels: [UnpricedModel],
    spendBeforeUSD: Decimal,
    spendAfterUSD: Decimal,
    priceTableVersion: String,
    previousPriceTableVersion: String?
  ) {
    self.rowsExamined = rowsExamined
    self.rowsChanged = rowsChanged
    self.rowsUnpriced = rowsUnpriced
    self.unpricedModels = unpricedModels
    self.spendBeforeUSD = spendBeforeUSD
    self.spendAfterUSD = spendAfterUSD
    self.priceTableVersion = priceTableVersion
    self.previousPriceTableVersion = previousPriceTableVersion
  }

  /// How much the ledger's raw rows are worth now, minus what they were worth before.
  public var spendDeltaUSD: Decimal { spendAfterUSD - spendBeforeUSD }

  /// True when the pass found every row already correct: repricing again with the same costing can
  /// only report this.
  public var madeNoChanges: Bool { rowsChanged == 0 }
}
