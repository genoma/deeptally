// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A local source of usage that can be read incrementally.
///
/// The seam exists so the import flow can be tested without a 400 MB fixture database, and so a second
/// local source (the loopback proxy planned for v1.1) can reuse the same flow instead of growing a
/// parallel copy of it.
public protocol UsageImporting {
  /// The ledger keys watermarks by source, so a source must name itself.
  var source: UsageSource { get }
  /// Everything newer than `since`, plus the newest instant offered. `since == nil` scans everything.
  func importAll(since: Date?) throws -> OpenCodeImporter.ImportResult
}

extension OpenCodeImporter: UsageImporting {
  public var source: UsageSource { .opencode }
}

/// One import of local usage into the ledger — the flow the CLI and the app share.
///
/// It exists so "what happens if I import twice?" has exactly one answer in one place: nothing new is
/// added, because the ledger already holds those rows and `rawHash` is unique. The importer itself is
/// stateless and re-scans; the *ledger* owns the watermark, because the ledger is what knows which rows
/// were actually committed.
///
/// Not `Sendable`, deliberately: it holds a `LedgerStore`, which is deliberately not `Sendable` so the
/// compiler refuses to move it between isolation domains. Call it from whatever already owns the store.
public struct LedgerSync {
  public struct Outcome: Sendable, Equatable {
    /// Rows the ledger did not already have.
    public let inserted: Int
    /// Rows the source offered, including ones the ledger already had.
    public let offered: Int
    /// The watermark in force after the sync; unchanged when the scan saw nothing.
    public let watermark: Date?
    /// True when this pass deliberately rescanned everything.
    public let wasFullScan: Bool

    public init(inserted: Int, offered: Int, watermark: Date?, wasFullScan: Bool) {
      self.inserted = inserted
      self.offered = offered
      self.watermark = watermark
      self.wasFullScan = wasFullScan
    }
  }

  private let ledger: LedgerStore
  private let source: any UsageImporting

  public init(ledger: LedgerStore, source: any UsageImporting) {
    self.ledger = ledger
    self.source = source
  }

  /// Imports everything newer than the stored watermark. Calling it twice in a row inserts nothing the
  /// second time: no rows are re-added, the watermark does not move, and the rollups are not rebuilt.
  @discardableResult
  public func sync() throws -> Outcome {
    try sync(since: try ledger.importWatermark(for: source.source))
  }

  /// A repair pass: rescans everything and lets `rawHash` uniqueness absorb the duplicates. This is the
  /// recovery path for a row that arrived with a timestamp at or before the stored watermark, which the
  /// strict `>` in the incremental scan cannot see. It costs a full scan, so it is not the normal path.
  @discardableResult
  public func fullResync() throws -> Outcome {
    try sync(since: nil)
  }

  private func sync(since: Date?) throws -> Outcome {
    let result = try source.importAll(since: since)
    let inserted = try ledger.insert(
      result.records.map { (record: $0.record, rawHash: $0.rawHash) })

    if let latest = result.latestSeen {
      // Never move the watermark backwards: a repair pass can legitimately see an older maximum than the
      // one already stored, and rewinding would make the next incremental scan re-offer old rows.
      let stored = try ledger.importWatermark(for: source.source)
      try ledger.recordImportWatermark(max(latest, stored ?? .distantPast), for: source.source)
    }

    // Only touch the rollups when there is something new to roll up.
    if inserted > 0 {
      try ledger.rebuildDailyRollups()
    }

    return Outcome(
      inserted: inserted,
      offered: result.records.count,
      watermark: try ledger.importWatermark(for: source.source),
      wasFullScan: since == nil
    )
  }
}
