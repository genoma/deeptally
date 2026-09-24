// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The ledger's CSV dialect: RFC 4180 quoting, a fixed set of columns, one line per `request` row.
///
/// CSV is an interchange and inspection format here, never the primary store (docs/PLAN.md §4), so
/// this namespace only knows how to write a row and how to turn text back into a row. It never
/// touches the database: `LedgerStore` owns the I/O, and a malformed file is reported before a
/// single row is written.
///
/// Columns, in the order ``headerLine`` writes them:
/// `ts,source,provider,model,input,output,reasoning,cache_read,cache_write,cost_usd,session_id,raw_hash`.
/// On import the header is read by name, so a reordered or extended file still works.
enum LedgerCSV {
  static let columns = [
    "ts", "source", "provider", "model", "input", "output", "reasoning", "cache_read",
    "cache_write", "cost_usd", "session_id", "raw_hash",
  ]

  static let headerLine = columns.joined(separator: ",")

  /// Amounts in this format are always `.`-separated; parsing them with the user's locale would
  /// read `0.5` as 5 in a comma-decimal locale.
  private static let posixLocale = Locale(identifier: "en_US_POSIX")

  /// One physical CSV record. `line` is where the record starts, counting the header as line 1.
  struct Row {
    let fields: [String]
    let line: Int
  }

  /// The column positions a file's header declares, so rows can be read by name.
  struct Layout {
    let positions: [String: Int]
    /// How many fields every data row must have, taken from the header they are read with.
    let fieldCount: Int

    init(headerFields: [String], line: Int) throws {
      var positions: [String: Int] = [:]
      for (index, field) in headerFields.enumerated() {
        let name = field.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        guard positions[name] == nil else {
          throw LedgerError.malformedCSV(line: line, reason: "the column \(name) is listed twice")
        }
        positions[name] = index
      }
      for column in LedgerCSV.columns where positions[column] == nil {
        throw LedgerError.malformedCSV(
          line: line, reason: "the header is missing the \(column) column")
      }
      self.positions = positions
      fieldCount = headerFields.count
    }

    /// The raw field for a column. The header guarantees the column exists, so a missing position
    /// is only possible for a row with too few fields — which `decode` rejects first.
    func value(_ fields: [String], _ column: String) -> String {
      guard let position = positions[column], position < fields.count else { return "" }
      return fields[position]
    }
  }

  /// One CSV row, ready to insert.
  struct DecodedRow {
    let record: UsageRecord
    /// The row's dedupe key, taken from the file so a repeated import is a no-op.
    let rawHash: String
  }

  // MARK: - Writing

  static func line(_ fields: [String]) -> String {
    fields.map(escaped).joined(separator: ",")
  }

  private static func escaped(_ field: String) -> String {
    let needsQuotes = field.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
    guard needsQuotes else { return field }
    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  // MARK: - Reading

  /// Parses RFC 4180 text: `"` quotes a field, `""` inside a quoted field is a literal quote, and a
  /// quoted field may contain commas and newlines. LF and CRLF both end a record, and a blank line
  /// is skipped.
  static func parse(_ text: String) throws -> [Row] {
    var rows: [Row] = []
    var fields: [String] = []
    var field = ""
    var inQuotes = false
    var line = 1
    var recordStart = 1
    var index = text.startIndex

    while index < text.endIndex {
      let character = text[index]
      if inQuotes {
        switch character {
        case "\"":
          let next = text.index(after: index)
          if next < text.endIndex, text[next] == "\"" {
            field.append("\"")
            index = next
          } else {
            inQuotes = false
          }
        case "\n":
          line += 1
          field.append(character)
        default:
          field.append(character)
        }
        index = text.index(after: index)
        continue
      }

      switch character {
      case "\"":
        guard field.isEmpty else {
          throw LedgerError.malformedCSV(
            line: line, reason: "a quote appeared inside an unquoted field")
        }
        inQuotes = true
      case ",":
        fields.append(field)
        field = ""
      case "\r":
        break
      case "\n":
        fields.append(field)
        field = ""
        let row = Row(fields: fields, line: recordStart)
        if !isBlank(row) { rows.append(row) }
        fields = []
        line += 1
        recordStart = line
      default:
        field.append(character)
      }
      index = text.index(after: index)
    }

    guard !inQuotes else {
      throw LedgerError.malformedCSV(
        line: recordStart, reason: "a quoted field is never closed")
    }
    if !fields.isEmpty || !field.isEmpty {
      fields.append(field)
      let row = Row(fields: fields, line: recordStart)
      if !isBlank(row) { rows.append(row) }
    }
    return rows
  }

  private static func isBlank(_ row: Row) -> Bool {
    row.fields.count == 1 && row.fields[0].isEmpty
  }

  /// Turns one row into a record. Every field is validated by name, so a broken file names the
  /// column it failed on instead of silently importing a zero.
  static func decode(fields: [String], layout: Layout, line: Int) throws -> DecodedRow {
    guard fields.count == layout.fieldCount else {
      throw LedgerError.malformedCSV(
        line: line, reason: "expected \(layout.fieldCount) fields, found \(fields.count)")
    }

    let ts = try integer(fields, layout, "ts", line: line, minimum: nil)
    let sourceName = trimmed(layout.value(fields, "source"))
    guard let source = UsageSource(rawValue: sourceName) else {
      throw LedgerError.malformedCSV(line: line, reason: "unknown source \"\(sourceName)\"")
    }
    let providerName = trimmed(layout.value(fields, "provider"))
    guard let provider = Provider(rawValue: providerName) else {
      throw LedgerError.malformedCSV(line: line, reason: "unknown provider \"\(providerName)\"")
    }
    let model = layout.value(fields, "model")
    guard !model.isEmpty else {
      throw LedgerError.malformedCSV(line: line, reason: "model is empty")
    }

    let cacheWrite = Int(try integer(fields, layout, "cache_write", line: line, minimum: 0))
    let cacheRead = Int(try integer(fields, layout, "cache_read", line: line, minimum: 0))
    let input = Int(try integer(fields, layout, "input", line: line, minimum: 0))
    let output = Int(try integer(fields, layout, "output", line: line, minimum: 0))
    let reasoning = Int(try integer(fields, layout, "reasoning", line: line, minimum: 0))

    let costField = trimmed(layout.value(fields, "cost_usd"))
    guard
      let costUSD = Decimal(string: costField, locale: posixLocale),
      costUSD >= 0
    else {
      throw LedgerError.malformedCSV(
        line: line, reason: "cost_usd \"\(costField)\" is not a non-negative decimal amount")
    }

    let rawHash = layout.value(fields, "raw_hash")
    guard !rawHash.isEmpty else {
      throw LedgerError.malformedCSV(
        line: line,
        reason: "raw_hash is required: without it a repeated import would count the row again")
    }

    let sessionID = layout.value(fields, "session_id")
    let record = UsageRecord(
      timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
      source: source,
      provider: provider,
      model: model,
      usage: TokenUsage(
        promptTokens: input + cacheWrite + cacheRead,
        completionTokens: output + reasoning,
        cacheHitTokens: cacheRead,
        cacheMissTokens: input + cacheWrite,
        reasoningTokens: reasoning
      ),
      costUSD: MicroUSD.decimal(MicroUSD.fromDecimal(costUSD)),
      sessionID: sessionID.isEmpty ? nil : sessionID
    )
    return DecodedRow(record: record, rawHash: rawHash)
  }

  private static func integer(
    _ fields: [String], _ layout: Layout, _ column: String, line: Int, minimum: Int64?
  ) throws -> Int64 {
    let raw = trimmed(layout.value(fields, column))
    guard let value = Int64(raw) else {
      throw LedgerError.malformedCSV(
        line: line, reason: "\(column) \"\(raw)\" is not a whole number")
    }
    if let minimum, value < minimum {
      throw LedgerError.malformedCSV(
        line: line, reason: "\(column) is \(value), which is below \(minimum)")
    }
    return value
  }

  private static func trimmed(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespaces)
  }
}
