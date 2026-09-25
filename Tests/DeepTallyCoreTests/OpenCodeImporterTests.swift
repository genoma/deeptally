// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3
import Testing

@testable import DeepTallyCore

// MARK: - Fixture database

/// A throwaway SQLite database in a temporary directory. Tests never open the real opencode database.
private final class FixtureDatabase {
  struct Row {
    let id: String
    let sessionID: String
    let timeCreated: Int64
    let timeUpdated: Int64
    let data: String
  }

  struct FixtureError: Error {
    let description: String
  }

  let directoryURL: URL
  let fileURL: URL
  private var handle: OpaquePointer?

  init() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-opencode-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    directoryURL = directory
    fileURL = directory.appending(path: "opencode.db")

    var opened: OpaquePointer?
    let code = sqlite3_open_v2(
      fileURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard code == SQLITE_OK, let database = opened else {
      if let opened { _ = sqlite3_close(opened) }
      throw FixtureError(description: "could not open fixture database (code \(code))")
    }
    handle = database
  }

  deinit {
    if let handle { _ = sqlite3_close(handle) }
  }

  func destroy() {
    if let handle {
      _ = sqlite3_close(handle)
      self.handle = nil
    }
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func execute(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(handle, sql, nil, nil, &message)
    guard code == SQLITE_OK else {
      let detail = message.map { String(cString: $0) } ?? "code \(code)"
      sqlite3_free(message)
      throw FixtureError(description: "\(detail) while running: \(sql)")
    }
  }

  func execute(_ sql: String, textParameters: [String]) throws {
    var statement: OpaquePointer?
    let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard prepare == SQLITE_OK, let prepared = statement else {
      throw FixtureError(description: "could not prepare statement (code \(prepare))")
    }
    defer { _ = sqlite3_finalize(prepared) }
    for (offset, parameter) in textParameters.enumerated() {
      bind(prepared, Int32(offset + 1), parameter)
    }
    let step = sqlite3_step(prepared)
    guard step == SQLITE_DONE else {
      throw FixtureError(description: "statement failed (code \(step)): \(sql)")
    }
  }

  func createMessageTable() throws {
    try execute(
      """
      CREATE TABLE message (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL,
        time_updated INTEGER NOT NULL,
        data TEXT NOT NULL
      )
      """)
  }

  func createSessionMessageTable() throws {
    try execute(
      """
      CREATE TABLE session_message (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        type TEXT NOT NULL,
        seq INTEGER NOT NULL,
        time_created INTEGER NOT NULL,
        time_updated INTEGER NOT NULL,
        data TEXT NOT NULL
      )
      """)
  }

  func insert(_ row: Row, into table: String) throws {
    try execute(
      "INSERT INTO \(table) (id, session_id, time_created, time_updated, data) "
        + "VALUES (?1, ?2, ?3, ?4, ?5)",
      textParameters: [row.id, row.sessionID, "\(row.timeCreated)", "\(row.timeUpdated)", row.data])
  }

  func insertSessionMessage(_ row: Row, type: String) throws {
    try execute(
      "INSERT INTO session_message (id, session_id, time_created, time_updated, data, type, seq) "
        + "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      textParameters: [
        row.id, row.sessionID, "\(row.timeCreated)", "\(row.timeUpdated)", row.data, type, "1",
      ])
  }

  private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
    _ = sqlite3_bind_text(
      statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }
}

// MARK: - Fixture rows

private struct TokenSpec {
  var input = 0
  var output = 0
  var reasoning = 0
  var cacheRead = 0
  var cacheWrite = 0
}

private func row(
  id: String,
  sessionID: String = "ses_test",
  created: Int64,
  updated: Int64? = nil,
  data: String
) -> FixtureDatabase.Row {
  FixtureDatabase.Row(
    id: id, sessionID: sessionID, timeCreated: created, timeUpdated: updated ?? created, data: data)
}

/// Generation (a): role, providerID and modelID flat in `data`, and a derived `tokens.total`.
private func generationAMessage(
  role: String = "assistant",
  providerID: String? = "deepseek",
  modelID: String? = "deepseek-flash",
  createdMilliseconds: Int64,
  tokens: TokenSpec?,
  cost: Double = 0.001
) -> String {
  var payload: [String: Any] = [
    "role": role,
    "time": ["created": createdMilliseconds],
    "cost": cost,
  ]
  if let providerID { payload["providerID"] = providerID }
  if let modelID { payload["modelID"] = modelID }
  if let tokens { payload["tokens"] = tokensObject(tokens, includeTotal: true) }
  return jsonString(payload)
}

/// Generation (b): a `type` column classifies the row and the model is nested; no `tokens.total`.
private func generationBMessage(
  providerID: String? = "deepseek",
  modelID: String? = "deepseek-flash",
  createdMilliseconds: Int64,
  tokens: TokenSpec?,
  cost: Double = 0.001
) -> String {
  var payload: [String: Any] = [
    "time": ["created": createdMilliseconds],
    "cost": cost,
  ]
  var model: [String: Any] = [:]
  if let providerID { model["providerID"] = providerID }
  if let modelID { model["id"] = modelID }
  if !model.isEmpty { payload["model"] = model }
  if let tokens { payload["tokens"] = tokensObject(tokens, includeTotal: false) }
  return jsonString(payload)
}

private func tokensObject(_ spec: TokenSpec, includeTotal: Bool) -> [String: Any] {
  var tokens: [String: Any] = [
    "input": spec.input,
    "output": spec.output,
    "reasoning": spec.reasoning,
    "cache": ["read": spec.cacheRead, "write": spec.cacheWrite],
  ]
  if includeTotal {
    tokens["total"] = spec.input + spec.output + spec.reasoning + spec.cacheRead + spec.cacheWrite
  }
  return tokens
}

private func jsonString(_ object: [String: Any]) -> String {
  guard let data = try? JSONSerialization.data(withJSONObject: object),
    let json = String(data: data, encoding: .utf8)
  else { return "{}" }
  return json
}

private func importer(for fixture: FixtureDatabase) -> OpenCodeImporter {
  OpenCodeImporter(databaseURL: fixture.fileURL) { _, _, _ in .zero }
}

// MARK: - Import behaviour

@Suite("OpenCode importer")
struct OpenCodeImporterTests {
  @Test("imports generation (a) message rows with mapped tokens, provider, timestamp and cost")
  func importsMessageGeneration() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()

    let created: Int64 = 1_787_800_000_000
    try fixture.insert(
      row(
        id: "msg_a1",
        sessionID: "ses_a",
        created: created,
        data: generationAMessage(
          createdMilliseconds: created,
          tokens: TokenSpec(input: 100, output: 40, reasoning: 8, cacheRead: 700, cacheWrite: 0))),
      into: "message")

    var costed: (model: String, usage: TokenUsage, date: Date)?
    let importer = OpenCodeImporter(databaseURL: fixture.fileURL) { model, usage, date in
      costed = (model, usage, date)
      return Decimal(string: "0.123") ?? .zero
    }
    let imported = try importer.importAll()

    #expect(imported.count == 1)
    let entry = try #require(imported.first)
    #expect(entry.record.source == .opencode)
    #expect(entry.record.provider == .deepseek)
    #expect(entry.record.model == "deepseek-flash")
    #expect(entry.record.sessionID == "ses_a")
    #expect(entry.record.costUSD == (Decimal(string: "0.123") ?? .zero))
    #expect(entry.record.timestamp == Date(timeIntervalSince1970: TimeInterval(created) / 1000))
    #expect(entry.record.usage.promptTokens == 800)
    #expect(entry.record.usage.completionTokens == 48)
    #expect(entry.record.usage.totalTokens == 848)
    #expect(entry.record.usage.cacheHitTokens == 700)
    #expect(entry.record.usage.cacheMissTokens == 100)
    #expect(entry.record.usage.reasoningTokens == 8)
    #expect(costed?.model == entry.record.model)
    #expect(costed?.usage == entry.record.usage)
    #expect(costed?.date == entry.record.timestamp)
    // Pinned digest of SHA256("opencode\u{1F}msg_a1\u{1F}ses_a"); rawHash must not drift.
    #expect(entry.rawHash == "00718930dfdee6e472f5ac6222b4d4272ec13a31d7022e3d020aba936511f4aa")
  }

  @Test("imports generation (b) session_message rows with the type column and nested model")
  func importsSessionMessageGeneration() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createSessionMessageTable()

    let created: Int64 = 1_787_900_000_000
    try fixture.insertSessionMessage(
      row(
        id: "msg_b1",
        sessionID: "ses_b",
        created: created,
        data: generationBMessage(
          providerID: "kilo",
          modelID: "kilo-auto",
          createdMilliseconds: created,
          tokens: TokenSpec(input: 50, output: 20, reasoning: 5, cacheRead: 30))),
      type: "assistant")

    let imported = try importer(for: fixture).importAll()

    #expect(imported.count == 1)
    let entry = try #require(imported.first)
    #expect(entry.record.provider == .kilo)
    #expect(entry.record.model == "kilo-auto")
    #expect(entry.record.sessionID == "ses_b")
    // prompt = input + cache.read and completion = output + reasoning, both DeepSeek semantics.
    #expect(entry.record.usage.promptTokens == 80)
    #expect(entry.record.usage.cacheHitTokens == 30)
    #expect(entry.record.usage.cacheMissTokens == 50)
    #expect(entry.record.usage.completionTokens == 25)
    #expect(entry.record.usage.reasoningTokens == 5)
  }

  @Test("reads a WAL-mode database read-only")
  func readsWALModeDatabase() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.execute("PRAGMA journal_mode = WAL")
    try fixture.createMessageTable()
    try fixture.insert(
      row(
        id: "msg_wal",
        created: 1_000,
        data: generationAMessage(
          modelID: "wal-model", createdMilliseconds: 1_000, tokens: TokenSpec(input: 1))),
      into: "message")

    let imported = try importer(for: fixture).importAll()

    #expect(imported.count == 1)
    #expect(imported.first?.record.model == "wal-model")
  }

  @Test("maps providerID strings and falls back to .unknown")
  func mapsProviderIDs() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()

    let entries: [(id: String, provider: String?, model: String)] = [
      ("msg_p1", "deepseek", "model-deepseek"),
      ("msg_p2", "kilo", "model-kilo"),
      ("msg_p3", "openrouter", "model-openrouter"),
      ("msg_p4", "mystery-gateway", "model-mystery"),
      ("msg_p5", nil, "model-without-provider"),
    ]
    for (offset, entry) in entries.enumerated() {
      let created = 1_000 + Int64(offset)
      try fixture.insert(
        row(
          id: entry.id,
          created: created,
          data: generationAMessage(
            providerID: entry.provider,
            modelID: entry.model,
            createdMilliseconds: created,
            tokens: TokenSpec(input: 1))),
        into: "message")
    }

    let imported = try importer(for: fixture).importAll()

    #expect(imported.map(\.record.provider) == [.deepseek, .kilo, .openrouter, .unknown, .unknown])
    #expect(imported.map(\.record.model) == entries.map(\.model))
  }

  @Test("skips rows whose tokens are absent or entirely zero")
  func skipsRowsWithoutTokens() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()

    try fixture.insert(
      row(
        id: "msg_absent",
        created: 1_000,
        data: generationAMessage(
          modelID: "absent", createdMilliseconds: 1_000, tokens: nil)),
      into: "message")
    try fixture.insert(
      row(
        id: "msg_zero",
        created: 2_000,
        data: generationAMessage(
          modelID: "zero", createdMilliseconds: 2_000, tokens: TokenSpec())),
      into: "message")
    try fixture.insert(
      row(
        id: "msg_kept",
        created: 3_000,
        data: generationAMessage(
          modelID: "kept", createdMilliseconds: 3_000, tokens: TokenSpec(output: 1))),
      into: "message")

    let imported = try importer(for: fixture).importAll()

    #expect(imported.map(\.record.model) == ["kept"])
  }

  @Test("skips non-assistant rows in both generations")
  func skipsNonAssistantRows() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()
    try fixture.createSessionMessageTable()

    try fixture.insert(
      row(
        id: "msg_user",
        created: 1_000,
        data: generationAMessage(
          role: "user", modelID: "message-user", createdMilliseconds: 1_000,
          tokens: TokenSpec(input: 5))),
      into: "message")
    try fixture.insert(
      row(
        id: "msg_assistant",
        created: 2_000,
        data: generationAMessage(
          modelID: "message-assistant", createdMilliseconds: 2_000, tokens: TokenSpec(input: 5))),
      into: "message")
    try fixture.insertSessionMessage(
      row(
        id: "msg_session_user",
        created: 3_000,
        data: generationBMessage(
          modelID: "session-user", createdMilliseconds: 3_000, tokens: TokenSpec(input: 5))),
      type: "user")
    try fixture.insertSessionMessage(
      row(
        id: "msg_session_assistant",
        created: 4_000,
        data: generationBMessage(
          modelID: "session-assistant", createdMilliseconds: 4_000, tokens: TokenSpec(input: 5))),
      type: "assistant")

    let imported = try importer(for: fixture).importAll()

    #expect(imported.map(\.record.model) == ["message-assistant", "session-assistant"])
  }

  @Test("unions both generations and prefers the message row when the mapped usage agrees")
  func unionsGenerations() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()
    try fixture.createSessionMessageTable()

    let overlapTokens = TokenSpec(input: 100, output: 5, reasoning: 1, cacheRead: 20)
    try fixture.insert(
      row(
        id: "msg_message_only",
        created: 1_000,
        data: generationAMessage(
          modelID: "message-only", createdMilliseconds: 1_000, tokens: TokenSpec(input: 10))),
      into: "message")
    try fixture.insert(
      row(
        id: "msg_overlap",
        sessionID: "ses_overlap",
        created: 2_000,
        updated: 500,
        data: generationAMessage(
          modelID: "message-wins", createdMilliseconds: 2_000, tokens: overlapTokens)),
      into: "message")
    // The session_message copy has a newer time_updated and no derived `total`, but the same counters.
    try fixture.insertSessionMessage(
      row(
        id: "msg_overlap",
        sessionID: "ses_overlap",
        created: 2_000,
        updated: 900,
        data: generationBMessage(
          modelID: "session-loses", createdMilliseconds: 2_000, tokens: overlapTokens)),
      type: "assistant")
    try fixture.insertSessionMessage(
      row(
        id: "msg_session_only",
        created: 3_000,
        data: generationBMessage(
          modelID: "session-only", createdMilliseconds: 3_000, tokens: TokenSpec(input: 7))),
      type: "assistant")

    let imported = try importer(for: fixture).importAll()

    #expect(imported.map(\.record.model) == ["message-only", "message-wins", "session-only"])
    let overlap = try #require(imported.first { $0.record.sessionID == "ses_overlap" })
    #expect(overlap.record.usage.cacheMissTokens == 100)
    #expect(overlap.record.usage.cacheHitTokens == 20)
    #expect(overlap.record.usage.completionTokens == 6)
  }

  @Test("prefers the row with the greater time_updated when mapped usage diverges")
  func prefersFresherRowOnDivergence() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()
    try fixture.createSessionMessageTable()

    try fixture.insert(
      row(
        id: "msg_overlap",
        sessionID: "ses_overlap",
        created: 2_000,
        updated: 500,
        data: generationAMessage(
          modelID: "stale", createdMilliseconds: 2_000, tokens: TokenSpec(input: 10))),
      into: "message")
    try fixture.insertSessionMessage(
      row(
        id: "msg_overlap",
        sessionID: "ses_overlap",
        created: 2_000,
        updated: 900,
        data: generationBMessage(
          modelID: "corrected", createdMilliseconds: 2_000, tokens: TokenSpec(input: 20))),
      type: "assistant")
    // Identical counters here, and here the session copy is the *fresher* one (5000 vs 100). It must
    // not inherit the time_updated preference from the divergent overlap above: divergence is decided
    // per overlap, so this group keeps the message row even though the session copy was written later.
    try fixture.insert(
      row(
        id: "msg_overlap2",
        sessionID: "ses_overlap2",
        created: 2_500,
        updated: 100,
        data: generationAMessage(
          modelID: "older-message", createdMilliseconds: 2_500, tokens: TokenSpec(input: 7))),
      into: "message")
    try fixture.insertSessionMessage(
      row(
        id: "msg_overlap2",
        sessionID: "ses_overlap2",
        created: 2_500,
        updated: 5_000,
        data: generationBMessage(
          modelID: "fresher-session", createdMilliseconds: 2_500, tokens: TokenSpec(input: 7))),
      type: "assistant")

    let imported = try importer(for: fixture).importAll()

    #expect(imported.map(\.record.model) == ["corrected", "older-message"])
    #expect(imported.map(\.record.usage.cacheMissTokens) == [20, 7])
  }

  @Test("two runs produce identical records and rawHashes")
  func isIdempotentAcrossRuns() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()
    try fixture.createSessionMessageTable()

    let overlapTokens = TokenSpec(input: 42, output: 7, cacheRead: 8)
    try fixture.insert(
      row(
        id: "msg_message_only",
        created: 1_000,
        data: generationAMessage(
          modelID: "message-only", createdMilliseconds: 1_000, tokens: TokenSpec(input: 3))),
      into: "message")
    try fixture.insert(
      row(
        id: "msg_overlap",
        sessionID: "ses_overlap",
        created: 2_000,
        updated: 500,
        data: generationAMessage(
          modelID: "message-overlap", createdMilliseconds: 2_000, tokens: overlapTokens)),
      into: "message")
    try fixture.insertSessionMessage(
      row(
        id: "msg_overlap",
        sessionID: "ses_overlap",
        created: 2_000,
        updated: 900,
        data: generationBMessage(
          modelID: "session-overlap", createdMilliseconds: 2_000, tokens: overlapTokens)),
      type: "assistant")
    try fixture.insertSessionMessage(
      row(
        id: "msg_session_only",
        created: 3_000,
        data: generationBMessage(
          modelID: "session-only", createdMilliseconds: 3_000, tokens: TokenSpec(input: 5))),
      type: "assistant")

    let importer = importer(for: fixture)
    let first = try importer.importAll()
    let second = try importer.importAll()

    #expect(first == second)
    #expect(first.count == 3)
    #expect(Set(first.map(\.rawHash)).count == first.count)
  }
}

// MARK: - Failure modes

@Suite("OpenCode importer errors")
struct OpenCodeImporterErrorTests {
  @Test("a missing database throws .databaseMissing")
  func missingDatabase() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-missing-\(UUID().uuidString)")
    let url = directory.appending(path: "opencode.db")

    #expect(throws: OpenCodeImporter.ImportError.databaseMissing(path: url.path)) {
      try OpenCodeImporter(databaseURL: url) { _, _, _ in .zero }.importAll()
    }
  }

  @Test("a file that is not a SQLite database throws .databaseUnusable")
  func unusableDatabase() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-unusable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "opencode.db")
    try Data("this is not a sqlite database".utf8).write(to: url)

    let error = #expect(throws: OpenCodeImporter.ImportError.self) {
      try OpenCodeImporter(databaseURL: url) { _, _, _ in .zero }.importAll()
    }
    guard case .databaseUnusable = error else {
      Issue.record("expected .databaseUnusable, got \(error)")
      return
    }
  }

  @Test("a database without either generation throws .unsupportedSchema")
  func unsupportedSchema() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.execute("CREATE TABLE unrelated (id TEXT PRIMARY KEY)")

    let error = #expect(throws: OpenCodeImporter.ImportError.self) {
      try importer(for: fixture).importAll()
    }
    guard case .unsupportedSchema = error else {
      Issue.record("expected .unsupportedSchema, got \(error)")
      return
    }
  }

  @Test("a locked database throws .databaseBusy instead of crashing")
  func lockedDatabase() throws {
    let fixture = try FixtureDatabase()
    defer {
      try? fixture.execute("ROLLBACK")
      fixture.destroy()
    }
    try fixture.createMessageTable()
    try fixture.execute("BEGIN EXCLUSIVE")

    let error = #expect(throws: OpenCodeImporter.ImportError.self) {
      try importer(for: fixture).importAll()
    }
    #expect(error == .databaseBusy)
  }
}

// MARK: - Credential safety

@Suite("OpenCode importer safety")
struct OpenCodeImporterSafetyTests {
  @Test("imports without reading credential, cred_*, account or auth tables")
  func neverReadsCredentialTables() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()

    let created: Int64 = 1_000_000
    try fixture.insert(
      row(
        id: "msg_legit",
        created: created,
        data: generationAMessage(
          modelID: "legit-model", createdMilliseconds: created,
          tokens: TokenSpec(input: 1, output: 1))),
      into: "message")

    // Each trap row would decode as a token-bearing assistant message with a marker model, so any
    // accidental read of a credential table would surface it in the result.
    let trap = generationAMessage(
      modelID: "LEAKED-FROM-CREDENTIALS",
      createdMilliseconds: 2_000_000,
      tokens: TokenSpec(input: 9_999, output: 9_999))
    for table in ["credential", "cred_tokens", "account", "account_state", "auth"] {
      try fixture.execute(
        """
        CREATE TABLE \(table) (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          time_created INTEGER NOT NULL,
          time_updated INTEGER NOT NULL,
          data TEXT NOT NULL,
          secret TEXT
        )
        """)
      try fixture.execute(
        "INSERT INTO \(table) (id, session_id, time_created, time_updated, data, secret) "
          + "VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        textParameters: ["msg_trap", "ses_trap", "2000000", "2000000", trap, "sk-fake-marker"])
    }

    let imported = try importer(for: fixture).importAll()

    #expect(imported.count == 1)
    #expect(imported.map(\.record.model) == ["legit-model"])
    #expect(!imported.contains { $0.record.model.contains("LEAKED") })

    #expect(OpenCodeImporter.isSensitiveTableName("credential"))
    #expect(OpenCodeImporter.isSensitiveTableName("cred_tokens"))
    #expect(OpenCodeImporter.isSensitiveTableName("account_state"))
    #expect(OpenCodeImporter.isSensitiveTableName("auth"))
    #expect(!OpenCodeImporter.isSensitiveTableName("message"))
    #expect(!OpenCodeImporter.isSensitiveTableName("session_message"))
  }
}

// MARK: - Incremental scans

/// Two assistant rows, one second apart, with different token counts.
private func insertTwoTokenRows(into fixture: FixtureDatabase) throws -> (older: Date, newer: Date)
{
  let older: Int64 = 1_787_800_000_000
  let newer: Int64 = 1_787_800_500_000
  try fixture.insert(
    row(
      id: "msg_old",
      sessionID: "ses_old",
      created: older,
      data: generationAMessage(
        modelID: "deepseek-flash", createdMilliseconds: older,
        tokens: TokenSpec(input: 100, cacheRead: 700))),
    into: "message")
  try fixture.insert(
    row(
      id: "msg_new",
      sessionID: "ses_new",
      created: newer,
      data: generationAMessage(
        modelID: "deepseek-flash", createdMilliseconds: newer,
        tokens: TokenSpec(input: 50, cacheRead: 20))),
    into: "message")
  return (
    Date(timeIntervalSince1970: TimeInterval(older) / 1_000),
    Date(timeIntervalSince1970: TimeInterval(newer) / 1_000)
  )
}

/// Deletes one ledger row through a second connection, standing in for a prune or a hand-cleaned file.
private func deleteLedgerRow(rawHash: String, at url: URL) throws {
  var handle: OpaquePointer?
  let open = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
  guard open == SQLITE_OK, let database = handle else {
    if let handle { _ = sqlite3_close(handle) }
    throw FixtureDatabase.FixtureError(description: "could not open the ledger (code \(open))")
  }
  defer { _ = sqlite3_close(database) }

  var statement: OpaquePointer?
  let prepare = sqlite3_prepare_v2(
    database, "DELETE FROM request WHERE raw_hash = ?1", -1, &statement, nil)
  guard prepare == SQLITE_OK, let prepared = statement else {
    throw FixtureDatabase.FixtureError(description: "could not prepare the delete")
  }
  defer { _ = sqlite3_finalize(prepared) }
  _ = sqlite3_bind_text(
    prepared, 1, rawHash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  guard sqlite3_step(prepared) == SQLITE_DONE else {
    throw FixtureDatabase.FixtureError(description: "the delete failed")
  }
}

private func makeTemporaryLedger() throws -> (store: LedgerStore, directory: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "deeptally-ledger-import-\(UUID().uuidString)")
  return (try LedgerStore(url: directory.appending(path: "ledger.sqlite")), directory)
}

@Suite("OpenCode importer incremental scan")
struct OpenCodeImporterIncrementalTests {
  @Test("a scan from the newest instant seen finds nothing new")
  func sinceAtLatestSeenFindsNothing() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()
    _ = try insertTwoTokenRows(into: fixture)

    let importer = importer(for: fixture)
    let full = try importer.importAll(since: nil)
    #expect(full.records.count == 2)
    let newest = try #require(full.latestSeen)
    #expect(newest == Date(timeIntervalSince1970: 1_787_800_500))

    let incremental = try importer.importAll(since: newest)
    #expect(incremental.records.isEmpty)
    #expect(incremental.latestSeen == nil)

    // A watermark just before the newest row pulls in exactly that row, and nothing older.
    let widened = try importer.importAll(since: newest.addingTimeInterval(-0.001))
    #expect(widened.records.map(\.record.sessionID) == ["ses_new"])
    #expect(widened.latestSeen == newest)

    // The full scan still sees both, so widening a watermark can always repair a scan.
    #expect(try importer.importAll().count == 2)
    #expect(try importer.importAll(since: nil).latestSeen == newest)
  }

  @Test(
    "a row opencode touched after the watermark is offered again even though its created instant equals it"
  )
  func touchedRowIsReoffered() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createSessionMessageTable()

    let created: Int64 = 1_787_800_000_000
    // opencode's streaming pattern: the row is stored when the request starts and rewritten as tokens
    // arrive. `time_created` stays put; only `time_updated` moves.
    let updated = created + 4_000
    try fixture.insertSessionMessage(
      row(
        id: "msg_streamed",
        sessionID: "ses_streamed",
        created: created,
        updated: updated,
        data: generationBMessage(
          createdMilliseconds: created, tokens: TokenSpec(input: 100, output: 40))),
      type: "assistant")

    let watermark = Date(timeIntervalSince1970: TimeInterval(created) / 1_000)
    let scan = try importer(for: fixture).importAll(since: watermark)

    // The row is offered although its own created instant is not newer than the watermark...
    #expect(scan.records.map(\.record.sessionID) == ["ses_streamed"])
    // ...carrying the counters the rewrite left behind...
    #expect(scan.records.first?.record.usage.cacheMissTokens == 100)
    #expect(scan.records.first?.record.usage.completionTokens == 40)
    // ...with the cost still anchored to `time_created`, not to `time_updated`.
    #expect(scan.records.first?.record.timestamp == watermark)
    // `latestSeen` covers the update as well as the creation, so the next pass does not re-offer this
    // row forever: the watermark advances past every instant the scan actually saw (review finding N3).
    // A later rewrite moves `time_updated` again, which outruns this watermark and re-offers the row -
    // that is the F1 guarantee, and the assertion below keeps both halves honest.
    #expect(scan.latestSeen == Date(timeIntervalSince1970: TimeInterval(updated) / 1_000))

    // The pass immediately after a touched-row import offers nothing at all.
    #expect(try importer(for: fixture).importAll(since: scan.latestSeen).records.isEmpty)

    // A watermark past both instants ends the re-offering, so the widened scan is not "everything".
    let pastBoth = Date(timeIntervalSince1970: TimeInterval(updated) / 1_000 + 1)
    #expect(try importer(for: fixture).importAll(since: pastBoth).records.isEmpty)
  }

  @Test("a touched copy re-offers an agreeing overlap, and the message row still wins it")
  func touchedOverlapIsReoffered() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()
    try fixture.createSessionMessageTable()

    let created: Int64 = 1_787_800_000_000
    let overlapTokens = TokenSpec(input: 100, output: 40, cacheRead: 20)
    // The `message` copy carries the same counters and was not touched after the scan...
    try fixture.insert(
      row(
        id: "msg_overlap",
        sessionID: "ses_overlap",
        created: created,
        updated: created,
        data: generationAMessage(
          modelID: "message-copy", createdMilliseconds: created, tokens: overlapTokens)),
      into: "message")
    // ...while the `session_message` copy of the same source row was rewritten four seconds later.
    try fixture.insertSessionMessage(
      row(
        id: "msg_overlap",
        sessionID: "ses_overlap",
        created: created,
        updated: created + 4_000,
        data: generationBMessage(
          modelID: "session-copy", createdMilliseconds: created, tokens: overlapTokens)),
      type: "assistant")

    let watermark = Date(timeIntervalSince1970: TimeInterval(created) / 1_000)
    let scan = try importer(for: fixture).importAll(since: watermark)

    // Offered once — the union still merges the two generations into one row — and the memory of the
    // touch does not change which copy wins, so an incremental scan offers the same record a full
    // scan would.
    #expect(scan.records.count == 1)
    #expect(scan.records.first?.record.model == "message-copy")
    #expect(scan.records.first?.record.usage.cacheMissTokens == 100)
  }

  @Test("a row deleted from the ledger is re-inserted by the next full scan, and only that row")
  func deletedRowIsReinserted() throws {
    let fixture = try FixtureDatabase()
    defer { fixture.destroy() }
    try fixture.createMessageTable()
    _ = try insertTwoTokenRows(into: fixture)

    let ledger = try makeTemporaryLedger()
    defer { try? FileManager.default.removeItem(at: ledger.directory) }
    let store = ledger.store

    let first = try importer(for: fixture).importAll(since: nil)
    #expect(try store.insert(first.records.map { (record: $0.record, rawHash: $0.rawHash) }) == 2)
    let before = try store.summary(since: .distantPast, until: .distantFuture)
    #expect(before.requestCount == 2)

    // The ledger, not the importer, remembers where the import got to.
    let newest = try #require(first.latestSeen)
    try store.recordImportWatermark(newest, for: .opencode)
    let watermark = try #require(try store.importWatermark(for: .opencode))

    // The next tick re-reads nothing and stores nothing.
    let incremental = try importer(for: fixture).importAll(since: watermark)
    #expect(incremental.records.isEmpty)
    #expect(
      try store.insert(incremental.records.map { (record: $0.record, rawHash: $0.rawHash) }) == 0)
    #expect(try store.summary(since: .distantPast, until: .distantFuture) == before)

    // A row goes missing — a prune, or a ledger someone cleaned by hand.
    let missing = try #require(first.records.first)
    try deleteLedgerRow(rawHash: missing.rawHash, at: store.url)
    #expect(try store.summary(since: .distantPast, until: .distantFuture).requestCount == 1)

    // A full scan offers both rows again; `raw_hash` uniqueness stores only the missing one, so the
    // summary comes back identical instead of counting the surviving row twice.
    let rescan = try importer(for: fixture).importAll()
    #expect(rescan.count == 2)
    #expect(try store.insert(rescan.map { (record: $0.record, rawHash: $0.rawHash) }) == 1)
    #expect(try store.summary(since: .distantPast, until: .distantFuture) == before)
  }
}
