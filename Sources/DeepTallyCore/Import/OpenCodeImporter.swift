// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import SQLite3

/// Read-only importer for opencode's local usage database (`~/.local/share/opencode/opencode.db`).
///
/// opencode has shipped two schema generations: `message` (role, providerID and modelID stored flat in
/// `data`) and `session_message` (a `type` column plus a nested `data.model`). They are **not** mirrors
/// of the same rows: on the developer's database 1062 token-bearing assistant rows existed only in
/// `session_message` and 2590 only in `message`, so both generations are imported and deduped by
/// `rawHash`.
///
/// Credential-bearing tables are never read. An authorizer denies `credential*`, `cred_*`, `account*`
/// and `auth*` at the connection level, so a regression fails loudly instead of reading a secret.
public struct OpenCodeImporter {
  /// Fills `costUSD` for a row. The pricing engine lives in another lane; the importer never prices.
  public typealias Costing = (String, TokenUsage, Date) -> Decimal

  /// One imported row plus its dedupe key.
  public struct ImportedRecord: Sendable, Equatable {
    public let record: UsageRecord
    /// Stable SHA-256 over `(source, id, session_id)`, for idempotent ledger inserts.
    public let rawHash: String

    public init(record: UsageRecord, rawHash: String) {
      self.record = record
      self.rawHash = rawHash
    }
  }

  /// The outcome of one scan: the rows a caller has not been offered before, and the watermark to
  /// hand back on the next one.
  public struct ImportResult: Sendable, Equatable {
    public let records: [ImportedRecord]
    /// The newest record instant in ``records``, or `nil` when the scan found nothing new.
    public let latestSeen: Date?

    public init(records: [ImportedRecord], latestSeen: Date?) {
      self.records = records
      self.latestSeen = latestSeen
    }
  }

  public enum ImportError: Error, Equatable, Sendable {
    case databaseMissing(path: String)
    case databaseUnusable(reason: String)
    case databaseBusy
    case unsupportedSchema(reason: String)
  }

  /// `~/.local/share/opencode/opencode.db` — where opencode keeps the database on macOS.
  public static let standardDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".local/share/opencode/opencode.db")

  private let databaseURL: URL
  private let costing: Costing

  public init(
    databaseURL: URL = OpenCodeImporter.standardDatabaseURL,
    costing: @escaping Costing
  ) {
    self.databaseURL = databaseURL
    self.costing = costing
  }

  /// Every assistant message that carries usage, from whichever generation stores it. Rows that do not
  /// decode or that have no counters are skipped, never fatal: one bad row must not block the ledger.
  ///
  /// This is the full scan, and it is the right call for the first import of a profile or for a
  /// repair pass. For the fifteen-minute tick use ``importAll(since:)``.
  public func importAll() throws -> [ImportedRecord] {
    try scan(since: nil).records
  }

  /// Every row worth offering since `since`, plus the newest instant seen, so the caller can resume
  /// from there.
  ///
  /// The watermark is what makes a 400 MB database cheap to re-read every fifteen minutes: rows that
  /// neither started nor were last touched after `since` are filtered out by SQL (on opencode's
  /// millisecond `time_created`/`time_updated` columns) and again in memory, so the result is the
  /// rows a caller has not been offered before — plus any row opencode has rewritten since the last
  /// scan, whose counters may have grown (see ``reconsideredRawHashes(_:since:)``). `since == nil`
  /// scans everything.
  ///
  /// Passing a watermark *earlier* than the previous one is always safe — the ledger absorbs rows it
  /// already has, keyed on `rawHash` — and is the way to recover a row that arrived with a timestamp
  /// at or before the old watermark, the one case a strict `>` cannot see. `latestSeen` is `nil` when
  /// the scan saw nothing; a caller keeps its previous watermark in that case.
  ///
  /// The importer stores nothing: the ledger owns the watermark, because the ledger is what knows
  /// which rows were actually committed.
  public func importAll(since: Date?) throws -> ImportResult {
    let scanned = try scan(since: since)
    return ImportResult(records: scanned.records, latestSeen: scanned.latestSeen)
  }

  private func scan(since: Date?) throws -> (records: [ImportedRecord], latestSeen: Date?) {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
      throw ImportError.databaseMissing(path: databaseURL.path)
    }

    let database = try openReadOnly()
    defer { _ = sqlite3_close(database) }

    try execute(database, sql: "PRAGMA busy_timeout = 2000")

    // Only used to narrow the read; the authoritative cutoff is `reconsideredRawHashes(_:since:)`
    // below.
    let sinceMilliseconds = since.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) }
    let schema = try detectSchema(in: database)
    var candidates: [Candidate] = []
    if schema.hasMessage {
      candidates.append(
        contentsOf: try readCandidates(
          database, generation: .message, sinceMilliseconds: sinceMilliseconds))
    }
    if schema.hasSessionMessage {
      candidates.append(
        contentsOf: try readCandidates(
          database, generation: .sessionMessage, sinceMilliseconds: sinceMilliseconds))
    }

    let merged = merge(candidates)

    // What the scan reports as "newest seen" decides the next watermark, so it has to cover every
    // instant this pass looked at - including opencode's own updates. Reporting only the record
    // instants left a touched row that is newer than the newest created time re-offered on every
    // pass forever: nothing was written (the counters matched), but each pass re-scanned it and the
    // CLI kept reporting it as offered (review finding N3). A later update still outruns the stored
    // watermark, so the guarantee that a rewritten row is re-offered is unchanged.
    let kept: [ImportedRecord]
    let covered: [Candidate]
    if let since {
      let reconsidered = Self.reconsideredRawHashes(candidates, since: since)
      kept = merged.filter { reconsidered.contains($0.rawHash) }
      covered = candidates.filter { reconsidered.contains($0.rawHash) }
    } else {
      kept = merged
      covered = candidates
    }
    return (kept, Self.newestInstant(records: kept, candidates: covered))
  }

  /// The newest instant a scan covered: the record instants it offers, or opencode's updates to those
  /// same rows, whichever is later.
  private static func newestInstant(records: [ImportedRecord], candidates: [Candidate]) -> Date? {
    let created = records.map(\.record.timestamp).max()
    let updated = candidates.map {
      Date(timeIntervalSince1970: TimeInterval($0.timeUpdated) / 1_000)
    }.max()
    switch (created, updated) {
    case (let created?, let updated?): return max(created, updated)
    case (let created?, nil): return created
    case (nil, let updated?): return updated
    case (nil, nil): return nil
    }
  }

  /// The authoritative watermark test, as the set of source rows it keeps.
  ///
  /// A `(id, session)` row is worth offering when **any** of its copies satisfies either:
  ///
  /// * the instant the record is *about* (`time.created`, which is when the request started) is newer
  ///   than the watermark — the ordinary case; or
  /// * opencode has rewritten the copy since (`time_updated` newer) — the streaming case. A completion
  ///   stores its first copy while tokens are still arriving and grows the counters afterwards, so
  ///   `time.created` can equal the watermark while `time_updated` is seconds later. On the
  ///   developer's database every one of the 2,701 token-bearing `session_message` rows has
  ///   `time_updated > time_created` by one to five seconds, so this half is the common one, not an
  ///   edge case.
  ///
  /// Testing only the record's own instant — which this filter used to do — threw away exactly the
  /// rows the SQL pre-filter widens itself to keep, so a row imported while its counters were partial
  /// was never offered again. Re-offering a row is cheap: the ledger writes only what actually
  /// differs (``LedgerStore/upsert(_:)``).
  ///
  /// The answer is a set of `rawHash`es rather than a filtered candidate list on purpose: the union
  /// chooses between a row's generations with `time_updated` and the `message`-wins rule, and that
  /// choice must not depend on the watermark, or an incremental scan and a full scan would offer
  /// *different records* for the same source row and the ledger would rewrite the row on every tick.
  /// The cost is recomputed from whichever record the merge chose, at that record's own instant.
  private static func reconsideredRawHashes(
    _ candidates: [Candidate], since: Date
  ) -> Set<String> {
    var keys: Set<String> = []
    for candidate in candidates
    where candidate.record.timestamp > since
      || Date(timeIntervalSince1970: TimeInterval(candidate.timeUpdated) / 1_000) > since
    {
      keys.insert(candidate.rawHash)
    }
    return keys
  }

  // MARK: - Connection

  /// Opens `file:PATH?mode=ro` — the URI form is what guarantees no journal or table write can happen.
  private func openReadOnly() throws -> OpaquePointer {
    var opened: OpaquePointer?
    let code = sqlite3_open_v2(
      Self.readOnlyURI(for: databaseURL), &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    guard code == SQLITE_OK, let database = opened else {
      let reason = Self.errorMessage(opened)
      if let opened { _ = sqlite3_close(opened) }
      throw Self.sqliteError(code, message: reason, context: "open")
    }

    let authorization = sqlite3_set_authorizer(database, denySensitiveTableReads, nil)
    guard authorization == SQLITE_OK else {
      _ = sqlite3_close(database)
      throw ImportError.databaseUnusable(
        reason: "could not install the credential-table read guard (\(authorization))")
    }
    return database
  }

  private static func readOnlyURI(for url: URL) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#")
    let path = url.path(percentEncoded: false)
    return "file:\(path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)?mode=ro"
  }

  private func execute(_ database: OpaquePointer, sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(database, sql, nil, nil, &message)
    guard code == SQLITE_OK else {
      let reason = message.map { String(cString: $0) } ?? "sqlite error \(code)"
      sqlite3_free(message)
      throw Self.sqliteError(code, message: reason, context: "exec")
    }
  }

  private static func sqliteError(_ code: Int32, message: String, context: String) -> ImportError {
    switch code & 0xFF {
    case SQLITE_BUSY, SQLITE_LOCKED:
      return .databaseBusy
    default:
      return .databaseUnusable(reason: "\(context): \(message)")
    }
  }

  private static func errorMessage(_ database: OpaquePointer?) -> String {
    guard let database, let message = sqlite3_errmsg(database) else {
      return "unknown sqlite error"
    }
    return String(cString: message)
  }

  /// Whether `name` matches one of opencode's credential-bearing table families.
  static func isSensitiveTableName(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return lowered.contains("credential") || lowered.hasPrefix("cred_")
      || lowered.contains("account") || lowered.hasPrefix("auth")
  }

  // MARK: - Schema detection

  private struct Schema {
    let hasMessage: Bool
    let hasSessionMessage: Bool
  }

  private func detectSchema(in database: OpaquePointer) throws -> Schema {
    let tables = Set(
      try queryStrings(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
    let required: Set<String> = ["id", "session_id", "data", "time_created", "time_updated"]
    let messageColumns = Set(try columnNames(database, of: "message"))
    let sessionColumns = Set(try columnNames(database, of: "session_message"))

    let hasMessage = tables.contains("message") && required.isSubset(of: messageColumns)
    let hasSessionMessage =
      tables.contains("session_message") && required.union(["type"]).isSubset(of: sessionColumns)
    guard hasMessage || hasSessionMessage else {
      throw ImportError.unsupportedSchema(
        reason: "neither message nor session_message has the columns this importer needs")
    }
    return Schema(hasMessage: hasMessage, hasSessionMessage: hasSessionMessage)
  }

  /// `PRAGMA` cannot take a bound parameter; the names passed here are literals in this file.
  private func columnNames(_ database: OpaquePointer, of table: String) throws -> [String] {
    try queryStrings(database, sql: "SELECT name FROM pragma_table_info('\(table)')")
  }

  private func queryStrings(_ database: OpaquePointer, sql: String) throws -> [String] {
    var statement: OpaquePointer?
    let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard prepare == SQLITE_OK, let prepared = statement else {
      throw Self.sqliteError(
        prepare, message: Self.errorMessage(database), context: "prepare schema query")
    }
    defer { _ = sqlite3_finalize(prepared) }

    var values: [String] = []
    while true {
      let step = sqlite3_step(prepared)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw Self.sqliteError(step, message: Self.errorMessage(database), context: "schema query")
      }
      if let value = columnText(prepared, 0) {
        values.append(value)
      }
    }
    return values
  }

  // MARK: - Reading rows

  /// Column order is fixed by `Generation.sql`: id, session_id, time_created, time_updated, data, type.
  private enum Generation {
    case message
    case sessionMessage

    /// With a watermark, the pre-filter keeps rows whose `time_created` **or** `time_updated` is at
    /// or after the cutoff, so a row written since the last scan — or one opencode has touched since
    /// — is always reconsidered. The timestamps inside `data` stay authoritative (`makeCandidate`
    /// prefers them whenever they are present), so this only narrows the read: the decision is the
    /// in-memory ``reconsideredRawHashes(_:since:)``, which keeps a row whose created instant is
    /// newer *or* whose `time_updated` is. This branch exists to avoid JSON-decoding a 400 MB history every
    /// fifteen minutes, never to decide on its own which rows are offered.
    func sql(sinceMilliseconds: Int64?) -> String {
      let filter =
        sinceMilliseconds == nil ? "" : " WHERE time_created >= ?1 OR time_updated >= ?1"
      switch self {
      case .message:
        return "SELECT id, session_id, time_created, time_updated, data FROM message" + filter
      case .sessionMessage:
        return "SELECT id, session_id, time_created, time_updated, data, type FROM session_message"
          + filter
      }
    }
  }

  private struct Candidate {
    let rawHash: String
    let record: UsageRecord
    let usage: TokenUsage
    let timeUpdated: Int64
    let isMessageGeneration: Bool
  }

  private func readCandidates(
    _ database: OpaquePointer,
    generation: Generation,
    sinceMilliseconds: Int64?
  ) throws -> [Candidate] {
    var statement: OpaquePointer?
    let prepare = sqlite3_prepare_v2(
      database, generation.sql(sinceMilliseconds: sinceMilliseconds), -1, &statement, nil)
    guard prepare == SQLITE_OK, let prepared = statement else {
      throw Self.sqliteError(prepare, message: Self.errorMessage(database), context: "prepare read")
    }
    defer { _ = sqlite3_finalize(prepared) }
    if let sinceMilliseconds {
      sqlite3_bind_int64(prepared, 1, sinceMilliseconds)
    }

    var candidates: [Candidate] = []
    while true {
      let step = sqlite3_step(prepared)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw Self.sqliteError(step, message: Self.errorMessage(database), context: "read")
      }
      guard let id = columnText(prepared, 0), let json = columnText(prepared, 4) else { continue }
      let type = generation == .sessionMessage ? columnText(prepared, 5) : nil
      if let candidate = makeCandidate(
        id: id,
        sessionID: columnText(prepared, 1),
        timeCreated: sqlite3_column_int64(prepared, 2),
        timeUpdated: sqlite3_column_int64(prepared, 3),
        type: type,
        json: json,
        generation: generation
      ) {
        candidates.append(candidate)
      }
    }
    return candidates
  }

  private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let bytes = sqlite3_column_text(statement, index)
    else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
  }

  private func makeCandidate(
    id: String,
    sessionID: String?,
    timeCreated: Int64,
    timeUpdated: Int64,
    type: String?,
    json: String,
    generation: Generation
  ) -> Candidate? {
    // A row that does not decode is skipped, not fatal: opencode's schema is versioned data and one
    // bad row must not block the whole ledger.
    guard let message = try? JSONDecoder().decode(MessageData.self, from: Data(json.utf8)),
      isAssistant(message, type: type, generation: generation),
      let tokens = message.tokens,
      tokens.usage.hasAnyTokens
    else { return nil }

    let milliseconds = message.time?.created ?? timeCreated
    let timestamp = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    let model = message.modelID ?? message.model?.id ?? ""
    let usage = tokens.usage
    let record = UsageRecord(
      timestamp: timestamp,
      source: .opencode,
      provider: Self.provider(forProviderID: message.providerID ?? message.model?.providerID),
      model: model,
      usage: usage,
      costUSD: costing(model, usage, timestamp),
      sessionID: sessionID
    )
    return Candidate(
      rawHash: Self.rawHash(id: id, sessionID: sessionID),
      record: record,
      usage: usage,
      timeUpdated: timeUpdated,
      isMessageGeneration: generation == .message
    )
  }

  private func isAssistant(
    _ message: MessageData,
    type: String?,
    generation: Generation
  ) -> Bool {
    switch generation {
    case .message:
      return message.role?.lowercased() == "assistant"
    case .sessionMessage:
      // The `type` column is the schema's own classifier; fall back to the JSON role if it is empty.
      let classifier = type.flatMap { $0.isEmpty ? nil : $0 } ?? message.role
      return classifier?.lowercased() == "assistant"
    }
  }

  static func provider(forProviderID providerID: String?) -> Provider {
    switch (providerID ?? "").lowercased() {
    case "deepseek": return .deepseek
    case "kilo": return .kilo
    case "openrouter": return .openrouter
    default: return .unknown
    }
  }

  // MARK: - Union and dedupe

  /// Unions both generations, deduped on `rawHash`. `message` rows are read first and win ties. Within
  /// an overlap that disagrees on the usage this importer maps, the merge instead prefers the row with
  /// the greater `time_updated` (a rewritten row is more likely a correction than a duplicate);
  /// overlaps that agree keep the `message` row even when the other copy is fresher.
  ///
  /// The derived `tokens.total` that only the `message` generation stores is deliberately not compared:
  /// on the developer's database 1635 of 1638 overlapping token-bearing rows differed only in that
  /// field, while 0 differed on the mapped counters — so `message` wins there.
  private func merge(_ candidates: [Candidate]) -> [ImportedRecord] {
    var order: [String] = []
    var groups: [String: [Candidate]] = [:]
    for candidate in candidates {
      if groups[candidate.rawHash] == nil {
        order.append(candidate.rawHash)
      }
      groups[candidate.rawHash, default: []].append(candidate)
    }

    let merged: [ImportedRecord] = order.compactMap { key in
      guard let group = groups[key],
        let messageRow = group.first(where: { $0.isMessageGeneration }) ?? group.first
      else { return nil }
      var winner = messageRow
      // Divergence is a property of one overlap group, not of the scan: a mismatch in one group must
      // not change which copy wins in a group whose copies agree. The comparison is against the
      // `message` row because that is the copy this merge prefers when they agree.
      let hasDivergence = group.contains { $0.usage != messageRow.usage }
      if hasDivergence {
        for candidate in group where candidate.timeUpdated > winner.timeUpdated {
          winner = candidate
        }
      }
      return ImportedRecord(record: winner.record, rawHash: winner.rawHash)
    }

    // Oldest first, so two runs over an unchanged database produce byte-identical output.
    return merged.sorted { lhs, rhs in
      if lhs.record.timestamp != rhs.record.timestamp {
        return lhs.record.timestamp < rhs.record.timestamp
      }
      return lhs.rawHash < rhs.rawHash
    }
  }

  /// SHA-256 over `source`, opencode row id and session id. `request.raw_hash` is UNIQUE in the ledger,
  /// so importing the same row twice inserts nothing.
  static func rawHash(id: String, sessionID: String?) -> String {
    let material = "\(UsageSource.opencode.rawValue)\u{1F}\(id)\u{1F}\(sessionID ?? "")"
    return SHA256.hash(data: Data(material.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  // MARK: - opencode's `data` JSON

  /// The subset of the `data` JSON this importer needs. Both generations decode with it: `message`
  /// stores `modelID`/`providerID` flat, `session_message` nests them under `model`.
  private struct MessageData: Decodable {
    struct ModelReference: Decodable {
      let id: String?
      let providerID: String?
    }

    struct TimeReference: Decodable {
      let created: Int64?
    }

    /// opencode's normalized counters. It stores the *uncached* prompt tokens in `input` and keeps
    /// reasoning separate, while DeepSeek's own fields fold both into prompt/completion.
    struct Tokens: Decodable {
      struct Cache: Decodable {
        let read: Int?
        let write: Int?
      }

      let input: Int?
      let output: Int?
      let reasoning: Int?
      let cache: Cache?

      /// Maps to DeepSeek semantics: `prompt == cacheHit + cacheMiss` and completion includes
      /// reasoning. Verified on the developer's database, where opencode's derived total equals
      /// `input + cache.read + cache.write + output + reasoning` for every row that stores it.
      var usage: TokenUsage {
        let input = input ?? 0
        let output = output ?? 0
        let reasoning = reasoning ?? 0
        let cacheRead = cache?.read ?? 0
        let cacheWrite = cache?.write ?? 0
        return TokenUsage(
          promptTokens: input + cacheWrite + cacheRead,
          completionTokens: output + reasoning,
          cacheHitTokens: cacheRead,
          cacheMissTokens: input + cacheWrite,
          reasoningTokens: reasoning
        )
      }
    }

    let role: String?
    let modelID: String?
    let providerID: String?
    let model: ModelReference?
    let time: TimeReference?
    let tokens: Tokens?
  }
}

/// Denies reads of tables that may hold plaintext provider credentials. A statement that touches one
/// fails with `SQLITE_AUTH` instead of pulling the secret into memory.
private func denySensitiveTableReads(
  _ userData: UnsafeMutableRawPointer?,
  _ actionCode: Int32,
  _ argument1: UnsafePointer<CChar>?,
  _ argument2: UnsafePointer<CChar>?,
  _ databaseName: UnsafePointer<CChar>?,
  _ triggerName: UnsafePointer<CChar>?
) -> Int32 {
  guard actionCode == SQLITE_READ, let table = argument1 else { return SQLITE_OK }
  return OpenCodeImporter.isSensitiveTableName(String(cString: table)) ? SQLITE_DENY : SQLITE_OK
}

extension TokenUsage {
  /// A row with no counters at all is noise (failed or aborted requests); the ledger skips it.
  fileprivate var hasAnyTokens: Bool {
    promptTokens != 0 || completionTokens != 0 || reasoningTokens != 0
      || cacheHitTokens != 0 || cacheMissTokens != 0
  }
}
