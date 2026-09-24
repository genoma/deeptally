// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Non-streaming responses

/// A non-streaming `POST /chat/completions` body. Only the fields the ledger needs are decoded;
/// completion content is deliberately never read.
public struct ChatCompletionEnvelope: Sendable, Decodable, Equatable {
  /// One entry of `choices`. Only `finish_reason` is of interest — not the assistant's content.
  public struct Choice: Sendable, Decodable, Equatable {
    public let index: Int?
    public let finishReason: String?

    public init(index: Int? = nil, finishReason: String? = nil) {
      self.index = index
      self.finishReason = finishReason
    }

    private enum CodingKeys: String, CodingKey {
      case index
      case finishReason = "finish_reason"
    }
  }

  public let model: String?
  public let choices: [Choice]
  public let usage: TokenUsage?

  public init(model: String? = nil, choices: [Choice] = [], usage: TokenUsage? = nil) {
    self.model = model
    self.choices = choices
    self.usage = usage
  }

  /// The `(model, usage)` pair a caller records in the ledger, or `nil` when the body omitted either.
  public var modelAndUsage: (model: String, usage: TokenUsage)? {
    guard let model, !model.isEmpty, let usage else { return nil }
    return (model, usage)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
    usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case choices
    case usage
  }
}

// MARK: - SSE plumbing

/// Splits a byte stream into lines, buffering whatever follows the last newline so a line that is
/// split across two chunks is reassembled before it is handed on.
private struct SSELineBuffer: Sendable {
  private var pending = Data()

  /// Appends a chunk and returns every line that is now complete, with a trailing `\r` stripped.
  mutating func append(_ chunk: Data) -> [String] {
    pending.append(chunk)
    var lines: [String] = []
    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
      let line = pending[pending.startIndex..<newline]
      pending.removeSubrange(pending.startIndex...newline)
      lines.append(Self.text(of: line))
    }
    return lines
  }

  /// The final line of a stream that ended without a trailing newline, if there is one.
  mutating func flush() -> String? {
    guard !pending.isEmpty else { return nil }
    let line = Self.text(of: pending)
    pending.removeAll(keepingCapacity: false)
    return line
  }

  private static func text(of data: Data) -> String {
    var line = String(decoding: data, as: UTF8.self)
    if line.hasSuffix("\r") {
      line.removeLast()
    }
    return line
  }
}

private enum SSE {
  /// The payload of a `data:` line; `nil` for keep-alives (empty lines), comments (`:`) and any
  /// other field (`event:`, `id:`, `retry:`). A trailing line terminator is tolerated.
  static func payload(of rawLine: String) -> String? {
    var line = Substring(rawLine)
    while let last = line.last, last == "\r" || last == "\n" {
      line = line.dropLast()
    }
    guard !line.isEmpty, !line.hasPrefix(":"), line.hasPrefix("data:") else { return nil }
    var payload = line.dropFirst("data:".count)
    if payload.first == " " {
      payload = payload.dropFirst()
    }
    return payload.isEmpty ? nil : String(payload)
  }
}

// MARK: - Streaming

/// Collects the final `usage` object from a streamed `POST /chat/completions` response.
///
/// DeepSeek puts usage on the last content chunk; there is no separate usage-only chunk. With
/// `stream_options.include_usage: true` every chunk carries a `usage` key (null until the last), so
/// both shapes are accepted: chunks with `usage: null` are ignored, and the last non-null usage wins.
/// A stream that never carries usage is not an error — `usage` simply stays `nil`.
public struct UsageStreamAccumulator: Sendable {
  /// The most recent non-null `usage` seen, or `nil` while (or unless) the stream carries one.
  public private(set) var usage: TokenUsage?
  /// True once a `data: [DONE]` line has been fed.
  public private(set) var sawDoneMarker = false
  private var isClosed = false
  private var buffer = SSELineBuffer()

  public init() {}

  /// Feeds a raw byte chunk. A line split across two chunks is buffered until it completes.
  public mutating func feed(_ chunk: Data) {
    guard !isClosed else { return }
    for line in buffer.append(chunk) {
      if handle(line) { return }
    }
  }

  /// Feeds one complete SSE line; a trailing `\r` or `\n` is tolerated.
  public mutating func feed(line: String) {
    guard !isClosed else { return }
    _ = handle(line)
  }

  /// Ends the stream: flushes a trailing line that carried no newline, then returns the final usage.
  /// `nil` means the stream carried no usage, which is not an error.
  @discardableResult
  public mutating func finish() -> TokenUsage? {
    guard !isClosed else { return usage }
    if let trailing = buffer.flush() {
      _ = handle(trailing)
    }
    isClosed = true
    return usage
  }

  /// Returns true when the line terminated the stream (`data: [DONE]`).
  private mutating func handle(_ line: String) -> Bool {
    guard let payload = SSE.payload(of: line) else { return false }
    if payload == "[DONE]" {
      sawDoneMarker = true
      isClosed = true
      return true
    }
    guard let data = payload.data(using: .utf8),
      let chunk = try? JSONDecoder().decode(UsageChunk.self, from: data),
      let decoded = chunk.usage
    else { return false }
    usage = decoded
    return false
  }
}

private struct UsageChunk: Decodable {
  let usage: TokenUsage?
}

/// Captures the model id from the first streamed chunk that carries one. Later chunks never
/// overwrite it, and a stream without a model id leaves `model` as `nil`.
public struct StreamingModelExtractor: Sendable {
  public private(set) var model: String?
  private var buffer = SSELineBuffer()

  public init() {}

  /// Feeds a raw byte chunk. A line split across two chunks is buffered until it completes.
  public mutating func feed(_ chunk: Data) {
    guard model == nil else { return }
    for line in buffer.append(chunk) {
      handle(line)
      if model != nil { return }
    }
  }

  /// Feeds one complete SSE line; a trailing `\r` or `\n` is tolerated.
  public mutating func feed(line: String) {
    guard model == nil else { return }
    handle(line)
  }

  private mutating func handle(_ line: String) {
    guard let payload = SSE.payload(of: line),
      let data = payload.data(using: .utf8),
      let chunk = try? JSONDecoder().decode(ModelChunk.self, from: data),
      let candidate = chunk.model,
      !candidate.isEmpty
    else { return }
    model = candidate
  }
}

private struct ModelChunk: Decodable {
  let model: String?
}

// MARK: - Error envelopes

/// The body of a failed DeepSeek call. Error bodies are **not contractual**: only `message` is read,
/// and only when it is present — never `type` or `code`. Malformed bodies decode to an empty detail.
public struct ErrorEnvelope: Sendable, Decodable, Equatable {
  /// `{ "error": { "message": "…" } }` — the documented shape.
  public struct ErrorBody: Sendable, Decodable, Equatable {
    public let message: String?

    public init(message: String? = nil) {
      self.message = message
    }
  }

  public let error: ErrorBody?
  /// A bare top-level `message`, which some OpenAI-compatible gateways return instead.
  public let message: String?

  public init(error: ErrorBody? = nil, message: String? = nil) {
    self.error = error
    self.message = message
  }

  /// The best available human-readable detail; empty when the body carried none.
  public var detail: String { error?.message ?? message ?? "" }

  /// Decodes tolerantly: a body that is not JSON, or that omits `error.message`, yields an empty detail.
  public static func decode(from data: Data) -> ErrorEnvelope {
    (try? JSONDecoder().decode(ErrorEnvelope.self, from: data)) ?? ErrorEnvelope()
  }
}

/// A failed HTTP call reduced to the cases the app reacts to. The numeric status stays available
/// for diagnostics; user-facing copy lives in `userFacingMessage`. Never contains the API key.
public enum DeepSeekAPIError: Swift.Error, Sendable, Equatable {
  case unauthorized
  case insufficientBalance
  case rateLimited
  case other(status: Int, message: String)

  /// 401/402/429 become named cases; every other status keeps its code and server message.
  public init(status: Int, envelope: ErrorEnvelope) {
    switch status {
    case 401: self = .unauthorized
    case 402: self = .insufficientBalance
    case 429: self = .rateLimited
    default: self = .other(status: status, message: envelope.detail)
    }
  }

  /// Convenience for a raw body; parsing never fails, so this does not throw.
  public init(status: Int, body: Data) {
    self.init(status: status, envelope: ErrorEnvelope.decode(from: body))
  }

  public var statusCode: Int {
    switch self {
    case .unauthorized: return 401
    case .insufficientBalance: return 402
    case .rateLimited: return 429
    case .other(let status, _): return status
    }
  }

  /// The server's message when it had one, otherwise empty.
  public var serverMessage: String {
    switch self {
    case .unauthorized, .insufficientBalance, .rateLimited: return ""
    case .other(_, let message): return message
    }
  }

  public var userFacingMessage: String {
    switch self {
    case .unauthorized: return "Authentication failed (401). Check the API key."
    case .insufficientBalance: return "Insufficient balance (402)."
    case .rateLimited: return "Rate limited (429). Try again shortly."
    case .other(let status, let message):
      return message.isEmpty ? "HTTP \(status)." : "HTTP \(status): \(message)"
    }
  }
}
