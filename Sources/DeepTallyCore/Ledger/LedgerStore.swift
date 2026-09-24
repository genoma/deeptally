// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

/// Everything that can go wrong in the ledger. No message can carry a secret: they are built from
/// our own SQL context strings plus sqlite's diagnostics, which describe schema, never data.
public enum LedgerError: Error, Equatable, Sendable {
  /// The folder could not be created before opening the file.
  case cannotCreateDirectory(path: String, reason: String)
  case cannotOpen(path: String, reason: String)
  /// The file was written by a newer DeepTally. Refusing is the only safe option: a downgrade that
  /// silently wrote an old schema over new data would lose the ledger.
  case unsupportedSchemaVersion(found: Int, supported: Int)
  /// Another connection holds the write lock, and the busy timeout expired.
  case busy
  case statementFailed(context: String, code: Int32, message: String)
  /// A caller's `rawHash` closure returned an empty key, which would silently disable dedupe.
  case emptyRawHash(row: Int)
  case fileMissing(path: String)
  case unreadableFile(path: String, reason: String)
  case cannotWrite(path: String, reason: String)
  /// One CSV row is unusable. The line number counts the header as line 1, so it is the number a
  /// text editor shows. Nothing from that file is applied.
  case malformedCSV(line: Int, reason: String)
}

/// Exact micro-USD conversion, the only place a `Decimal` amount becomes storable.
///
/// `docs/PLAN.md` §4 sketched `cost_usd REAL`; that is deliberately not what this ledger does.
/// Money is never a `Double` in this project, and binary floats make a cent-level sum drift as rows
/// accumulate, so the column is an INTEGER of 1e-6 USD and the conversion rounds half away from
/// zero exactly once, at the boundary.
enum MicroUSD {
  /// 1e-6 USD per unit, the scale of `request.cost_micro_usd`.
  static let scale = Decimal(1_000_000)

  static func fromDecimal(_ usd: Decimal) -> Int64 {
    var scaled = usd * scale
    var rounded = Decimal.zero
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    return NSDecimalNumber(decimal: rounded).int64Value
  }

  static func decimal(_ microUSD: Int64) -> Decimal {
    Decimal(microUSD) / scale
  }

  /// Six decimals, always, with no locale and no scientific notation: `0.001234`. A value written
  /// this way parses back to exactly the same integer, which is what makes the CSV a round trip.
  static func string(_ microUSD: Int64) -> String {
    let sign = microUSD < 0 ? "-" : ""
    let magnitude = microUSD.magnitude
    return "\(sign)\(magnitude / 1_000_000).\(String(format: "%06llu", magnitude % 1_000_000))"
  }
}

/// The local usage ledger, in one SQLite file. DeepSeek publishes no historical usage API
/// (docs/SPIKES.md S7), so this **is** the history: the popover, the CLI and the CSV export all read
/// it, and nothing else keeps a copy. Which is why every write is idempotent — an import that runs
/// every fifteen minutes must never count a request twice.
///
/// ## Money
/// `request.cost_micro_usd` is an INTEGER count of 1e-6 USD, exposed as `Decimal`; see ``MicroUSD``
/// for the deviation from the plan's `REAL` sketch. The cost is **not** computed here: the caller
/// prices each record with its own costing closure before inserting it, so peak / off-peak is
/// decided from the record's own timestamp — an old row keeps the window that was in force at its
/// instant, not the one in force when it happened to be imported.
///
/// ## Time
/// `request.ts` is whole epoch seconds, UTC, and every range query compares against it, so the second
/// is the resolution of everything range-shaped. `daily` is a rollup keyed by **UTC** date, which is
/// what makes a long-range query cheap. It is deliberately not the answer to "what did I spend
/// today": "today" is a local-time question, so a caller asks ``summary(since:until:provider:)`` with
/// a range built from its own calendar. Reading local-day totals out of the UTC rollup is off by a
/// day for every user east or west of UTC, which is the kind of bug that looks like a rounding error.
///
/// ## Rollups and pruning
/// `daily` is derived from `request` and is recomputed from it by
/// ``rebuildDailyRollups()`` (and after every insert that stored something): for any UTC day with at
/// least one `request` row, `daily` equals a direct aggregate over that day's rows. Days with no raw
/// rows keep their last computed values, which is exactly what lets ``pruneRawRequests(olderThanDays:now:)``
/// drop old raw rows without losing the totals they contributed — so a prune always removes whole UTC
/// days and never leaves a day half-aggregated. The trade-off is that raw-row range queries cannot
/// see past the prune horizon; the rollups can.
///
/// ## Concurrency
/// Deliberately **not** `Sendable`: the single `sqlite3` connection inside must be touched from one
/// isolation domain only, and the compiler enforces that for every caller. Hold the store in an actor
/// (or on the main actor) — to share it between actors, wrap it in an actor of your own — and do not
/// add an `@unchecked Sendable` conformance. Every method is synchronous, so a wrapper never
/// re-enters it.
public final class LedgerStore {
  /// One schema step. Statements are plain DDL/DML: the runner owns the transaction, so a step
  /// cannot half-apply, and the version it records is committed with the step's own statements.
  struct Migration: Sendable {
    let version: Int
    let statements: [String]
  }

  /// The `meta` keys the ledger owns. `import_watermark.<source>` is built per source.
  static let schemaVersionKey = "schema_version"
  static func importWatermarkKey(_ source: UsageSource) -> String {
    "import_watermark.\(source.rawValue)"
  }

  /// v1. `meta` is created by the runner before this, because the version itself is a `meta` row.
  static let migrations: [Migration] = [
    Migration(
      version: 1,
      statements: [
        """
        CREATE TABLE IF NOT EXISTS request (
          id INTEGER PRIMARY KEY,
          ts INTEGER NOT NULL,
          source TEXT NOT NULL,
          provider TEXT NOT NULL,
          model TEXT NOT NULL,
          input INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0,
          reasoning INTEGER NOT NULL DEFAULT 0,
          cache_read INTEGER NOT NULL DEFAULT 0,
          cache_write INTEGER NOT NULL DEFAULT 0,
          cost_micro_usd INTEGER NOT NULL,
          session_id TEXT,
          raw_hash TEXT UNIQUE
        )
        """,
        "CREATE INDEX IF NOT EXISTS request_ts ON request(ts)",
        """
        CREATE TABLE IF NOT EXISTS daily (
          date TEXT NOT NULL,
          provider TEXT NOT NULL,
          model TEXT NOT NULL,
          input INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0,
          reasoning INTEGER NOT NULL DEFAULT 0,
          cache_read INTEGER NOT NULL DEFAULT 0,
          cost_micro_usd INTEGER NOT NULL DEFAULT 0,
          request_count INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (date, provider, model)
        )
        """,
      ])
  ]

  /// `~/Library/Application Support/DeepTally/ledger.sqlite` — the file the app and the CLI share.
  public static var standardURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(
        path: "Library/Application Support")
    return base.appending(path: "DeepTally/ledger.sqlite")
  }

  private let database: OpaquePointer

  /// The file this store owns. Reported by diagnostics and error messages.
  public let url: URL

  /// The migrations this open applied, oldest first. Empty when the file was already current, which
  /// is the observable form of "reopening does not re-run v1".
  private(set) var appliedMigrationVersions: [Int] = []

  /// Opens (and creates on demand) the ledger at `url`, creating its folder if it is missing.
  ///
  /// `busyTimeout` is how long a statement waits for another connection's write lock before failing
  /// with ``LedgerError/busy``; the default is generous because losing an import to a momentary lock
  /// is worse than waiting.
  public convenience init(url: URL = LedgerStore.standardURL, busyTimeout: TimeInterval = 5)
    throws
  {
    try self.init(
      url: url, busyTimeout: busyTimeout, migrations: LedgerStore.migrations)
  }

  /// The designated initialiser, with the migration list injected. Production always passes
  /// ``migrations``; tests open a file with a future version appended, which is the only way to
  /// prove the runner adds a version without losing data.
  init(url: URL, busyTimeout: TimeInterval = 5, migrations: [Migration]) throws {
    let folder = url.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      throw LedgerError.cannotCreateDirectory(
        path: folder.path, reason: error.localizedDescription)
    }

    var opened: OpaquePointer?
    let code = sqlite3_open_v2(
      url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard code == SQLITE_OK, let handle = opened else {
      let reason = Self.errorMessage(opened)
      if let opened { _ = sqlite3_close(opened) }
      throw LedgerError.cannotOpen(path: url.path, reason: reason)
    }

    // Every stored property is set before anything below can throw, so a failure here leaves an
    // instance whose `deinit` closes the connection.
    self.database = handle
    self.url = url

    try Self.configure(handle, busyTimeout: busyTimeout)
    appliedMigrationVersions = try Self.migrate(handle, migrations: migrations)
  }

  /// Closes the connection. `sqlite3_close` is safe on a handle with no open statements: every
  /// statement in this type is finalized before its method returns.
  deinit {
    _ = sqlite3_close(database)
  }

  // MARK: - Schema

  /// The `schema_version` recorded in `meta`.
  public func schemaVersion() throws -> Int {
    try Self.schemaVersion(database)
  }

  private static func configure(_ handle: OpaquePointer, busyTimeout: TimeInterval) throws {
    // WAL so a reader never blocks the importer and a crash cannot corrupt the file; NORMAL is the
    // durability level the plan asks for — this is a rebuildable log of usage, not a bank.
    try execute(handle, "PRAGMA journal_mode = WAL")
    try execute(handle, "PRAGMA synchronous = NORMAL")
    try execute(handle, "PRAGMA foreign_keys = ON")
    _ = sqlite3_busy_timeout(handle, Int32(max(0, (busyTimeout * 1_000).rounded())))
  }

  /// Creates `meta`, reads the stored version and applies every migration newer than it, each in its
  /// own transaction. Returns the versions applied.
  private static func migrate(_ handle: OpaquePointer, migrations: [Migration]) throws -> [Int] {
    try execute(
      handle, "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")

    let ordered = migrations.sorted { $0.version < $1.version }
    let supported = ordered.last?.version ?? 0
    let stored = try schemaVersion(handle)
    guard stored <= supported else {
      throw LedgerError.unsupportedSchemaVersion(found: stored, supported: supported)
    }

    var applied: [Int] = []
    for migration in ordered where migration.version > stored {
      try execute(handle, "BEGIN IMMEDIATE")
      do {
        for statement in migration.statements {
          try execute(handle, statement)
        }
        try setMetaValue(handle, key: schemaVersionKey, value: "\(migration.version)")
        try execute(handle, "COMMIT")
      } catch {
        try? execute(handle, "ROLLBACK")
        throw error
      }
      applied.append(migration.version)
    }
    return applied
  }

  private static func schemaVersion(_ handle: OpaquePointer) throws -> Int {
    guard let raw = try metaValue(handle, key: schemaVersionKey) else { return 0 }
    return Int(raw) ?? 0
  }

  // MARK: - Insert

  /// Stores `records`, skipping any whose `rawHash` is already present, and returns how many rows
  /// were actually written — so a re-import of unchanged source data returns `0`.
  ///
  /// `rawHash` is the caller's dedupe key (the opencode importer uses a SHA-256 over the source row's
  /// identity). A key that is empty is a bug that would disable dedupe, so it throws
  /// ``LedgerError/emptyRawHash(row:)`` instead of being stored.
  ///
  /// `record.costUSD` is stored as given: the caller's costing closure priced the row for the
  /// peak / off-peak window in force **at the record's own timestamp**, so an old record inserted
  /// today keeps the price it actually paid.
  ///
  /// The affected UTC-day rollups are recomputed inside the same transaction, so a committed insert
  /// never leaves `daily` behind `request`.
  public func insert(_ records: [UsageRecord], rawHash: (UsageRecord) -> String) throws -> Int {
    try insert(
      records.enumerated().map { index, record in
        let key = rawHash(record)
        guard !key.isEmpty else { throw LedgerError.emptyRawHash(row: index) }
        return (record: record, rawHash: key)
      })
  }

  /// Inserts rows that already carry their dedupe key.
  ///
  /// This is the shape an importer has: `OpenCodeImporter` derives the key from the source row's id,
  /// which a `UsageRecord` does not carry, so the key has to travel beside the record rather than be
  /// recomputed from it. `importCSV` uses the same path with the key read out of the file.
  public func insert(_ rows: [(record: UsageRecord, rawHash: String)]) throws -> Int {
    if let index = rows.firstIndex(where: { $0.rawHash.isEmpty }) {
      throw LedgerError.emptyRawHash(row: index)
    }
    guard !rows.isEmpty else { return 0 }
    return try inTransaction {
      let statement = try prepare(Self.insertRequestSQL, context: "insert request")
      defer { _ = sqlite3_finalize(statement) }

      var inserted = 0
      for row in rows {
        _ = sqlite3_reset(statement)
        _ = sqlite3_clear_bindings(statement)
        try bind(statement, 1, Self.epochSeconds(row.record.timestamp))
        try bind(statement, 2, row.record.source.rawValue)
        try bind(statement, 3, row.record.provider.rawValue)
        try bind(statement, 4, row.record.model)
        try bind(statement, 5, Int64(row.record.usage.cacheMissTokens))
        try bind(statement, 6, Int64(Self.outputTokens(row.record.usage)))
        try bind(statement, 7, Int64(row.record.usage.reasoningTokens))
        try bind(statement, 8, Int64(row.record.usage.cacheHitTokens))
        try bind(statement, 9, Int64(0))
        try bind(statement, 10, MicroUSD.fromDecimal(row.record.costUSD))
        try bind(statement, 11, row.record.sessionID)
        try bind(statement, 12, row.rawHash)

        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else {
          throw Self.error(step, context: "insert request", message: Self.errorMessage(database))
        }
        if sqlite3_changes(database) > 0 { inserted += 1 }
      }
      if inserted > 0 { try rebuildDailyRollupsUnconditionally() }
      return inserted
    }
  }

  /// `TokenUsage` → the `request` columns, and back, without losing a counter:
  ///
  /// * `input = cacheMissTokens` and `cache_write = 0`. `TokenUsage` folds opencode's uncached input
  ///   and its cache writes into one miss count, and a cache write is never billed by DeepSeek, so
  ///   splitting them here would invent a distinction the record does not carry. `input + cache_write`
  ///   adds back up to the miss count.
  /// * `output = completionTokens - reasoningTokens`, `reasoning = reasoningTokens`, which is how
  ///   opencode stores them and how `CostEngine` bills them (reasoning is billed as output and is
  ///   already inside `completionTokens`; the two are recombined, never added twice).
  private static func outputTokens(_ usage: TokenUsage) -> Int {
    max(0, usage.completionTokens - usage.reasoningTokens)
  }

  private static let insertRequestSQL = """
    INSERT OR IGNORE INTO request
      (ts, source, provider, model, input, output, reasoning, cache_read, cache_write,
       cost_micro_usd, session_id, raw_hash)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
    """

  // MARK: - Rollups

  /// Recomputes `daily` from `request`. Idempotent: running it twice leaves identical rows.
  public func rebuildDailyRollups() throws {
    try inTransaction { try rebuildDailyRollupsUnconditionally() }
  }

  /// Upserts one row per `(UTC date, provider, model)` present in `request`. Days that have no raw
  /// rows are left alone on purpose: that is what keeps a pruned day's totals alive.
  ///
  /// The rollup has no `cache_write` column (the plan's sketch), which is not a loss today: records
  /// built from `TokenUsage` fold cache writes into `input` and store 0 there, so the rollup's
  /// prompt-side columns still add up. `request` stays the exact store.
  private func rebuildDailyRollupsUnconditionally() throws {
    try execute(Self.rebuildDailySQL)
  }

  private static let rebuildDailySQL = """
    INSERT INTO daily
      (date, provider, model, input, output, reasoning, cache_read, cost_micro_usd, request_count)
    SELECT date(ts, 'unixepoch'), provider, model, SUM(input), SUM(output), SUM(reasoning),
           SUM(cache_read), SUM(cost_micro_usd), COUNT(*)
      FROM request
     GROUP BY date(ts, 'unixepoch'), provider, model
    ON CONFLICT(date, provider, model) DO UPDATE SET
      input = excluded.input,
      output = excluded.output,
      reasoning = excluded.reasoning,
      cache_read = excluded.cache_read,
      cost_micro_usd = excluded.cost_micro_usd,
      request_count = excluded.request_count
    """

  // MARK: - Reprice

  /// The `meta` key recording which price table produced the costs the ledger holds now.
  public static let repricePriceTableVersionKey = "reprice.price_table_version"

  /// The table version the last ``reprice(costing:batchSize:)`` recorded, or `nil` when the ledger has
  /// never been repriced. Comparing it with the price table in hand is the whole of "is a reprice
  /// worthwhile?": equal means the stored costs already came from that table.
  public func recordedRepricePriceTableVersion() throws -> String? {
    try metaValue(Self.repricePriceTableVersionKey)
  }

  /// Reprices every raw row from **its own** model, token counters and timestamp, and rewrites only
  /// the rows whose cost actually changes.
  ///
  /// ## Why this exists
  /// A row is priced once, at import, and the cost is stored beside its tokens (see
  /// ``insert(_:rawHash:)``). Deduplication is by `raw_hash`, so re-importing the source cannot
  /// correct a row that was priced wrong: the row is already there and that is correct for counting.
  /// Without this pass an unresolved model id keeps its wrong cost forever, and a user who fixes the
  /// price table gains nothing on the history they already have.
  ///
  /// ## What it does
  /// `costing` decides the cost of one `(model, usage, timestamp)`, and each row is priced with the
  /// window in force at its *own* instant — a reprice recomputes history from records, it does not
  /// restate it at today's prices. Rows the costing cannot price are counted and reported, never
  /// written (see ``RowCosting/costIfPriced(model:usage:at:)``). The `daily` rollups are rebuilt from
  /// the recomputed rows inside the same transaction, so a committed reprice never leaves `daily`
  /// disagreeing with `request`.
  ///
  /// Idempotent: a second call with the same costing finds every row already correct, writes nothing
  /// and reports ``RepriceOutcome/madeNoChanges``.
  ///
  /// Bounded memory: rows are read in primary-key batches of `batchSize` (`WHERE id > ?` / `LIMIT`),
  /// so a 400,000-row ledger costs one batch at a time rather than the whole table. A batch is read
  /// into memory and its cursor closed before that batch is written, because reading and writing the
  /// same table through one pending `SELECT` has no defined visibility. `batchSize` is a parameter
  /// only so a test can force several pages.
  ///
  /// Atomic: rows, rollups and the recorded price-table version commit together, so an interrupted
  /// reprice changes nothing at all.
  ///
  /// - Note: ``RepriceOutcome/spendBeforeUSD`` and ``RepriceOutcome/spendAfterUSD`` total the raw rows
  ///   this pass examined. `daily` also keeps days whose raw rows were pruned, so those two totals are
  ///   the ledger's *repricable* spend, not the whole of `daily`.
  public func reprice(costing: any RowCosting, batchSize: Int = 2_000) throws -> RepriceOutcome {
    let previousVersion = try metaValue(Self.repricePriceTableVersionKey)

    return try inTransaction {
      let update = try prepare(Self.repriceUpdateSQL, context: "reprice update")
      defer { _ = sqlite3_finalize(update) }

      var examined = 0
      var changed = 0
      var spendBefore: Int64 = 0
      var spendAfter: Int64 = 0
      var unpriced: [String: ModelTally] = [:]

      try forEachCostRow(batchSize: batchSize) { row in
        examined += 1
        spendBefore += row.storedMicroUSD
        guard
          let cost = costing.costIfPriced(
            model: row.model, usage: row.usage, at: row.timestamp)
        else {
          // No price for this id: the stored cost stands and the row is only counted. It is *not*
          // zeroed — a zero written here would be indistinguishable from a measured zero.
          unpriced[row.model, default: ModelTally()].add(row.storedMicroUSD)
          spendAfter += row.storedMicroUSD
          return
        }
        let microUSD = MicroUSD.fromDecimal(cost)
        if microUSD != row.storedMicroUSD {
          try updateCost(update, microUSD: microUSD, id: row.id)
          changed += 1
        }
        spendAfter += microUSD
      }

      if changed > 0 { try rebuildDailyRollupsUnconditionally() }
      if !costing.priceTableVersion.isEmpty {
        try setMetaValue(Self.repricePriceTableVersionKey, costing.priceTableVersion)
      }

      return RepriceOutcome(
        rowsExamined: examined,
        rowsChanged: changed,
        rowsUnpriced: unpriced.values.reduce(0) { $0 + $1.rows },
        unpricedModels: Self.unpricedModels(from: unpriced),
        spendBeforeUSD: MicroUSD.decimal(spendBefore),
        spendAfterUSD: MicroUSD.decimal(spendAfter),
        priceTableVersion: costing.priceTableVersion,
        previousPriceTableVersion: previousVersion
      )
    }
  }

  /// What the current costing cannot price, without writing anything: the scan ``reprice(costing:batchSize:)``
  /// performs, reported instead of applied. This is what lets a caller say "4,237 rows have no price,
  /// and deepseek/deepseek-v4-flash-vision-exp is 2,750 of them" without first changing the ledger.
  ///
  /// Not a snapshot: it takes no write lock, so an import running concurrently can land between two
  /// batches. It is a report to show a user, not a decision to store.
  public func unpricedSummary(
    costing: any RowCosting, batchSize: Int = 2_000
  ) throws -> UnpricedSummary {
    var examined = 0
    var unpriced: [String: ModelTally] = [:]

    try forEachCostRow(batchSize: batchSize) { row in
      examined += 1
      let cost = costing.costIfPriced(model: row.model, usage: row.usage, at: row.timestamp)
      if cost == nil { unpriced[row.model, default: ModelTally()].add(row.storedMicroUSD) }
    }

    return UnpricedSummary(
      rowsExamined: examined,
      rowsUnpriced: unpriced.values.reduce(0) { $0 + $1.rows },
      models: Self.unpricedModels(from: unpriced))
  }

  /// How many rows one model id contributed, and what they carry.
  private struct ModelTally {
    var rows = 0
    var spend: Int64 = 0

    mutating func add(_ storedMicroUSD: Int64) {
      rows += 1
      spend += storedMicroUSD
    }
  }

  /// The tallies as a list, biggest gap first and ties by model id, so two runs over one ledger
  /// produce the same table.
  private static func unpricedModels(from tallies: [String: ModelTally]) -> [UnpricedModel] {
    tallies
      .map {
        UnpricedModel(
          model: $0.key, rows: $0.value.rows, spendUSD: MicroUSD.decimal($0.value.spend))
      }
      .sorted { $0.rows == $1.rows ? $0.model < $1.model : $0.rows > $1.rows }
  }

  /// One raw row as a reprice sees it: the inputs to a cost, plus what the row says now.
  private struct CostRow {
    let id: Int64
    let timestamp: Date
    let model: String
    let usage: TokenUsage
    let storedMicroUSD: Int64
  }

  /// Streams every raw row in primary-key order, `batchSize` at a time, and calls `body` once per row.
  ///
  /// The cursor is reset before the first row of a batch is handed out, so `body` may write to
  /// `request` without the scan seeing its own writes. `id` is the rowid, so this is an index walk and
  /// not a sort, and the walk starts below every possible id so "every raw row" does not depend on
  /// rowids being positive. A row inserted while the scan runs is either picked up or left for the next
  /// pass — it was priced at insert either way.
  private func forEachCostRow(batchSize: Int, _ body: (CostRow) throws -> Void) throws {
    let size = max(1, batchSize)
    let select = try prepare(Self.repriceSelectSQL, context: "reprice scan")
    defer { _ = sqlite3_finalize(select) }

    var lastID = Int64.min
    while true {
      var batch: [CostRow] = []
      _ = sqlite3_reset(select)
      _ = sqlite3_clear_bindings(select)
      try bind(select, 1, lastID)
      try bind(select, 2, Int64(size))
      while true {
        let step = sqlite3_step(select)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else {
          throw Self.error(step, context: "reprice scan", message: Self.errorMessage(database))
        }
        batch.append(costRow(select))
      }
      _ = sqlite3_reset(select)
      guard let last = batch.last else { return }
      for row in batch { try body(row) }
      lastID = last.id
    }
  }

  /// Decodes one `repriceSelectSQL` row. The token mapping is the exact inverse of the one
  /// ``insert(_:rawHash:)`` applies: `input + cache_write` is the miss count, `output + reasoning`
  /// the completion count (reasoning is billed as output and is already inside completion), and the
  /// prompt total is both of those plus `cache_read`.
  private func costRow(_ statement: OpaquePointer) -> CostRow {
    let input = sqlite3_column_int64(statement, 3)
    let output = sqlite3_column_int64(statement, 4)
    let reasoning = sqlite3_column_int64(statement, 5)
    let cacheRead = sqlite3_column_int64(statement, 6)
    let cacheWrite = sqlite3_column_int64(statement, 7)
    let cacheMiss = input + cacheWrite
    let completion = output + reasoning
    return CostRow(
      id: sqlite3_column_int64(statement, 0),
      timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
      model: text(statement, 2) ?? "",
      usage: TokenUsage(
        promptTokens: Int(cacheMiss + cacheRead),
        completionTokens: Int(completion),
        cacheHitTokens: Int(cacheRead),
        cacheMissTokens: Int(cacheMiss),
        reasoningTokens: Int(reasoning)
      ),
      storedMicroUSD: sqlite3_column_int64(statement, 8)
    )
  }

  /// Writes one row's cost. Only ever called for a row whose cost differs, which is why
  /// ``RepriceOutcome/rowsChanged`` and the number of `request` writes are the same number.
  private func updateCost(_ statement: OpaquePointer, microUSD: Int64, id: Int64) throws {
    _ = sqlite3_reset(statement)
    _ = sqlite3_clear_bindings(statement)
    try bind(statement, 1, microUSD)
    try bind(statement, 2, id)
    let step = sqlite3_step(statement)
    guard step == SQLITE_DONE else {
      throw Self.error(step, context: "reprice update", message: Self.errorMessage(database))
    }
  }

  private static let repriceSelectSQL = """
    SELECT id, ts, model, input, output, reasoning, cache_read, cache_write, cost_micro_usd
      FROM request
     WHERE id > ?1
     ORDER BY id
     LIMIT ?2
    """

  private static let repriceUpdateSQL = "UPDATE request SET cost_micro_usd = ?1 WHERE id = ?2"

  // MARK: - Summary

  /// Totals over the raw rows in `since ..< until`, optionally narrowed to one provider.
  ///
  /// The range is half-open and compared against `request.ts` at second resolution, so a caller
  /// builds a local day as `[start of that day, start of the next day)`. This reads `request`, not
  /// `daily`, because a local-time boundary can fall inside a UTC day.
  public func summary(since: Date, until: Date, provider: Provider? = nil) throws -> LedgerSummary {
    var sql = """
      SELECT provider, model, SUM(input), SUM(output), SUM(reasoning), SUM(cache_read),
             SUM(cache_write), SUM(cost_micro_usd), COUNT(*)
        FROM request
       WHERE ts >= ?1 AND ts < ?2
      """
    if provider != nil { sql += "   AND provider = ?3\n" }
    sql += "   GROUP BY provider, model\n   ORDER BY provider, model"

    let statement = try prepare(sql, context: "summary")
    defer { _ = sqlite3_finalize(statement) }
    try bind(statement, 1, Self.epochSeconds(since))
    try bind(statement, 2, Self.epochSeconds(until))
    if let provider { try bind(statement, 3, provider.rawValue) }

    var totals: [LedgerModelTotals] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw Self.error(step, context: "summary", message: Self.errorMessage(database))
      }
      // An unreadable provider is stored text that this build does not know; it is still usage, so
      // it is reported as `.unknown` rather than dropped from a total.
      let provider = Provider(rawValue: text(statement, 0) ?? "") ?? .unknown
      totals.append(
        LedgerModelTotals(
          provider: provider,
          model: text(statement, 1) ?? "",
          spendUSD: MicroUSD.decimal(sqlite3_column_int64(statement, 7)),
          inputTokens: Int(sqlite3_column_int64(statement, 2)),
          outputTokens: Int(sqlite3_column_int64(statement, 3)),
          reasoningTokens: Int(sqlite3_column_int64(statement, 4)),
          cacheReadTokens: Int(sqlite3_column_int64(statement, 5)),
          cacheWriteTokens: Int(sqlite3_column_int64(statement, 6)),
          requestCount: Int(sqlite3_column_int64(statement, 8))
        ))
    }
    return LedgerSummary(models: totals)
  }

  // MARK: - Pruning

  /// Deletes raw rows older than `days` before `now`, and returns how many rows went.
  ///
  /// The cutoff is floored to a UTC day boundary, so a prune never leaves a day half-aggregated: a
  /// day with some raw rows deleted and others kept would make `daily` disagree with the aggregate
  /// it is derived from. `daily` is not touched, so the pruned days' totals survive and a later
  /// rebuild still leaves them intact. `now` is injected so tests can pin the cutoff.
  public func pruneRawRequests(olderThanDays days: Int, now: Date = Date()) throws -> Int {
    let cutoff = Self.utcDayStart(now) - Int64(max(0, days)) * 86_400
    let statement = try prepare("DELETE FROM request WHERE ts < ?1", context: "prune request")
    defer { _ = sqlite3_finalize(statement) }
    try bind(statement, 1, cutoff)
    let step = sqlite3_step(statement)
    guard step == SQLITE_DONE else {
      throw Self.error(step, context: "prune request", message: Self.errorMessage(database))
    }
    return Int(sqlite3_changes(database))
  }

  // MARK: - CSV

  /// Writes every raw row, oldest first, as `ts,source,provider,model,input,output,reasoning,`
  /// `cache_read,cache_write,cost_usd,session_id,raw_hash`.
  ///
  /// CSV is an inspection and interchange format, never the primary store
  /// (docs/PLAN.md §4), and it round-trips: ``importCSV(from:)`` of this file reproduces the same
  /// rows and the same summary. A row with no `raw_hash` — which only something writing to the file
  /// outside this type can produce — exports with an empty key and is refused on the way back in,
  /// because the alternative is importing it twice.
  public func exportCSV(to url: URL) throws {
    let statement = try prepare(Self.exportSQL, context: "export request")
    defer { _ = sqlite3_finalize(statement) }

    var csv = LedgerCSV.headerLine + "\n"
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw Self.error(step, context: "export request", message: Self.errorMessage(database))
      }
      let ts: Int64 = sqlite3_column_int64(statement, 0)
      let source: String = text(statement, 1) ?? ""
      let provider: String = text(statement, 2) ?? ""
      let model: String = text(statement, 3) ?? ""
      let input: Int64 = sqlite3_column_int64(statement, 4)
      let output: Int64 = sqlite3_column_int64(statement, 5)
      let reasoning: Int64 = sqlite3_column_int64(statement, 6)
      let cacheRead: Int64 = sqlite3_column_int64(statement, 7)
      let cacheWrite: Int64 = sqlite3_column_int64(statement, 8)
      let cost: String = MicroUSD.string(sqlite3_column_int64(statement, 9))
      let sessionID: String = text(statement, 10) ?? ""
      let rawHash: String = text(statement, 11) ?? ""
      let fields: [String] = [
        "\(ts)", source, provider, model, "\(input)", "\(output)", "\(reasoning)",
        "\(cacheRead)", "\(cacheWrite)", cost, sessionID, rawHash,
      ]
      csv += LedgerCSV.line(fields) + "\n"
    }

    do {
      try Data(csv.utf8).write(to: url, options: .atomic)
    } catch {
      throw LedgerError.cannotWrite(path: url.path, reason: error.localizedDescription)
    }
  }

  /// Reads a CSV written by ``exportCSV(to:)`` and inserts what it does not already have, returning
  /// how many rows that was. Re-importing the same file is a no-op, because `raw_hash` is UNIQUE.
  ///
  /// The whole file is parsed before anything is written, so one malformed row means the ledger is
  /// untouched and the error names the line a text editor would show. An empty `raw_hash` field is
  /// malformed rather than stored: without a key the row would be counted again on the next import.
  public func importCSV(from url: URL) throws -> Int {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw LedgerError.fileMissing(path: url.path)
    }
    let raw: String
    do {
      raw = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw LedgerError.unreadableFile(path: url.path, reason: error.localizedDescription)
    }
    // A spreadsheet that saved a UTF-8 BOM must not turn the first column name into garbage.
    let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw

    let rows = try LedgerCSV.parse(text)
    guard let header = rows.first else {
      throw LedgerError.malformedCSV(line: 1, reason: "the file is empty; a header row is required")
    }
    let layout = try LedgerCSV.Layout(headerFields: header.fields, line: header.line)

    let decoded = try rows.dropFirst().map { row in
      try LedgerCSV.decode(fields: row.fields, layout: layout, line: row.line)
    }
    return try insert(decoded.map { (record: $0.record, rawHash: $0.rawHash) })
  }

  private static let exportSQL = """
    SELECT ts, source, provider, model, input, output, reasoning, cache_read, cache_write,
           cost_micro_usd, session_id, raw_hash
      FROM request
     ORDER BY ts, id
    """

  // MARK: - Watermarks

  /// The newest record instant already imported from `source`, or `nil` when none is recorded.
  ///
  /// The ledger owns this value because the ledger is what knows which rows were committed; the
  /// importer has no state (and is therefore safe to run again at any time). Keyed by source so a
  /// second importer cannot stomp the first one's watermark.
  public func importWatermark(for source: UsageSource) throws -> Date? {
    guard let raw = try metaValue(Self.importWatermarkKey(source)), let ms = Int64(raw) else {
      return nil
    }
    return Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
  }

  /// Advances the watermark for `source`, and never moves it backwards: a stale or replayed import
  /// must not make the next scan re-read months of rows.
  ///
  /// The instant is stored as epoch milliseconds, which is opencode's own resolution, so a timestamp
  /// that came out of opencode round-trips exactly. A sub-millisecond instant lands at most half a
  /// millisecond away, which cannot hide a row: nothing in the source carries finer resolution. The
  /// value is only ever a *lower* bound on what has been imported — the ledger ignores rows it
  /// already has — so an importer may always pass an earlier instant to re-read a window.
  public func recordImportWatermark(_ date: Date, for source: UsageSource) throws {
    let key = Self.importWatermarkKey(source)
    let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded())
    if let existing = try metaValue(key), let previous = Int64(existing), previous >= milliseconds {
      return
    }
    try setMetaValue(key, "\(milliseconds)")
  }

  // MARK: - meta

  private func metaValue(_ key: String) throws -> String? {
    try Self.metaValue(database, key: key)
  }

  private func setMetaValue(_ key: String, _ value: String) throws {
    try Self.setMetaValue(database, key: key, value: value)
  }

  private static func metaValue(_ handle: OpaquePointer, key: String) throws -> String? {
    let statement = try prepare(
      handle, "SELECT value FROM meta WHERE key = ?1", context: "read meta")
    defer { _ = sqlite3_finalize(statement) }
    try bind(handle, statement, 1, key)
    let step = sqlite3_step(statement)
    switch step {
    case SQLITE_DONE: return nil
    case SQLITE_ROW: return text(handle, statement, 0)
    default:
      throw error(step, context: "read meta", message: errorMessage(handle))
    }
  }

  private static func setMetaValue(_ handle: OpaquePointer, key: String, value: String) throws {
    let sql = """
      INSERT INTO meta(key, value) VALUES (?1, ?2)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      """
    let statement = try prepare(handle, sql, context: "write meta")
    defer { _ = sqlite3_finalize(statement) }
    try bind(handle, statement, 1, key)
    try bind(handle, statement, 2, value)
    let step = sqlite3_step(statement)
    guard step == SQLITE_DONE else {
      throw error(step, context: "write meta", message: errorMessage(handle))
    }
  }

  // MARK: - Statement plumbing

  private func inTransaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func execute(_ sql: String) throws {
    try Self.execute(database, sql)
  }

  private static func execute(_ handle: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(handle, sql, nil, nil, &message)
    guard code == SQLITE_OK else {
      let reason = message.map { String(cString: $0) } ?? "sqlite error \(code)"
      sqlite3_free(message)
      throw error(code, context: "exec", message: reason)
    }
  }

  private func prepare(_ sql: String, context: String) throws -> OpaquePointer {
    try Self.prepare(database, sql, context: context)
  }

  private static func prepare(
    _ handle: OpaquePointer, _ sql: String, context: String
  ) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard code == SQLITE_OK, let prepared = statement else {
      throw error(code, context: context, message: errorMessage(handle))
    }
    return prepared
  }

  private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
    try Self.bind(database, statement, index, value)
  }

  private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) throws {
    try Self.bind(database, statement, index, value)
  }

  private static func bind(
    _ handle: OpaquePointer, _ statement: OpaquePointer, _ index: Int32, _ value: Int64
  ) throws {
    guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
      throw error(sqlite3_errcode(handle), context: "bind integer", message: errorMessage(handle))
    }
  }

  private static func bind(
    _ handle: OpaquePointer, _ statement: OpaquePointer, _ index: Int32, _ value: String?
  ) throws {
    let code: Int32
    if let value {
      code = sqlite3_bind_text(
        statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    } else {
      code = sqlite3_bind_null(statement, index)
    }
    guard code == SQLITE_OK else {
      throw error(code, context: "bind text", message: errorMessage(handle))
    }
  }

  private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    Self.text(database, statement, index)
  }

  private static func text(
    _ handle: OpaquePointer, _ statement: OpaquePointer, _ index: Int32
  ) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let bytes = sqlite3_column_text(statement, index)
    else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
  }

  // MARK: - Time and errors

  /// Epoch seconds, the resolution of `request.ts`. Sub-second precision is dropped: a row is
  /// identified by its `raw_hash`, never by its timestamp.
  private static func epochSeconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970.rounded(.down))
  }

  /// The UTC midnight at or before `date`, as epoch seconds.
  private static func utcDayStart(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 / 86_400).rounded(.down)) * 86_400
  }

  private static func error(_ code: Int32, context: String, message: String) -> LedgerError {
    switch code & 0xFF {
    case SQLITE_BUSY, SQLITE_LOCKED:
      return .busy
    default:
      return .statementFailed(context: context, code: code, message: message)
    }
  }

  private static func errorMessage(_ handle: OpaquePointer?) -> String {
    guard let handle, let message = sqlite3_errmsg(handle) else { return "unknown sqlite error" }
    return String(cString: message)
  }
}
