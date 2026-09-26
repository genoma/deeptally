// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which store answered for one UTC day of a ``LedgerUsageWindow``.
public enum LedgerDaySource: String, Sendable, Equatable {
  /// `request` still holds the day's rows, so they were aggregated directly.
  case rawRows
  /// The day's raw rows are gone — pruned — and the day came from `daily`, the UTC-day rollup.
  case rollup
}

/// One UTC day of a ``LedgerUsageWindow``.
///
/// The day is a whole UTC day, because that is the only day `daily` knows. A caller who needs a local
/// day asks ``LedgerStore/summary(since:until:provider:)`` with a range built from its own calendar.
public struct LedgerDayUsage: Sendable, Equatable {
  /// The UTC date in `YYYY-MM-DD` form, the spelling `daily.date` uses.
  public let date: String
  /// ``date`` at UTC midnight: the day begins there and ends 86 400 seconds later.
  public let dayStart: Date
  public let source: LedgerDaySource
  /// What the day contributed: every model the day used, ordered as
  /// ``LedgerStore/summary(since:until:provider:)`` orders them. A ``LedgerDaySource/rawRows`` day that
  /// the range only partly covers carries that part and nothing else — the rollup never answers for a
  /// partial day.
  public let summary: LedgerSummary
}

/// A half-open range read as the UTC days it touches.
///
/// This is what keeps long-range history visible after ``LedgerStore/pruneRawRequests(olderThanDays:now:)``:
/// a day whose raw rows are still in `request` is aggregated exactly as ``LedgerStore/summary(since:until:provider:)``
/// would, and a day whose raw rows are gone is read from `daily`, which holds whole UTC days only.
///
/// The property that matters for honesty is that no number here is ever derived from a partial day:
/// a day the range only half covers is either answered from its raw rows or, when the rollup holds rows
/// for it, named in ``unavailableDays`` instead of being folded in.
public struct LedgerUsageWindow: Sendable, Equatable {
  /// Every day a store could answer for, oldest first. A day that is only partly inside the range and
  /// has no raw rows is not here — see ``unavailableDays``.
  public let days: [LedgerDayUsage]
  /// ``days`` summed per provider and model, ordered exactly as
  /// ``LedgerStore/summary(since:until:provider:)`` orders them. Exact: the counters are integers, and
  /// the money is a sum of micro-USD integers until the public `Decimal` boundary.
  public let summary: LedgerSummary
  /// How many of ``days`` came from `request`.
  public let rawDayCount: Int
  /// How many of ``days`` came from `daily`.
  public let rollupDayCount: Int
  /// UTC dates (`YYYY-MM-DD`) that the range only partly covers and that the rollup holds rows for,
  /// oldest first: days with usage the ledger can see but cannot split, because a rollup is one whole
  /// UTC day. They contribute nothing — using a whole-day aggregate for part of a day would over-count —
  /// so read the list as "days this range could not answer for although there is usage in them".
  ///
  /// A day the range only partly covers that holds nothing in either store is *not* listed: there is no
  /// usage to count, so nothing is missing from it. Empty when no such day is in range.
  ///
  /// ``rawDayCount``, ``rollupDayCount`` and this list account for every UTC day the range touches except
  /// a day that holds nothing in either store — with a `provider`, nothing for that provider. Those are
  /// counted nowhere, deliberately.
  public let unavailableDays: [String]
}
