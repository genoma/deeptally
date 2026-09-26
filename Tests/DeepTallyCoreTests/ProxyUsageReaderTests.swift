// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

// MARK: - Fixtures

/// Hand-written response bodies in the shape api.deepseek.com returns, with dummy content only.
/// The counters match the captured sample (37 prompt / 4 completion / 4 reasoning), so the expected
/// ``TokenUsage`` below is the exact record the reader has to produce.

/// The id every chunk of one streamed completion carries, as in the captured sample.
private let streamID = "d8025f0e-6d1a-4c1e-9d2f-000000000001"

/// The usage object exactly as the API spells it: both cache counters, the OpenAI-style
/// `prompt_tokens_details`, and reasoning inside `completion_tokens`.
private let usagePayload =
  #"{"prompt_tokens":37,"completion_tokens":4,"total_tokens":41,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":4},"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":37}"#

private let nonStreamingBody = #"""
  {"id":"97b0f8f4-e249-4131-baed-caa2d31f9a13","object":"chat.completion","created":1790412467,"model":"deepseek-flash","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":\#(usagePayload)}
  """#

/// The final content chunk: the one line of a streamed body that carries usage.
private func streamUsageLine() -> String {
  #"data: {"id":"\#(streamID)","object":"chat.completion.chunk","created":1790412498,"model":"deepseek-flash","choices":[{"index":0,"delta":{"content":""},"finish_reason":"length"}],"usage":\#(usagePayload)}"#
}

/// Seven data lines: five content chunks whose usage is null, the final content chunk carrying the
/// usage object, then `data: [DONE]`.
private func streamedBody() -> String {
  let contents = ["Hel", "lo", ", ", "world", "!"]
  var lines: [String] = []
  for (index, content) in contents.enumerated() {
    let finishReason = index == contents.count - 1 ? #""length""# : "null"
    lines.append(
      #"data: {"id":"\#(streamID)","object":"chat.completion.chunk","created":1790412498,"model":"deepseek-flash","choices":[{"index":0,"delta":{"content":"\#(content)","reasoning_content":null},"finish_reason":\#(finishReason)}],"usage":null}"#
    )
  }
  lines.append(streamUsageLine())
  lines.append("data: [DONE]")
  return lines.map { $0 + "\n" }.joined()
}

/// The exact record the sample above maps to: reasoning stays inside `completionTokens` (4) and is
/// also carried as `reasoningTokens` (4).
private let expectedUsage = TokenUsage(
  promptTokens: 37, completionTokens: 4, totalTokens: 41, cacheHitTokens: 0,
  cacheMissTokens: 37, reasoningTokens: 4)

private let sampleDate = Date(timeIntervalSince1970: 1_790_412_467)

// MARK: - Tests

@Suite("Proxy usage reader")
struct ProxyUsageReaderTests {
  @Test("reads the non-streaming sample exactly, id and model included")
  func nonStreamingSample() throws {
    let parsed = try #require(
      ProxyUsageReader.usage(
        from: Data(nonStreamingBody.utf8), contentType: "application/json", recordedAt: sampleDate))

    #expect(parsed.responseID == "97b0f8f4-e249-4131-baed-caa2d31f9a13")
    #expect(parsed.model == "deepseek-flash")
    #expect(parsed.recordedAt == sampleDate)
    #expect(parsed.usage == expectedUsage)
  }

  @Test("reads the streamed sample from the last chunk, ignoring the null-usage ones")
  func streamedSample() throws {
    let parsed = try #require(
      ProxyUsageReader.usage(
        from: Data(streamedBody().utf8), contentType: "text/event-stream", recordedAt: sampleDate))

    #expect(parsed.responseID == streamID)
    #expect(parsed.model == "deepseek-flash")
    #expect(parsed.usage == expectedUsage)
  }

  @Test("a data line split at any boundary yields the same result")
  func chunkBoundaries() throws {
    let bytes = Array(streamedBody().utf8)

    for size in [1, 3, 7, 64, bytes.count] {
      var byteTap = ProxyUsageReader.StreamTap()
      var dataTap = ProxyUsageReader.StreamTap()
      for start in stride(from: 0, to: bytes.count, by: size) {
        let chunk = Array(bytes[start..<min(start + size, bytes.count)])
        // Both consume overloads, so the split-line reassembly is proven for each.
        byteTap.consume(chunk)
        dataTap.consume(Data(chunk))
      }

      let byteResult = try #require(byteTap.usage(recordedAt: sampleDate), "chunk size \(size)")
      #expect(byteResult == dataTap.usage(recordedAt: sampleDate), "chunk size \(size)")
      #expect(byteResult.usage == expectedUsage, "chunk size \(size)")
    }
  }

  @Test("a final usage line without a trailing newline still parses")
  func noTrailingNewline() throws {
    let body = streamUsageLine()

    let parsed = try #require(
      ProxyUsageReader.usage(
        from: Data(body.utf8), contentType: "text/event-stream", recordedAt: sampleDate))
    #expect(parsed.usage == expectedUsage)

    var tap = ProxyUsageReader.StreamTap()
    tap.consume(Data(body.utf8))
    #expect(tap.usage(recordedAt: sampleDate)?.usage == expectedUsage)
  }

  @Test("bodies without usable usage report nil instead of throwing")
  func unusableBodies() {
    let bodies: [(name: String, body: String, contentType: String?)] = [
      ("no usage", #"{"id":"x","model":"deepseek-flash","choices":[]}"#, "application/json"),
      ("null usage", #"{"id":"x","model":"deepseek-flash","usage":null}"#, "application/json"),
      (
        "usage without counters", #"{"id":"x","model":"deepseek-flash","usage":{}}"#,
        "application/json"
      ),
      (
        "malformed JSON", #"{"id":"x","model":"deepseek-flash","usage":{"prompt_tokens":"#,
        "application/json"
      ),
      (
        "missing model", #"{"id":"x","usage":\#(usagePayload)}"#,
        "application/json"
      ),
      ("empty body", "", "text/event-stream"),
      ("plain-text error page", "upstream connect error or disconnect/reset", "text/plain"),
      ("HTML error page", "<html><body>502 Bad Gateway</body></html>", "text/html"),
      (
        "SSE error stream", "event: error\ndata: {\"error\":{\"message\":\"boom\"}}\n\n",
        "text/event-stream"
      ),
      (
        "SSE stream without usage",
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"usage\":null}\ndata: [DONE]\n",
        "text/event-stream"
      ),
    ]

    for candidate in bodies {
      #expect(
        ProxyUsageReader.usage(
          from: Data(candidate.body.utf8), contentType: candidate.contentType,
          recordedAt: sampleDate) == nil,
        "\(candidate.name) should yield nil")
    }
  }

  @Test("an over-long content line is discarded, not the usage line after it")
  func overlongContentLine() throws {
    // The cap bounds memory; it is not a filter on usage. A content chunk can be far larger than
    // 256 KiB and never carries usage, so an over-long line is dropped as it arrives — and the
    // usage line, a small counters object well under the cap, still parses after it.
    let hugeContent = String(repeating: "x", count: 300 * 1024)
    let hugeLine =
      #"data: {"id":"\#(streamID)","object":"chat.completion.chunk","created":1790412498,"model":"deepseek-flash","choices":[{"index":0,"delta":{"content":"\#(hugeContent)"},"finish_reason":null}],"usage":null}"#
    let body = hugeLine + "\n" + streamUsageLine() + "\n" + "data: [DONE]\n"

    let parsed = try #require(
      ProxyUsageReader.usage(
        from: Data(body.utf8), contentType: "text/event-stream", recordedAt: sampleDate))

    #expect(parsed.usage == expectedUsage)
  }

  @Test("falls back to the OpenAI cache spelling and derives the miss count")
  func cacheCounterFallbacks() throws {
    let body =
      #"{"id":"x","model":"deepseek-flash","usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":64}}}"#

    let parsed = try #require(
      ProxyUsageReader.usage(
        from: Data(body.utf8), contentType: "application/json", recordedAt: sampleDate))

    #expect(parsed.usage.cacheHitTokens == 64)
    #expect(parsed.usage.cacheMissTokens == 36)  // prompt_tokens - cacheHitTokens
    #expect(parsed.usage.reasoningTokens == 0)
    #expect(parsed.usage.completionTokens == 10)
  }

  @Test("an explicit miss count wins over the derived one")
  func explicitMissCountWins() throws {
    let body =
      #"{"id":"x","model":"deepseek-flash","usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_cache_hit_tokens":64,"prompt_cache_miss_tokens":10}}"#

    let parsed = try #require(
      ProxyUsageReader.usage(
        from: Data(body.utf8), contentType: "application/json", recordedAt: sampleDate))

    #expect(parsed.usage.cacheHitTokens == 64)
    #expect(parsed.usage.cacheMissTokens == 10)
  }

  @Test("an absent response id is allowed, an absent model is not")
  func idOptionalModelRequired() throws {
    // The id is the dedupe key *when present*: the caller has its own key, so a body without one is
    // still recorded. A body without a model cannot be attributed or priced, so it is not.
    let withoutID = #"{"model":"deepseek-flash","usage":\#(usagePayload)}"#
    let parsed = try #require(
      ProxyUsageReader.usage(
        from: Data(withoutID.utf8), contentType: "application/json", recordedAt: sampleDate))
    #expect(parsed.responseID == nil)
    #expect(parsed.usage == expectedUsage)

    let withoutModel = #"{"id":"x","usage":\#(usagePayload)}"#
    #expect(
      ProxyUsageReader.usage(
        from: Data(withoutModel.utf8), contentType: "application/json", recordedAt: sampleDate)
        == nil)
  }

  @Test("the content type is a hint, not the answer")
  func contentTypeIsAHint() throws {
    let stream = Data(streamedBody().utf8)
    let object = Data(nonStreamingBody.utf8)

    // A streamed body with no header and a wrong header still parses.
    #expect(
      ProxyUsageReader.usage(from: stream, contentType: nil, recordedAt: sampleDate)?.usage
        == expectedUsage)
    #expect(
      ProxyUsageReader.usage(from: stream, contentType: "application/json", recordedAt: sampleDate)?
        .usage == expectedUsage)
    // And a single JSON object mislabelled as a stream still parses.
    #expect(
      ProxyUsageReader.usage(
        from: object, contentType: "text/event-stream", recordedAt: sampleDate)?.usage
        == expectedUsage)
  }

  @Test("a parsed response keeps reasoning inside completion through the ledger's accounting")
  func ledgerAccounting() throws {
    let parsed = try #require(
      ProxyUsageReader.usage(
        from: Data(nonStreamingBody.utf8), contentType: "application/json", recordedAt: sampleDate))
    let record = UsageRecord(
      timestamp: parsed.recordedAt,
      source: .proxy,
      provider: .deepseek,
      model: parsed.model,
      usage: parsed.usage,
      costUSD: 0)

    let directory = FileManager.default.temporaryDirectory
      .appending(path: "deeptally-proxy-usage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LedgerStore(url: directory.appending(path: "ledger.sqlite"))
    let inserted = try store.insert([record]) {
      "proxy:\($0.model):\($0.timestamp.timeIntervalSince1970)"
    }
    #expect(inserted == 1)

    let summary = try store.summary(
      since: sampleDate.addingTimeInterval(-1), until: sampleDate.addingTimeInterval(1),
      provider: .deepseek)

    // The ledger's storedCounters() maps input = cacheMissTokens and
    // output = completionTokens - reasoningTokens, so this row can only store output 0 with
    // reasoning 4 if completionTokens really is the API's 4 (reasoning included) and
    // reasoningTokens really is 4 (reasoning carried separately).
    #expect(summary.requestCount == 1)
    #expect(summary.inputTokens == 37)
    #expect(summary.outputTokens == 0)
    #expect(summary.reasoningTokens == 4)
    #expect(summary.cacheReadTokens == 0)
  }
}
