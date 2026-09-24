// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

/// The `usage` object DeepSeek returns once at the end of a response, reasoning tokens included.
private let usagePayload = #"""
  {"prompt_tokens":120,"completion_tokens":30,"total_tokens":150,"prompt_cache_hit_tokens":100,"prompt_cache_miss_tokens":20,"completion_tokens_details":{"reasoning_tokens":11}}
  """#

/// One SSE `data:` line carrying `json` as its payload.
private func dataLine(_ json: String) -> String { "data: \(json)" }

private func dataChunk(_ text: String) -> Data { Data(text.utf8) }

@Suite("Chat completion envelope")
struct ChatCompletionEnvelopeTests {
  @Test("decodes model, choices and usage from a non-streaming body")
  func decodesNonStreamingBody() throws {
    let json = #"""
      {
        "id": "chat-1",
        "object": "chat.completion",
        "model": "deepseek-flash",
        "choices": [
          { "index": 0, "message": { "role": "assistant" }, "finish_reason": "stop" }
        ],
        "usage": {
          "prompt_tokens": 1000,
          "completion_tokens": 200,
          "total_tokens": 1200,
          "prompt_cache_hit_tokens": 750,
          "prompt_cache_miss_tokens": 250,
          "completion_tokens_details": { "reasoning_tokens": 40 }
        }
      }
      """#

    let envelope = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: Data(json.utf8))
    let parsed = try #require(envelope.modelAndUsage)

    #expect(parsed.model == "deepseek-flash")
    #expect(parsed.usage.promptTokens == 1000)
    #expect(parsed.usage.cacheHitTokens + parsed.usage.cacheMissTokens == parsed.usage.promptTokens)
    #expect(parsed.usage.reasoningTokens == 40)
    #expect(envelope.choices.count == 1)
    #expect(envelope.choices.first?.finishReason == "stop")
  }

  @Test("a body without usage yields no model/usage pair")
  func decodesBodyWithoutUsage() throws {
    let json = #"""
      { "model": "deepseek-v4-pro", "choices": [{ "index": 0, "finish_reason": "stop" }] }
      """#

    let envelope = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: Data(json.utf8))

    #expect(envelope.model == "deepseek-v4-pro")
    #expect(envelope.usage == nil)
    #expect(envelope.modelAndUsage == nil)
  }

  @Test("an explicit null usage decodes as absent")
  func decodesNullUsage() throws {
    let json = #"{"model":"deepseek-flash","choices":[],"usage":null}"#

    let envelope = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: Data(json.utf8))

    #expect(envelope.usage == nil)
    #expect(envelope.modelAndUsage == nil)
  }
}

@Suite("Usage stream accumulator")
struct UsageStreamAccumulatorTests {
  @Test("reads usage from the chunk that carries it")
  func singleChunkUsage() {
    var accumulator = UsageStreamAccumulator()
    accumulator.feed(line: dataLine(#"{"choices":[{"delta":{"content":"hi"}}],"usage":null}"#))
    accumulator.feed(line: dataLine(#"{"choices":[],"usage":\#(usagePayload)}"#))
    accumulator.feed(line: "data: [DONE]")

    let usage = accumulator.finish()

    #expect(accumulator.sawDoneMarker)
    #expect(usage?.promptTokens == 120)
    #expect(usage?.totalTokens == 150)
    #expect(usage?.cacheHitTokens == 100)
    #expect(usage?.cacheMissTokens == 20)
    #expect(usage?.reasoningTokens == 11)
  }

  @Test("null usage on early chunks then the real usage on the last")
  func nullUsageUntilLastChunk() {
    var accumulator = UsageStreamAccumulator()

    accumulator.feed(dataChunk(dataLine(#"{"usage":null}"#) + "\n"))
    accumulator.feed(dataChunk(dataLine(#"{"usage":null}"#) + "\n"))
    #expect(accumulator.usage == nil)

    accumulator.feed(dataChunk(dataLine(#"{"choices":[],"usage":\#(usagePayload)}"#) + "\n"))
    accumulator.feed(dataChunk(dataLine("[DONE]") + "\n"))

    #expect(accumulator.usage?.promptTokens == 120)
    #expect(accumulator.finish()?.reasoningTokens == 11)
  }

  @Test("reassembles a data line split across two feed calls")
  func reassemblesSplitLine() {
    var accumulator = UsageStreamAccumulator()
    let line = dataLine(#"{"choices":[],"usage":\#(usagePayload)}"#) + "\n"
    let split = line.index(line.startIndex, offsetBy: 18)

    accumulator.feed(dataChunk(String(line[..<split])))
    #expect(accumulator.usage == nil)

    accumulator.feed(dataChunk(String(line[split...])))
    #expect(accumulator.usage?.promptTokens == 120)
  }

  @Test("buffers a line even when the split lands inside the data prefix")
  func reassemblesSplitPrefix() {
    var accumulator = UsageStreamAccumulator()

    accumulator.feed(dataChunk("dat"))
    accumulator.feed(dataChunk("a: [DONE]\n"))
    accumulator.feed(line: dataLine(#"{"choices":[],"usage":\#(usagePayload)}"#))

    #expect(accumulator.usage == nil)
    #expect(accumulator.sawDoneMarker)
  }

  @Test("ignores keep-alives, comments and other SSE fields")
  func ignoresNonDataLines() {
    var accumulator = UsageStreamAccumulator()

    accumulator.feed(line: "")
    accumulator.feed(line: ": keep-alive")
    accumulator.feed(line: "event: message")
    accumulator.feed(line: "id: 42")
    accumulator.feed(line: "retry: 1000")
    accumulator.feed(line: "data:")
    accumulator.feed(line: "data:rubbish")
    accumulator.feed(dataChunk("\n\n"))

    #expect(accumulator.usage == nil)
    #expect(!accumulator.sawDoneMarker)
    #expect(accumulator.finish() == nil)
  }

  @Test("stops at the [DONE] marker and ignores anything after it")
  func stopsAtDoneMarker() {
    var accumulator = UsageStreamAccumulator()

    accumulator.feed(line: dataLine(#"{"choices":[],"usage":\#(usagePayload)}"#))
    accumulator.feed(line: "data: [DONE]")
    accumulator.feed(
      line: dataLine(
        #"{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":1}}"#
      ))

    #expect(accumulator.sawDoneMarker)
    #expect(accumulator.usage?.promptTokens == 120)
    #expect(accumulator.finish()?.promptTokens == 120)
  }

  @Test("a stream that never carries usage ends with nil and does not throw")
  func streamWithoutUsage() {
    var accumulator = UsageStreamAccumulator()

    accumulator.feed(dataChunk(dataLine(#"{"choices":[{"delta":{"content":"hi"}}]}"#) + "\n"))
    accumulator.feed(dataChunk(dataLine("[DONE]") + "\n"))

    #expect(accumulator.usage == nil)
    #expect(accumulator.finish() == nil)
  }

  @Test("malformed chunks are skipped without crashing the accumulator")
  func skipsMalformedChunks() {
    var accumulator = UsageStreamAccumulator()

    accumulator.feed(line: "data: {not json at all")
    accumulator.feed(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0xFE, 0x0A]))  // invalid UTF-8
    accumulator.feed(line: dataLine(#"{"choices":[],"usage":"not an object"}"#))
    accumulator.feed(line: dataLine(#"{"choices":[],"usage":\#(usagePayload)}"#))

    #expect(accumulator.usage?.promptTokens == 120)
  }

  @Test("finish() flushes a final line that has no trailing newline")
  func flushesTrailingLine() {
    var accumulator = UsageStreamAccumulator()

    accumulator.feed(dataChunk(dataLine(#"{"choices":[],"usage":\#(usagePayload)}"#)))
    #expect(accumulator.usage == nil)

    #expect(accumulator.finish()?.promptTokens == 120)
  }

  @Test("decodes reasoning tokens from the streamed usage object")
  func decodesStreamedReasoningTokens() {
    let payload = #"""
      {"usage":{"prompt_tokens":5,"completion_tokens":9,"total_tokens":14,"prompt_cache_hit_tokens":4,"prompt_cache_miss_tokens":1,"completion_tokens_details":{"reasoning_tokens":6}}}
      """#

    var accumulator = UsageStreamAccumulator()
    accumulator.feed(line: dataLine(payload))

    #expect(accumulator.usage?.reasoningTokens == 6)
    #expect(accumulator.usage?.cacheHitTokens == 4)
  }
}

@Suite("Streaming model extractor")
struct StreamingModelExtractorTests {
  @Test("captures the model id from the first chunk that carries one")
  func capturesFirstModel() {
    var extractor = StreamingModelExtractor()

    extractor.feed(dataChunk(dataLine(#"{"choices":[{"delta":{"content":"x"}}]}"#) + "\n"))
    extractor.feed(dataChunk(dataLine(#"{"model":"deepseek-flash","choices":[]}"#) + "\n"))
    extractor.feed(line: dataLine(#"{"model":"deepseek-v4-pro","choices":[]}"#))

    #expect(extractor.model == "deepseek-flash")
  }

  @Test("stays nil when no chunk carries a model")
  func staysNilWithoutModel() {
    var extractor = StreamingModelExtractor()

    extractor.feed(dataChunk(": keep-alive\n"))
    extractor.feed(line: "data: [DONE]")

    #expect(extractor.model == nil)
  }
}

@Suite("Error envelopes")
struct ErrorEnvelopeTests {
  @Test("maps 401, 402 and 429 to named cases")
  func mapsNamedStatuses() {
    let unauthorized = Data(
      #"{"error":{"message":"Authentication Fails (no such user)","type":"authentication_error"}}"#
        .utf8)
    let insufficient = Data(
      #"{"error":{"message":"Insufficient Balance","type":"insufficient_balance"}}"#.utf8)

    #expect(DeepSeekAPIError(status: 401, body: unauthorized) == .unauthorized)
    #expect(DeepSeekAPIError(status: 402, body: insufficient) == .insufficientBalance)
    #expect(DeepSeekAPIError(status: 429, body: Data()) == .rateLimited)
    #expect(DeepSeekAPIError.unauthorized.statusCode == 401)
    #expect(DeepSeekAPIError.insufficientBalance.statusCode == 402)
    #expect(DeepSeekAPIError.rateLimited.statusCode == 429)
  }

  @Test("an unknown status keeps both the code and the server message")
  func mapsUnknownStatus() {
    let body = Data(#"{"error":{"message":"internal error","type":"server_error"}}"#.utf8)

    #expect(
      DeepSeekAPIError(status: 500, body: body) == .other(status: 500, message: "internal error"))
    #expect(
      DeepSeekAPIError(status: 503, body: Data("{}".utf8)) == .other(status: 503, message: ""))
    #expect(DeepSeekAPIError(status: 500, body: body).statusCode == 500)
    #expect(DeepSeekAPIError(status: 500, body: body).serverMessage == "internal error")
  }

  @Test("a body without a message field decodes tolerantly")
  func toleratesMissingMessage() {
    let envelope = ErrorEnvelope.decode(
      from: Data(#"{"error":{"type":"authentication_error"}}"#.utf8))

    #expect(envelope.error?.message == nil)
    #expect(envelope.detail.isEmpty)
    #expect(DeepSeekAPIError(status: 401, envelope: envelope) == .unauthorized)
    #expect(DeepSeekAPIError(status: 500, envelope: envelope) == .other(status: 500, message: ""))
  }

  @Test("a non-JSON body never throws and yields an empty detail")
  func toleratesNonJSONBody() {
    let envelope = ErrorEnvelope.decode(from: Data("<html>502 Bad Gateway</html>".utf8))

    #expect(envelope.error == nil)
    #expect(envelope.detail.isEmpty)
    #expect(
      DeepSeekAPIError(status: 502, body: Data("<html/>".utf8)) == .other(status: 502, message: ""))
  }

  @Test("falls back to a bare top-level message")
  func fallsBackToTopLevelMessage() {
    let envelope = ErrorEnvelope.decode(from: Data(#"{"message":"upstream timeout"}"#.utf8))

    #expect(envelope.detail == "upstream timeout")
    #expect(DeepSeekAPIError(status: 504, envelope: envelope).serverMessage == "upstream timeout")
  }

  @Test("user-facing copy names the status and never the key")
  func userFacingMessages() {
    #expect(DeepSeekAPIError.unauthorized.userFacingMessage.contains("401"))
    #expect(DeepSeekAPIError.insufficientBalance.userFacingMessage.contains("402"))
    #expect(DeepSeekAPIError.rateLimited.userFacingMessage.contains("429"))
    #expect(DeepSeekAPIError.other(status: 500, message: "").userFacingMessage == "HTTP 500.")
    #expect(
      DeepSeekAPIError.other(status: 500, message: "boom").userFacingMessage == "HTTP 500: boom")
  }
}
