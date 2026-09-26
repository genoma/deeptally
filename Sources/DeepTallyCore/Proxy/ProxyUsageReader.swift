// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reads the `usage` object out of a response the proxy forwarded to a client.
///
/// DeepSeek has no usage endpoint, so the per-response `usage` object is the only API-level
/// accounting signal. The proxy sees that body as it passes through; this reader turns it into a
/// ``ProxyUsage`` without ever touching the message content beside it — a line is decoded only when
/// it can carry a usage object, and only the usage-bearing line survives the call.
///
/// Both response shapes are handled: one JSON object (a non-streaming call) and `data:` lines (a
/// streamed one, where usage rides the final content chunk and is `null` on every other chunk).
public enum ProxyUsageReader {
  /// The usage in one whole response body, or `nil` when it carried none.
  ///
  /// `contentType` only chooses which reader goes first — `text/event-stream` reads lines, anything
  /// else reads one JSON object — and the other reader still gets a chance when the first finds
  /// nothing, because the header is a hint and a mislabelled body still has to work.
  ///
  /// Never throws and never fails on shape: a malformed body, a body without usage, an empty body
  /// and a plain-text error page all report `nil`. A response that names no model reports `nil`
  /// too, because nothing downstream could attribute or price it; an absent response `id` is fine,
  /// because it is optional and the caller has its own dedupe key.
  public static func usage(from body: Data, contentType: String?, recordedAt: Date)
    -> ProxyUsage?
  {
    if isEventStream(contentType) {
      return usageByLine(body, recordedAt: recordedAt)
        ?? usageByObject(body, recordedAt: recordedAt)
    }
    return usageByObject(body, recordedAt: recordedAt)
      ?? usageByLine(body, recordedAt: recordedAt)
  }

  /// Incremental reader for a **streamed** body: feed bytes as they arrive, ask for the usage at the
  /// end.
  ///
  /// It holds one line at a time and keeps only the newest line that carried usage, so a long
  /// completion costs one byte scan per line and a bounded amount of memory. A line split across
  /// `consume` calls is reassembled; one call may contain many lines.
  public struct StreamTap: Sendable {
    private var scanner = ProxyUsageLineScanner()

    public init() {}

    /// Feeds the next slice of the response body.
    public mutating func consume(_ bytes: [UInt8]) {
      scanner.consume(bytes)
    }

    /// Feeds the next chunk of the response body.
    public mutating func consume(_ data: Data) {
      scanner.consume(data)
    }

    /// The last usage in everything fed so far, or `nil` when there was none. A final line that
    /// ended without a newline still counts, so the tap needs no separate flush call.
    public func usage(recordedAt: Date) -> ProxyUsage? {
      scanner.usage(recordedAt: recordedAt)
    }
  }

  // MARK: - Whole-body entry points

  private static func usageByObject(_ body: Data, recordedAt: Date) -> ProxyUsage? {
    guard let envelope = try? JSONDecoder().decode(ProxyUsageBody.self, from: body),
      let parsed = envelope.parsedUsage()
    else { return nil }
    return parsed.proxyUsage(recordedAt: recordedAt)
  }

  private static func usageByLine(_ body: Data, recordedAt: Date) -> ProxyUsage? {
    var scanner = ProxyUsageLineScanner()
    scanner.consume(body)
    return scanner.usage(recordedAt: recordedAt)
  }

  /// True when the header names an SSE body; `contains` because a gateway may append a charset.
  private static func isEventStream(_ contentType: String?) -> Bool {
    contentType?.lowercased().contains("text/event-stream") ?? false
  }
}

/// One usage-bearing line as parsed, with the recorded instant still to come: the scanner keeps the
/// newest one while it works, and the caller's date is attached when the answer is built.
private struct ParsedUsage: Sendable, Equatable {
  let responseID: String?
  let model: String
  let usage: TokenUsage
}

extension ParsedUsage {
  fileprivate func proxyUsage(recordedAt: Date) -> ProxyUsage {
    ProxyUsage(responseID: responseID, model: model, usage: usage, recordedAt: recordedAt)
  }
}

/// Splits a byte stream into lines while holding at most one line, and remembers only the last line
/// that decoded into usage.
///
/// A line is dropped as soon as its newline arrives, and a line that grows past
/// ``maximumLineBytes`` is abandoned as it arrives and never decoded — its remaining bytes are
/// discarded one by one. That cap is safe precisely because the line that carries usage is a small
/// counters object, while the lines that grow large are content chunks, which never carry usage.
private struct ProxyUsageLineScanner: Sendable {
  /// The longest line this keeps. Content chunks can be far larger, and none of them carry usage,
  /// so an over-long line is discarded rather than buffered.
  static let maximumLineBytes = 256 * 1024

  private var line: [UInt8] = []
  private var isDiscardingOverlongLine = false
  private var latest: ParsedUsage?

  /// Feeds the next bytes, completing and discarding lines as newlines arrive.
  mutating func consume(_ bytes: some Sequence<UInt8>) {
    for byte in bytes {
      if byte == UInt8(ascii: "\n") {
        finishLine()
      } else if isDiscardingOverlongLine {
        continue
      } else if line.count < Self.maximumLineBytes {
        line.append(byte)
      } else {
        // The cap: from here on the rest of this line is dropped as it arrives.
        isDiscardingOverlongLine = true
        line.removeAll(keepingCapacity: false)
      }
    }
  }

  /// The last usage seen, or `nil` when there was none. The line still in the buffer counts, so a
  /// stream (or whole body) that ends without a final newline still reports its last line.
  func usage(recordedAt: Date) -> ProxyUsage? {
    (pendingUsage() ?? latest)?.proxyUsage(recordedAt: recordedAt)
  }

  /// The usage a not-yet-terminated final line carries, or `nil`. Non-mutating: the tap may be
  /// asked for the answer more than once.
  private func pendingUsage() -> ParsedUsage? {
    guard !isDiscardingOverlongLine, !line.isEmpty else { return nil }
    return Self.decode(line[...])
  }

  /// Ends the current line: decodes it into `latest` when it can carry usage, then drops it.
  private mutating func finishLine() {
    defer {
      line.removeAll(keepingCapacity: false)
      isDiscardingOverlongLine = false
    }
    guard !isDiscardingOverlongLine, !line.isEmpty else { return }
    if let parsed = Self.decode(line[...]) { latest = parsed }
  }

  /// Decodes one complete line, or returns `nil` when it is not a `data:` line, cannot carry usage,
  /// or does not decode into one. Never throws.
  private static func decode(_ line: ArraySlice<UInt8>) -> ParsedUsage? {
    // `[DONE]` and every other non-JSON payload fails `couldCarryUsage` (no `{`), so it is ignored
    // without a decode attempt, exactly like a content chunk with `"usage":null`.
    guard let payload = ssePayload(of: line),
      couldCarryUsage(payload),
      let envelope = try? JSONDecoder().decode(ProxyUsageBody.self, from: Data(payload)),
      let parsed = envelope.parsedUsage()
    else { return nil }
    return parsed
  }

  /// The JSON payload of an SSE `data:` line, or `nil` for everything else — keep-alives, comments
  /// and the other fields (`event:`, `id:`, `retry:`). A trailing `\r` is stripped, so `\r\n` and
  /// `\n` bodies behave the same.
  private static func ssePayload(of line: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
    var payload = line
    if payload.last == UInt8(ascii: "\r") { payload = payload.dropLast() }
    guard let first = payload.first,
      first != UInt8(ascii: ":"),
      payload.prefix(dataField.count).elementsEqual(dataField)
    else { return nil }
    payload = payload.dropFirst(dataField.count)
    if payload.first == UInt8(ascii: " ") { payload = payload.dropFirst() }
    return payload.isEmpty ? nil : payload
  }

  private static let dataField = Array("data:".utf8)

  /// The cheap byte gate that keeps a content chunk from being decoded: only a `"usage"` key with
  /// something other than `null` after it can carry a usage object. A line that fails the gate is
  /// skipped without a parse, which is what makes a stream of large content chunks cost one scan
  /// each rather than one JSON decode each.
  private static func couldCarryUsage(_ payload: ArraySlice<UInt8>) -> Bool {
    guard payload.contains(UInt8(ascii: "{")) else { return false }
    guard var keyStart = find(usageKey, in: payload, from: payload.startIndex) else { return false }
    while true {
      var cursor = payload.index(keyStart, offsetBy: usageKey.count)
      cursor = skipWhitespace(in: payload, from: cursor)
      if cursor < payload.endIndex, payload[cursor] == UInt8(ascii: ":") {
        cursor = skipWhitespace(in: payload, from: payload.index(after: cursor))
        if !matches(nullLiteral, in: payload, at: cursor) { return true }
      } else {
        // A `"usage"` that is not a key at all: let the decoder decide rather than guess.
        return true
      }
      // This occurrence was `"usage": null`; another occurrence can still carry the real one.
      guard let next = find(usageKey, in: payload, from: cursor) else { return false }
      keyStart = next
    }
  }

  private static let usageKey = Array("\"usage\"".utf8)
  private static let nullLiteral = Array("null".utf8)

  private static func find(
    _ needle: [UInt8], in haystack: ArraySlice<UInt8>, from start: Int
  ) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
    let lastStart = haystack.endIndex - needle.count
    var index = max(start, haystack.startIndex)
    while index <= lastStart {
      if haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
      index += 1
    }
    return nil
  }

  private static func matches(
    _ needle: [UInt8], in haystack: ArraySlice<UInt8>, at start: Int
  ) -> Bool {
    let end = start + needle.count
    guard start >= haystack.startIndex, end <= haystack.endIndex else { return false }
    return haystack[start..<end].elementsEqual(needle)
  }

  private static func skipWhitespace(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
    var index = start
    while index < bytes.endIndex, isWhitespace(bytes[index]) { index += 1 }
    return index
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
  }
}

/// The three fields of a response (or one streamed chunk) this reader needs. Everything else —
/// `choices`, deltas, the assistant's text — stays in the bytes and is never decoded into a value
/// that outlives the call.
private struct ProxyUsageBody: Decodable {
  let id: String?
  let model: String?
  let usage: ProxyUsageCounts?

  /// The usable record this body carries, or `nil` when it has no model to attribute the usage to
  /// or no usage object with the two counters every real response has.
  func parsedUsage() -> ParsedUsage? {
    guard let model, !model.isEmpty, let usage, let tokenUsage = usage.tokenUsage() else {
      return nil
    }
    return ParsedUsage(
      responseID: id.flatMap { $0.isEmpty ? nil : $0 }, model: model, usage: tokenUsage)
  }
}

/// The `usage` object as the API sends it, before the project's mapping turns it into
/// ``TokenUsage``. The two spellings of the cache counters and the reasoning detail are the part
/// that has to be exact.
private struct ProxyUsageCounts: Decodable {
  struct PromptDetails: Decodable {
    let cachedTokens: Int?

    private enum CodingKeys: String, CodingKey {
      case cachedTokens = "cached_tokens"
    }
  }

  struct CompletionDetails: Decodable {
    let reasoningTokens: Int?

    private enum CodingKeys: String, CodingKey {
      case reasoningTokens = "reasoning_tokens"
    }
  }

  let promptTokens: Int?
  let completionTokens: Int?
  let promptCacheHitTokens: Int?
  let promptCacheMissTokens: Int?
  let promptTokensDetails: PromptDetails?
  let completionTokensDetails: CompletionDetails?

  /// DeepSeek's usage object mapped to ``TokenUsage``, or `nil` when it is not a complete one — a
  /// usage object without the prompt and completion counts is not a measurement, and writing zeros
  /// for it would invent one.
  ///
  /// The mapping, exactly:
  /// * `cacheHitTokens` is `prompt_cache_hit_tokens`, falling back to
  ///   `prompt_tokens_details.cached_tokens` (the OpenAI spelling of the same number), else 0;
  /// * `cacheMissTokens` is `prompt_cache_miss_tokens`, else the rest of the prompt,
  ///   `max(0, prompt_tokens - cacheHitTokens)`;
  /// * `reasoningTokens` is `completion_tokens_details.reasoning_tokens`, else 0, and it stays
  ///   inside `completionTokens` where the API put it. The ledger derives
  ///   `output = completionTokens - reasoningTokens`, so removing it here would lose the split the
  ///   cost engine bills.
  func tokenUsage() -> TokenUsage? {
    guard let promptTokens, let completionTokens else { return nil }
    let cacheHitTokens = promptCacheHitTokens ?? promptTokensDetails?.cachedTokens ?? 0
    let cacheMissTokens = promptCacheMissTokens ?? max(0, promptTokens - cacheHitTokens)
    let reasoningTokens = completionTokensDetails?.reasoningTokens ?? 0
    return TokenUsage(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cacheHitTokens: cacheHitTokens,
      cacheMissTokens: cacheMissTokens,
      reasoningTokens: reasoningTokens
    )
  }

  private enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case promptCacheHitTokens = "prompt_cache_hit_tokens"
    case promptCacheMissTokens = "prompt_cache_miss_tokens"
    case promptTokensDetails = "prompt_tokens_details"
    case completionTokensDetails = "completion_tokens_details"
  }
}
