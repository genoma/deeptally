// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Network
import Synchronization
import Testing

@testable import DeepTallyApp

// MARK: - Bodies

/// One JSON body with the keys a test needs, serialised rather than spelled out so the quoting and
/// the escaping cannot drift from what the API sends.
func jsonBody(_ object: [String: Any]) -> Data {
  (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
}

/// The counters every response in this file carries: 100 prompt tokens with 80 of them cached, 20
/// completion tokens with 5 of them reasoning. The mapping the reader has to do is exactly this.
func completionCounters() -> [String: Any] {
  [
    "prompt_tokens": 100,
    "completion_tokens": 20,
    "total_tokens": 120,
    "prompt_cache_hit_tokens": 80,
    "prompt_cache_miss_tokens": 20,
    "completion_tokens_details": ["reasoning_tokens": 5],
  ]
}

/// One non-streaming completion: what `POST /chat/completions` answers with.
func completionBody() -> Data {
  jsonBody([
    "id": "chatcmpl-1",
    "object": "chat.completion",
    "model": "deepseek-flash",
    "choices": [["index": 0, "message": ["role": "assistant", "content": "hi"]]],
    "usage": completionCounters(),
  ])
}

/// One SSE `data:` line, as DeepSeek writes them, terminated by the blank line an event ends with.
func sseLine(_ object: [String: Any]) -> Data {
  Data("data: ".utf8) + jsonBody(object) + Data("\n\n".utf8)
}

/// The events one streamed completion is made of: two content chunks whose `usage` is `null`, the
/// usage chunk, and the terminator. The last data line is the only one that carries usage, which is
/// what the reader's incremental tap exists for.
func streamedCompletionEvents() -> [Data] {
  [
    sseLine([
      "id": "chatcmpl-2", "model": "deepseek-flash",
      "choices": [["index": 0, "delta": ["content": "Hel"]]], "usage": NSNull(),
    ]),
    sseLine([
      "id": "chatcmpl-2", "model": "deepseek-flash",
      "choices": [["index": 0, "delta": ["content": "lo"]]], "usage": NSNull(),
    ]),
    sseLine([
      "id": "chatcmpl-2", "model": "deepseek-flash", "choices": [Any](),
      "usage": completionCounters(),
    ]),
    Data("data: [DONE]\n\n".utf8),
  ]
}

/// The whole stream body, in order.
func streamedCompletionBody() -> Data {
  streamedCompletionEvents().reduce(Data(), +)
}

/// The same body cut where a network would cut it, including one JSON object split across two chunks,
/// so the tap has to reassemble a line and the client has to see the order regardless.
func streamedCompletionChunks() -> [Data] {
  var chunks = streamedCompletionEvents()
  let first = chunks[0]
  chunks[0] = Data(first.prefix(3))
  chunks.insert(Data(first.dropFirst(3)), at: 1)
  return chunks
}

/// One `GET` request: the client declares no body, so the `Content-Length` the upstream sees is the
/// proxy's own zero.
func getRequest(_ target: String) -> Data {
  Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
}

/// One `POST` request with whichever headers a test wants the proxy to see.
func postRequest(_ target: String, headers: [String] = [], body: Data = Data()) -> Data {
  var text = "POST \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
  for header in headers { text += header + "\r\n" }
  return Data("\(text)Content-Length: \(body.count)\r\n\r\n".utf8) + body
}

// MARK: - The upstream stub

/// The upstream seam as a test double: the requests it was given, and the answer it hands back.
///
/// `Mutex` rather than an actor so an assertion can read the request log without an `await` that
/// would let the server make progress while the test looks away.
final class StubProxyUpstream: ProxyUpstream, Sendable {
  /// What `send` answers with: a status, headers and a body — or the error that stands in for an
  /// upstream that never completed.
  struct Answer: Sendable {
    var statusCode = 200
    var headers: [ProxyHeader] = [ProxyHeader(name: "Content-Type", value: "application/json")]
    var body = ProxyUpstreamBody(Data())
    var failure: (any Error)?
  }

  private struct State: Sendable {
    var requests: [ProxyUpstreamRequest] = []
    var answer = Answer()
  }

  private let state = Mutex(State())

  /// Every request the proxy forwarded, oldest first.
  var requests: [ProxyUpstreamRequest] { state.withLock { $0.requests } }

  func setAnswer(_ answer: Answer) {
    state.withLock { $0.answer = answer }
  }

  func send(_ request: ProxyUpstreamRequest) async throws -> ProxyUpstreamResponse {
    let answer = state.withLock { state -> Answer in
      state.requests.append(request)
      return state.answer
    }
    if let failure = answer.failure { throw failure }
    return ProxyUpstreamResponse(
      statusCode: answer.statusCode, headers: answer.headers, body: answer.body)
  }
}

/// An upstream that failed before it could answer: a refused connection, a timeout.
struct StubUpstreamFailure: Error {}

/// One canned answer: a status, the headers a test wants to see passed through, and a body.
func stubAnswer(
  statusCode: Int = 200,
  headers: [ProxyHeader] = [ProxyHeader(name: "Content-Type", value: "application/json")],
  chunks: [Data]
) -> StubProxyUpstream.Answer {
  var answer = StubProxyUpstream.Answer()
  answer.statusCode = statusCode
  answer.headers = headers
  answer.body = ProxyUpstreamBody(chunks: chunks)
  return answer
}

/// The content type that makes the server stream instead of buffering.
let eventStreamHeader = ProxyHeader(name: "Content-Type", value: "text/event-stream")

// MARK: - The recorder stub

/// The recorder seam as a collector: every usage the server recorded, in order.
final class ProxyUsageCollector: Sendable {
  private let usages = Mutex<[ProxyUsage]>([])

  var recorded: [ProxyUsage] { usages.withLock { $0 } }

  /// The closure ``UsageProxyServer`` is built with.
  var recorder: ProxyUsageRecorder {
    { usage in self.usages.withLock { $0.append(usage) } }
  }
}

// MARK: - A raw HTTP client

/// An upstream body a test controls and can watch being cancelled.
final class CancelRecordedBody: Sendable {
  private let cancels = Mutex(0)

  var cancelCount: Int { cancels.withLock { $0 } }

  func wrap(_ chunks: AsyncThrowingStream<Data, any Error>) -> ProxyUpstreamBody {
    ProxyUpstreamBody(
      chunks: chunks,
      cancel: { self.cancels.withLock { $0 += 1 } })
  }
}

/// The bytes a test can watch while an exchange is still running: the raw client appends to this as
/// chunks arrive, so "the answer started before the upstream finished" is an assertion.
final class ReceivedBytes: Sendable {
  private let bytes = Mutex(Data())

  var text: String { bytes.withLock { String(decoding: $0, as: UTF8.self) } }
  var count: Int { bytes.withLock { $0.count } }

  func append(_ chunk: Data) { bytes.withLock { $0.append(chunk) } }
}

/// One HTTP/1.1 response as a client sees it: the status, the headers, and the entity body with any
/// transfer coding undone.
struct RawHTTPResponse {
  let statusCode: Int
  /// Header names lowercased: HTTP header names are case-insensitive.
  let headers: [String: String]
  let body: Data

  init(_ raw: Data) throws {
    guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else { throw RawHTTPError.noHead }
    let headByteCount = raw.distance(from: raw.startIndex, to: separator.lowerBound)
    let head = String(decoding: Data(raw.prefix(headByteCount)), as: UTF8.self)
    let bodyBytes = Data(raw.dropFirst(headByteCount + 4))

    var lines = head.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else { throw RawHTTPError.noStatusLine }
    let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2, let statusCode = Int(parts[1]) else { throw RawHTTPError.noStatusLine }
    self.statusCode = statusCode

    lines.removeFirst()
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = String(line[line.startIndex..<colon]).lowercased()
      headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    self.headers = headers
    body = headers["transfer-encoding"] == "chunked" ? try Self.dechunk(bodyBytes) : bodyBytes
  }

  /// Undoes `Transfer-Encoding: chunked`: each chunk is its length in hexadecimal, a CRLF, the bytes
  /// and another CRLF, ending with a zero-length chunk.
  private static func dechunk(_ bytes: Data) throws -> Data {
    var body = Data()
    var rest = bytes
    while true {
      guard let lineEnd = rest.range(of: Data("\r\n".utf8)) else { throw RawHTTPError.badChunk }
      let lineLength = rest.distance(from: rest.startIndex, to: lineEnd.lowerBound)
      let lengthText = String(decoding: Data(rest.prefix(lineLength)), as: UTF8.self)
      guard let size = Int(lengthText.split(separator: ";").first ?? "", radix: 16) else {
        throw RawHTTPError.badChunk
      }
      rest = Data(rest.dropFirst(rest.distance(from: rest.startIndex, to: lineEnd.upperBound)))
      if size == 0 { return body }
      guard rest.count >= size + 2 else { throw RawHTTPError.badChunk }
      body.append(Data(rest.prefix(size)))
      rest = Data(rest.dropFirst(size + 2))
    }
  }
}

/// Why a raw response could not be read. A test-only failure: the server's own answers are what the
/// tests assert on, so a malformed one has to fail loudly here rather than silently.
enum RawHTTPError: Error {
  case noHead
  case noStatusLine
  case badChunk
}

/// A raw HTTP/1.1 client over the same `Network` framework the server uses.
///
/// It exists so these assertions can be about the bytes on the wire: `URLSession` adds headers of its
/// own and undoes framing for the caller, and both are part of what is under test. One real
/// `URLSession` request against the same listener covers the case where that is the point.
enum RawProxyClient {
  /// Sends `request`, collects the raw answer, and returns it once the server closes the connection or
  /// `closeAfter` has arrived — the second is how a test makes a client go away mid-response.
  static func exchange(
    port: Int,
    request: Data,
    closeAfter marker: Data? = nil,
    onChunk: @escaping @Sendable (Data) -> Void = { _ in }
  ) async throws -> RawHTTPResponse {
    let connection = NWConnection(host: .ipv4(.loopback), port: endpointPort(port), using: .tcp)
    defer { connection.cancel() }
    let queue = DispatchQueue(label: "io.github.genoma.deeptally.tests.proxy-client")
    connection.start(queue: queue)
    try await send(request, over: connection)

    var raw = Data()
    while let chunk = try await receive(from: connection) {
      raw.append(chunk)
      onChunk(chunk)
      if let marker, raw.range(of: marker) != nil {
        // An abortive close, the way a cancelled request goes away: the proxy's next write to this
        // socket fails.
        connection.forceCancel()
        break
      }
    }
    return try RawHTTPResponse(raw)
  }

  /// The next bytes from the server, or `nil` when it closed the connection.
  private static func receive(from connection: NWConnection) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        data, _, _, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private static func send(_ data: Data, over connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data, isComplete: false,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        })
    }
  }

  /// Every port this file uses comes from a listener, so it is always a port number.
  private static func endpointPort(_ port: Int) -> NWEndpoint.Port {
    guard let value = UInt16(exactly: port) else {
      Issue.record("\(port) is not a port number")
      return .any
    }
    return NWEndpoint.Port(rawValue: value) ?? .any
  }
}

// MARK: - The server

/// The loopback proxy as a socket: what crosses the wire, what the upstream sees, and what is
/// recorded. Every test here drives the real listener over real loopback connections, with a stub
/// upstream and a collector — nothing reaches the network or the developer's ledger.
@Suite("Usage proxy server")
struct UsageProxyServerTests {
  /// A fixed instant, so a recorded row's own instant is asserted rather than tolerated.
  static let instant = Date(timeIntervalSince1970: 1_790_000_000)

  /// Starts the real listener on an ephemeral port, runs `body`, and stops it.
  private func withServer<T>(
    upstream: StubProxyUpstream,
    recorder: ProxyUsageCollector,
    _ body: (UsageProxyServer, Int) async throws -> T
  ) async throws -> T {
    let server = UsageProxyServer(
      upstream: upstream, record: recorder.recorder, now: { Self.instant })
    _ = await server.start(port: 0)
    let port = try #require(await server.boundPort, "the listener did not bind")
    defer { Task { await server.stop() } }
    let value = try await body(server, port)
    await server.stop()
    return value
  }

  @Test("a non-streaming response comes back unchanged and records one row")
  func jsonResponseIsForwardedAndRecorded() async throws {
    let upstream = StubProxyUpstream()
    let expected = completionBody()
    upstream.setAnswer(stubAnswer(chunks: [expected]))
    let collector = ProxyUsageCollector()

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      let response = try await RawProxyClient.exchange(
        port: port,
        request: postRequest("/chat/completions", body: Data(#"{"model":"deepseek-flash"}"#.utf8)))

      #expect(response.statusCode == 200)
      #expect(response.headers["content-type"] == "application/json")
      #expect(response.headers["content-length"] == "\(expected.count)")
      #expect(response.headers["connection"] == "close")
      // The bytes, not a re-encoded copy of them.
      #expect(response.body == expected)
    }

    let usage = try #require(collector.recorded.first)
    #expect(collector.recorded.count == 1)
    #expect(usage.responseID == "chatcmpl-1")
    #expect(usage.model == "deepseek-flash")
    #expect(usage.usage.promptTokens == 100)
    #expect(usage.usage.completionTokens == 20)
    #expect(usage.usage.cacheHitTokens == 80)
    #expect(usage.usage.cacheMissTokens == 20)
    #expect(usage.usage.reasoningTokens == 5)
    #expect(usage.recordedAt == Self.instant)
  }

  @Test("a streamed response arrives in order and records the usage chunk")
  func streamedResponseIsForwardedAndRecorded() async throws {
    let upstream = StubProxyUpstream()
    let expected = streamedCompletionBody()
    upstream.setAnswer(stubAnswer(headers: [eventStreamHeader], chunks: streamedCompletionChunks()))
    let collector = ProxyUsageCollector()

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      let response = try await RawProxyClient.exchange(
        port: port,
        request: postRequest("/chat/completions", body: Data(#"{"model":"deepseek-flash"}"#.utf8)))

      #expect(response.statusCode == 200)
      #expect(response.headers["content-type"] == "text/event-stream")
      // The body is delimited by the framing, not by a length the proxy would have to know first.
      #expect(response.headers["transfer-encoding"] == "chunked")
      #expect(response.headers["content-length"] == nil)
      // The entity body is every byte the upstream sent, once, in order — de-chunked by the client
      // exactly as a real SSE client would.
      #expect(response.body == expected)
    }

    let usage = try #require(collector.recorded.first)
    #expect(collector.recorded.count == 1)
    #expect(usage.responseID == "chatcmpl-2")
    #expect(usage.usage.promptTokens == 100)
    #expect(usage.usage.completionTokens == 20)
    #expect(usage.usage.cacheHitTokens == 80)
  }

  @Test("a chunk reaches the client before the upstream has finished its body")
  func streamingIsIncremental() async throws {
    let (chunks, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
    let upstream = StubProxyUpstream()
    var answer = StubProxyUpstream.Answer()
    answer.headers = [eventStreamHeader]
    answer.body = ProxyUpstreamBody(chunks: chunks, cancel: {})
    upstream.setAnswer(answer)
    let collector = ProxyUsageCollector()
    let received = ReceivedBytes()
    let firstChunk = sseLine([
      "id": "chatcmpl-3", "model": "deepseek-flash",
      "choices": [["index": 0, "delta": ["content": "Hel"]]], "usage": NSNull(),
    ])
    let usageChunk = sseLine([
      "id": "chatcmpl-3", "model": "deepseek-flash", "choices": [Any](),
      "usage": completionCounters(),
    ])
    let terminator = Data("data: [DONE]\n\n".utf8)

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      let exchange = Task {
        try await RawProxyClient.exchange(
          port: port,
          request: postRequest("/chat/completions", body: Data("{}".utf8)),
          onChunk: { received.append($0) })
      }
      feed.yield(firstChunk)

      // The upstream body is still open, and the client already holds the head and the first chunk:
      // nothing in the proxy waits for a response to finish before writing what it has.
      await waitUntil("the first chunk to reach the client") {
        received.text.contains("\"content\":\"Hel\"")
      }
      #expect(!received.text.contains("[DONE]"))

      feed.yield(usageChunk)
      feed.yield(terminator)
      feed.finish()

      let response = try await exchange.value
      #expect(response.body == firstChunk + usageChunk + terminator)
    }

    #expect(collector.recorded.count == 1)
    #expect(collector.recorded.first?.usage.completionTokens == 20)
  }

  @Test("a response with no usage records nothing")
  func responseWithoutUsageRecordsNothing() async throws {
    let upstream = StubProxyUpstream()
    let body = jsonBody(["id": "chatcmpl-4", "model": "deepseek-flash", "choices": [Any]()])
    upstream.setAnswer(stubAnswer(chunks: [body]))
    let collector = ProxyUsageCollector()

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      let response = try await RawProxyClient.exchange(
        port: port, request: postRequest("/models", body: Data("{}".utf8)))
      // The client still gets exactly what upstream sent, usage or no usage.
      #expect(response.statusCode == 200)
      #expect(response.body == body)
    }

    #expect(collector.recorded.isEmpty)
  }

  @Test("an upstream that never answers becomes a 502 and records nothing")
  func upstreamFailureIsBadGateway() async throws {
    let upstream = StubProxyUpstream()
    var answer = StubProxyUpstream.Answer()
    answer.failure = StubUpstreamFailure()
    upstream.setAnswer(answer)
    let collector = ProxyUsageCollector()

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      let response = try await RawProxyClient.exchange(
        port: port, request: postRequest("/chat/completions", body: Data("{}".utf8)))

      #expect(response.statusCode == 502)
      #expect(response.headers["content-type"] == "application/json")
      #expect(response.headers["connection"] == "close")
      let text = String(decoding: response.body, as: UTF8.self)
      #expect(text.contains("api.deepseek.com"))
    }

    #expect(collector.recorded.isEmpty)
  }

  @Test("what the upstream sees is the client's request minus the headers of its own hop")
  func forwardedRequestKeepsWhatMatters() async throws {
    let upstream = StubProxyUpstream()
    upstream.setAnswer(stubAnswer(chunks: [completionBody()]))
    let collector = ProxyUsageCollector()
    let body = Data(#"{"model":"deepseek-flash"}"#.utf8)

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      let response = try await RawProxyClient.exchange(
        port: port,
        request: postRequest(
          "/chat/completions?trace=1",
          headers: [
            "Authorization: Bearer sk-test-proxy",
            "Connection: keep-alive",
            "Keep-Alive: timeout=5",
            "Proxy-Connection: keep-alive",
            "Accept-Encoding: gzip, deflate",
          ],
          body: body))
      #expect(response.statusCode == 200)

      // A `GET` declares no body at all; the upstream still sees the length the proxy computed.
      let models = try await RawProxyClient.exchange(port: port, request: getRequest("/models"))
      #expect(models.statusCode == 200)
    }

    let forwarded = try #require(upstream.requests.first)
    #expect(upstream.requests.count == 2)
    #expect(forwarded.method == "POST")
    #expect(forwarded.path == "/chat/completions?trace=1")
    #expect(forwarded.body == body)
    // The client's own headers travel: the Authorization value is what the upstream authorises with,
    // and the proxy never reads, logs or stores it.
    #expect(
      forwarded.headers.contains(
        ProxyHeader(name: "Authorization", value: "Bearer sk-test-proxy")))
    #expect(
      forwarded.headers.contains(ProxyHeader(name: "Content-Type", value: "application/json")))
    // The body it actually sends is the one this Content-Length describes, not a client's guess.
    #expect(
      forwarded.headers.contains(ProxyHeader(name: "Content-Length", value: "\(body.count)")))
    let names = forwarded.headers.map { $0.name.lowercased() }
    #expect(!names.contains("host"))
    #expect(!names.contains("connection"))
    #expect(!names.contains("keep-alive"))
    #expect(!names.contains("proxy-connection"))
    #expect(!names.contains("accept-encoding"))

    let get = try #require(upstream.requests.last)
    #expect(get.method == "GET")
    #expect(get.path == "/models")
    #expect(get.body.isEmpty)
    #expect(get.headers.contains(ProxyHeader(name: "Content-Length", value: "0")))
  }

  @Test("a request the proxy cannot forward is refused before it reaches the upstream")
  func unsupportedRequestsAreRefused() async throws {
    let upstream = StubProxyUpstream()
    upstream.setAnswer(stubAnswer(chunks: [completionBody()]))
    let collector = ProxyUsageCollector()

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      // A body the client is still streaming: the proxy would have to read it to know how much there
      // is, and one sentence is a better answer than a guess at the length.
      let chunked = try await RawProxyClient.exchange(
        port: port,
        request: Data(
          "POST /chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            .utf8))
      #expect(chunked.statusCode == 501)
      #expect(String(decoding: chunked.body, as: UTF8.self).contains("Content-Length"))

      // An absolute-form target would let the client choose the host; this proxy has one.
      let absolute = try await RawProxyClient.exchange(
        port: port,
        request: Data("GET https://example.com/v1/models HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
      #expect(absolute.statusCode == 400)
      #expect(String(decoding: absolute.body, as: UTF8.self).contains("api.deepseek.com"))

      let wrongMethod = try await RawProxyClient.exchange(
        port: port, request: Data("DELETE /chat/completions HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
      #expect(wrongMethod.statusCode == 405)
      #expect(wrongMethod.headers["allow"] == "GET, POST")

      let noPath = try await RawProxyClient.exchange(
        port: port, request: Data("GET * HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
      #expect(noPath.statusCode == 400)
    }

    #expect(upstream.requests.isEmpty)
    #expect(collector.recorded.isEmpty)
  }

  @Test("a second listener on a port that is taken reports it instead of crashing")
  func portInUseIsAValue() async throws {
    let first = UsageProxyServer(upstream: StubProxyUpstream(), record: { _ in })
    _ = await first.start(port: 0)
    let port = try #require(await first.boundPort)
    defer { Task { await first.stop() } }

    let second = UsageProxyServer(upstream: StubProxyUpstream(), record: { _ in })
    let outcome = await second.start(port: port)

    guard case .notListening(let reason) = outcome else {
      Issue.record("a second listener bound port \(port) as well: \(outcome)")
      return
    }
    #expect(reason == "port \(port) is already in use")
    // The refused start left nothing behind, and the first listener is untouched.
    let secondPort = await second.boundPort
    let firstPort = await first.boundPort
    #expect(secondPort == nil)
    #expect(firstPort == port)
    await second.stop()
    await first.stop()
  }

  @Test("an upstream that fails mid-body is a 502, and a truncated stream records nothing")
  func upstreamFailureMidBody() async throws {
    // A non-streaming body that stops halfway: nothing has reached the client yet, so the proxy can
    // still answer the truth.
    let upstream = StubProxyUpstream()
    var answer = StubProxyUpstream.Answer()
    answer.body = ProxyUpstreamBody(
      chunks: AsyncThrowingStream { continuation in
        continuation.yield(Data(#"{"id":"chatcmpl-5","model":"deepseek-flash",""#.utf8))
        continuation.finish(throwing: StubUpstreamFailure())
      },
      cancel: {})
    upstream.setAnswer(answer)
    let jsonCollector = ProxyUsageCollector()

    try await withServer(upstream: upstream, recorder: jsonCollector) { _, port in
      let response = try await RawProxyClient.exchange(
        port: port, request: postRequest("/chat/completions", body: Data("{}".utf8)))
      #expect(response.statusCode == 502)
    }
    #expect(jsonCollector.recorded.isEmpty)

    // A streamed body that stops right after its usage chunk: the client already holds a truncated
    // response, and usage rides a response's own last line — so a body that never finished is not a
    // measurement, even though the counters arrived.
    let streamed = StubProxyUpstream()
    var truncated = StubProxyUpstream.Answer()
    truncated.headers = [eventStreamHeader]
    truncated.body = ProxyUpstreamBody(
      chunks: AsyncThrowingStream { continuation in
        continuation.yield(streamedCompletionEvents()[2])
        continuation.finish(throwing: StubUpstreamFailure())
      },
      cancel: {})
    streamed.setAnswer(truncated)
    let streamCollector = ProxyUsageCollector()

    try await withServer(upstream: streamed, recorder: streamCollector) { _, port in
      let received = ReceivedBytes()
      var truncation: (any Error)?
      do {
        _ = try await RawProxyClient.exchange(
          port: port, request: postRequest("/chat/completions", body: Data("{}".utf8)),
          onChunk: { received.append($0) })
      } catch {
        truncation = error
      }
      // The head and the usage line did reach the client, and the body never ended: a client reading
      // a truncated chunked response fails, which is what the truncation is.
      #expect(received.text.contains("HTTP/1.1 200"))
      #expect(received.text.contains("\"usage\""))
      #expect(truncation is RawHTTPError)
    }
    #expect(streamCollector.recorded.isEmpty)
  }

  @Test("a client that goes away stops the upstream read and records nothing")
  func clientGoingAwayCancelsTheUpstream() async throws {
    let (chunks, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
    let body = CancelRecordedBody()
    let upstream = StubProxyUpstream()
    var answer = StubProxyUpstream.Answer()
    answer.headers = [eventStreamHeader]
    answer.body = body.wrap(chunks)
    upstream.setAnswer(answer)
    let collector = ProxyUsageCollector()
    let events = streamedCompletionEvents()

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      // The client takes the head, then goes away without ever reading the body.
      let exchange = Task {
        try? await RawProxyClient.exchange(
          port: port,
          request: postRequest("/chat/completions", body: Data("{}".utf8)),
          closeAfter: Data("Transfer-Encoding: chunked".utf8))
      }
      feed.yield(events[0])
      await exchange.value

      // The proxy's next write lands on a closed socket, so it stops reading upstream with it.
      feed.yield(events[1])
      feed.yield(events[2])
      feed.finish()
      await waitUntil("the upstream read to be cancelled") { body.cancelCount == 1 }
    }

    // The usage line was in the body, and it is still not recorded: a client that went away is a
    // request that never completed.
    #expect(collector.recorded.isEmpty)
  }

  @Test("a body is delivered one completed line at a time, and bounded when there is none")
  func bodyPumpCoalescesIntoLines() async throws {
    // Two SSE events, byte by byte, exactly as `URLSession` hands them over.
    let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
      for byte in Array("data: one\n\ndata: two\n".utf8) { continuation.yield(byte) }
      continuation.finish()
    }

    var chunks: [Data] = []
    for try await chunk in URLSessionProxyUpstream.body(of: bytes).chunks { chunks.append(chunk) }

    // A flush per line, which is the unit an SSE client acts on: nothing waits for the next event.
    #expect(
      chunks == [Data("data: one\n".utf8), Data("\n".utf8), Data("data: two\n".utf8)])
    #expect(chunks.reduce(Data(), +) == Data("data: one\n\ndata: two\n".utf8))
  }

  @Test("a body with no line break is delivered in bounded chunks")
  func bodyPumpBoundsChunks() async throws {
    let count = 16 * 1024 * 2 + 7
    let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
      for _ in 0..<count { continuation.yield(UInt8(ascii: "x")) }
      continuation.finish()
    }

    var sizes: [Int] = []
    for try await chunk in URLSessionProxyUpstream.body(of: bytes).chunks {
      sizes.append(chunk.count)
    }

    // A long completion is never held whole, and the bytes still add up to exactly what arrived.
    #expect(sizes == [16 * 1024, 16 * 1024, 7])
  }

  @Test("a body that failed mid-stream delivers what arrived, then throws")
  func bodyPumpPropagatesFailure() async throws {
    let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
      for byte in Array("data: one\n".utf8) { continuation.yield(byte) }
      continuation.finish(throwing: StubUpstreamFailure())
    }

    var chunks: [Data] = []
    var failure: (any Error)?
    do {
      for try await chunk in URLSessionProxyUpstream.body(of: bytes).chunks { chunks.append(chunk) }
    } catch {
      failure = error
    }

    // What arrived is a real prefix of the body, and the error is what tells the server the rest will
    // never come — which is why a truncated response records nothing.
    #expect(chunks == [Data("data: one\n".utf8)])
    #expect(failure != nil)
  }

  @Test("a URLSession request reaches the real listener and comes back")
  func urlSessionThroughTheListener() async throws {
    let upstream = StubProxyUpstream()
    let expected = completionBody()
    upstream.setAnswer(stubAnswer(chunks: [expected]))
    let collector = ProxyUsageCollector()

    try await withServer(upstream: upstream, recorder: collector) { _, port in
      let url = try #require(URL(string: "http://127.0.0.1:\(port)/chat/completions"))
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.httpBody = Data(#"{"model":"deepseek-flash"}"#.utf8)
      request.setValue("Bearer sk-test-proxy", forHTTPHeaderField: "Authorization")

      let (data, response) = try await URLSession.shared.data(for: request)

      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      #expect(data == expected)
    }

    let forwarded = try #require(upstream.requests.first)
    #expect(
      forwarded.headers.contains(
        ProxyHeader(name: "Authorization", value: "Bearer sk-test-proxy")))
    #expect(collector.recorded.count == 1)
  }
}

// MARK: - The ledger

/// What one proxied response leaves in the ledger: one priced row, deduplicated by response id.
@Suite("Usage proxy ledger")
struct UsageProxyLedgerTests {
  /// A fixed instant on a UTC day, so the re-read metrics are about the row rather than about the
  /// machine's time zone.
  static let instant = Date(timeIntervalSince1970: 1_790_000_000)

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  /// One response's usage, as the reader would hand it over.
  static func proxyUsage(responseID: String? = "chatcmpl-9", at instant: Date? = nil) -> ProxyUsage
  {
    ProxyUsage(
      responseID: responseID,
      model: "deepseek-flash",
      usage: TokenUsage(
        promptTokens: 100, completionTokens: 20, cacheHitTokens: 80, cacheMissTokens: 20,
        reasoningTokens: 5),
      recordedAt: instant ?? Self.instant)
  }

  /// A UTC window that covers exactly the instant the rows are recorded at.
  static var window: (since: Date, until: Date) {
    (instant.addingTimeInterval(-3_600), instant.addingTimeInterval(3_600))
  }

  @Test("a proxied response lands one priced row, and the same response id never lands twice")
  func recordInsertsOnePricedRow() async throws {
    let ledgerURL = temporaryLedgerURL()
    let table = try PriceTableLoader().loadBundled()
    let engine = CostEngine(table: table)
    // `makeSource: nil` is the shipping "importing is not configured here" case: this test is about
    // the proxy's own row, which the costing sites in the same engine every other row is priced with.
    let ledger = LocalUsageLedger(
      ledgerURL: ledgerURL, priceTable: table, makeSource: nil, costing: engine)
    let usage = Self.proxyUsage()
    let expected = engine.cost(model: usage.model, usage: usage.usage, at: usage.recordedAt)
    #expect(expected > 0)

    let first = await ledger.record(usage, now: Self.instant, calendar: Self.calendar)

    #expect(first.disposition == .recorded)
    // The metrics come back with the call, so the menu bar does not wait for the next import tick.
    // The ledger stores money as whole micro-USD, so the stored amount is the engine's cost at that
    // precision rather than bit-for-bit equal to it.
    let storedSpend = try #require(first.metrics?.todaySpendUSD)
    #expect(abs(expected - storedSpend) < decimal("0.000001"))
    #expect(first.analytics?.windows.first?.requestCount == 1)

    let second = await ledger.record(Self.proxyUsage(), now: Self.instant, calendar: Self.calendar)
    #expect(second.disposition == .duplicate)

    let store = try LedgerStore(url: ledgerURL)
    let window = try store.usageWindow(
      since: Self.window.since, until: Self.window.until, provider: .deepseek)
    #expect(window.summary.requestCount == 1)
    #expect(window.summary.spendUSD == storedSpend)
    #expect(window.summary.promptTokens == 100)
    #expect(window.summary.cacheReadTokens == 80)
    #expect(window.summary.outputTokens == 15)
    #expect(window.summary.reasoningTokens == 5)

    // `source` is what tells a proxied row apart from an imported one, and the CSV the ledger writes
    // for inspection is where a test can read the stored row back.
    let csvURL = ledgerURL.deletingLastPathComponent().appending(path: "export.csv")
    try store.exportCSV(to: csvURL)
    let csv = try String(contentsOf: csvURL, encoding: .utf8)
    #expect(csv.contains("proxy,deepseek,deepseek-flash,"))
  }

  @Test("a response with no id is still deduplicated, on its instant, model and counters")
  func responsesWithoutAnIDAreDeduplicated() async throws {
    let ledgerURL = temporaryLedgerURL()
    let table = try PriceTableLoader().loadBundled()
    let ledger = LocalUsageLedger(
      ledgerURL: ledgerURL, priceTable: table, makeSource: nil,
      costing: CostEngine(table: table))

    let first = await ledger.record(
      Self.proxyUsage(responseID: nil), now: Self.instant, calendar: Self.calendar)
    let second = await ledger.record(
      Self.proxyUsage(responseID: nil), now: Self.instant, calendar: Self.calendar)
    let otherInstant = Self.instant.addingTimeInterval(1)
    let later = await ledger.record(
      Self.proxyUsage(responseID: nil, at: otherInstant), now: Self.instant, calendar: Self.calendar
    )

    #expect(first.disposition == .recorded)
    #expect(second.disposition == .duplicate)
    // A different response is a different row even without an id.
    #expect(later.disposition == .recorded)
    let window = try LedgerStore(url: ledgerURL).usageWindow(
      since: Self.window.since, until: Self.window.until)
    #expect(window.summary.requestCount == 2)
  }

  @Test("with no price table the row is skipped rather than stored at zero")
  func withoutAPriceTableNothingIsRecorded() async throws {
    let ledgerURL = temporaryLedgerURL()
    let ledger = LocalUsageLedger(
      ledgerURL: ledgerURL, priceTable: .unavailable, makeSource: nil, costing: nil)

    let outcome = await ledger.record(Self.proxyUsage(), now: Self.instant, calendar: Self.calendar)

    #expect(outcome.disposition == .skippedNoPriceTable)
    #expect(outcome.metrics == nil)
    // Nothing was written: no row priced at nothing, and nothing to re-price later.
    let window = try LedgerStore(url: ledgerURL).usageWindow(
      since: Self.window.since, until: Self.window.until)
    #expect(window.summary.requestCount == 0)
  }
}

// MARK: - Settings and the model

/// The setting, its caption and the listener the model starts and stops. Every socket here is stubbed:
/// the real listener is covered by the server suite above.
@Suite("Usage proxy settings", .serialized)
@MainActor
struct UsageProxySettingsTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.proxy"
  private static let settingsKey = "io.github.genoma.deeptally.settings"

  @Test("the proxy is off by default, on 8787, and a nonsense port is pulled into range")
  func defaultsAndClamping() {
    #expect(AppSettings.default.proxyEnabled == false)
    #expect(AppSettings.default.proxyPort == 8787)
    #expect(AppSettings.proxyPortRange == 1024...65_535)

    #expect(AppSettings(proxyPort: 1).validated().proxyPort == 1024)
    #expect(AppSettings(proxyPort: -1).validated().proxyPort == 1024)
    #expect(AppSettings(proxyPort: 999_999).validated().proxyPort == 65_535)
    // A port already inside the range is kept exactly.
    #expect(AppSettings(proxyPort: 9123).validated().proxyPort == 9123)
  }

  @Test("the proxy settings round-trip, and a nonsense field resets only itself")
  func roundTripAndTolerantDecoding() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let store = SettingsStore(defaults: defaults)
      var settings = AppSettings.default
      settings.proxyEnabled = true
      settings.proxyPort = 9123
      store.save(settings)
      #expect(store.load() == settings)

      // A hand-edited blob: the port is the wrong type, and everything else in it survives.
      defaults.set(
        Data(#"{"proxyEnabled":true,"proxyPort":"soon","showSecondaryMetric":true}"#.utf8),
        forKey: Self.settingsKey)
      let loaded = store.load()
      #expect(loaded.proxyEnabled)
      #expect(loaded.proxyPort == 8787)
      #expect(loaded.showSecondaryMetric)

      // A port that is a number but not a port is clamped, not discarded.
      defaults.set(Data(#"{"proxyEnabled":true,"proxyPort":1}"#.utf8), forKey: Self.settingsKey)
      let clamped = store.load()
      #expect(clamped.proxyEnabled)
      #expect(clamped.proxyPort == AppSettings.proxyPortRange.lowerBound)
    }
  }

  @Test("the toggle starts the listener, the caption carries the bound port, and off stops it")
  func toggleStartsAndStops() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      var settings = AppSettings.default
      settings.proxyEnabled = true
      let proxy = StubUsageProxy()
      let fixture = makeFixture(defaults: defaults, settings: settings, usageProxy: proxy)

      fixture.model.start(observingSystemEvents: false)
      await waitUntil("the listener to start") { proxy.startedPorts == [8787] }
      #expect(fixture.model.proxyBoundPort == 8787)
      #expect(fixture.model.proxyProblem == nil)
      #expect(
        fixture.model.proxyCaption
          == "Point clients at http://127.0.0.1:8787 — usage is recorded from each API response.")
      #expect(!fixture.model.banners.contains { $0.id == "usage-proxy" })

      // A different port on the same toggle restarts the listener on it.
      fixture.model.settings.proxyPort = 9001
      await waitUntil("the listener on the new port") { proxy.startedPorts == [8787, 9001] }
      #expect(fixture.model.proxyBoundPort == 9001)
      #expect(fixture.model.proxyCaption?.contains("http://127.0.0.1:9001") == true)

      fixture.model.settings.proxyEnabled = false
      await waitUntil("the listener to stop") { proxy.stopCount == 1 }
      #expect(fixture.model.proxyBoundPort == nil)
      #expect(fixture.model.proxyCaption == nil)
      #expect(fixture.model.proxyProblem == nil)
      #expect(SettingsStore(defaults: defaults).load().proxyEnabled == false)
    }
  }

  @Test("a port that is taken is one line, and the balance keeps working")
  func bindFailureIsOneLine() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      var settings = AppSettings.default
      settings.proxyEnabled = true
      let proxy = StubUsageProxy()
      proxy.outcome = .notListening(reason: "port 8787 is already in use")
      let fixture = makeFixture(
        defaults: defaults, outcome: .balance(usdBalance("12.34")), settings: settings,
        usageProxy: proxy)

      fixture.model.start(observingSystemEvents: false)
      await waitUntil("the bind failure") { fixture.model.proxyProblem != nil }

      #expect(
        fixture.model.proxyProblem
          == "The local usage proxy could not start: port 8787 is already in use.")
      #expect(fixture.model.proxyBoundPort == nil)
      // No address is claimed for a listener that is not answering.
      #expect(fixture.model.proxyCaption == nil)
      let banner = try #require(fixture.model.banners.first { $0.id == "usage-proxy" })
      #expect(banner.kind == .warning)
      #expect(banner.message == fixture.model.proxyProblem)

      // The rest of the app is untouched: the balance still fetches and renders.
      await settleRefresh(fixture.model)
      #expect(fixture.model.balanceState?.amountText == "$12.34")
      #expect(fixture.fetcher.callCount == 1)
    }
  }
}
