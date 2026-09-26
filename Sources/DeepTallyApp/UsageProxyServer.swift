// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Network
import Synchronization

/// Records one forwarded response's usage in the ledger.
///
/// `@Sendable` and `async` because the server runs off the main actor: the app points this at
/// ``LocalUsageLedger``, a test at a collector. It is called at most once per response, and only for
/// a response whose body finished and carried usage.
typealias ProxyUsageRecorder = @Sendable (ProxyUsage) async -> Void

/// What one `start` attempt did.
enum UsageProxyStart: Sendable, Equatable {
  /// Bound and accepting. `port` is the port it actually bound, which differs from the requested one
  /// when 0 was requested.
  case listening(port: Int)
  /// The listener could not bind — the port is taken, or macOS refused. `reason` is a short phrase,
  /// never an error dump; the model turns it into the one line the user sees.
  case notListening(reason: String)
}

/// The loopback listener as ``AppModel`` drives it.
///
/// A protocol so the model's toggle, its caption and its bind-failure line are provable without a
/// socket: the shipping implementation is ``UsageProxyServer``, and a test injects a stub. Both
/// methods are `async` because binding and cancelling a listener are.
protocol UsageProxyServing: Sendable {
  /// Starts listening on `port` — `0` means an ephemeral one — replacing whatever was running.
  func start(port: Int) async -> UsageProxyStart
  /// Cancels the listener and every connection it accepted. Safe to call when nothing is running.
  func stop() async
}

/// The opt-in loopback usage proxy.
///
/// It binds `127.0.0.1` only and forwards to `https://api.deepseek.com` only. A request travels as it
/// arrived — the body is never rewritten, because DeepSeek sends its `usage` object even without
/// `stream_options.include_usage` — and the response goes back in the same order, with the same
/// status and the same bytes. The one thing the proxy does with a response is read its usage, and
/// only the counters, the model and the response id survive that read: no body, no header and no
/// `Authorization` value is ever logged, stored or copied into an error message (AGENTS.md §5).
///
/// All mutable state lives on this actor, and every connection's own state lives on the `async` stack
/// of the task that serves it, so nothing on this path needs a lock or an `@unchecked Sendable`.
actor UsageProxyServer: UsageProxyServing {
  private let upstream: any ProxyUpstream
  private let record: ProxyUsageRecorder
  /// When a response's usage is dated. Injectable so a test can pin the instant.
  private let now: @Sendable () -> Date
  /// The one queue the listener and every accepted connection run on. Network.framework delivers its
  /// events there; each connection hops off it into a `Task` immediately, so nothing but framework
  /// callbacks run on it.
  private let queue: DispatchQueue
  /// How long one read may take before the client is refused. A local client that connects and then
  /// stops sending would otherwise hold a connection slot forever (test seam: the shipping default is
  /// generous, and the tests pass something short).
  private let readTimeout: TimeInterval
  /// The most connections served at once. Beyond this the proxy answers 503 rather than accumulating
  /// tasks; a chat client needs a handful, and the rest is a client that is misbehaving.
  private let maximumConnections: Int

  private var listener: NWListener?
  /// What `start` was asked for, so a second start with the same port does not rebind.
  private var requestedPort: Int?
  /// The connections accepted and not yet finished, so ``stop()`` can cancel the ones in flight.
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  /// The port the listener actually bound, or `nil` while it is not listening.
  private(set) var boundPort: Int?

  init(
    upstream: any ProxyUpstream,
    record: @escaping ProxyUsageRecorder,
    now: @escaping @Sendable () -> Date = { Date() },
    queue: DispatchQueue = DispatchQueue(label: "io.github.genoma.deeptally.proxy"),
    readTimeout: TimeInterval = 30,
    maximumConnections: Int = 32
  ) {
    self.upstream = upstream
    self.record = record
    self.now = now
    self.queue = queue
    self.readTimeout = readTimeout
    self.maximumConnections = maximumConnections
  }

  // MARK: - Lifecycle

  /// Binds and starts listening, replacing whatever was running before.
  ///
  /// The result is a value, never a throw and never a crash: a port that is already in use is the
  /// expected failure of an opt-in listener, and the model shows it as one calm line.
  func start(port: Int) async -> UsageProxyStart {
    if requestedPort == port, let boundPort { return .listening(port: boundPort) }
    await stop()
    guard let requested = Self.networkPort(port) else {
      return .notListening(reason: "\(port) is not a port number")
    }

    let parameters = NWParameters.tcp
    // Loopback only: this listener must never be reachable from another machine (AGENTS.md §1).
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requested)
    // A restart on the same port right after a connection ended would otherwise trip over the
    // previous socket's TIME_WAIT, which reads to the user as "port already in use".
    parameters.allowLocalEndpointReuse = true

    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      return .notListening(reason: Self.describe(error, port: port))
    }

    let bound = OneShotResume<UsageProxyStart>()
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        bound.resolve(.listening(port: Int(listener.port?.rawValue ?? requested.rawValue)))
      case .failed(let error), .waiting(let error):
        // A waiting listener is not accepting either, and waiting forever for a port that is taken
        // would leave `start` — and the settings caption — hanging instead of saying so.
        bound.resolve(.notListening(reason: Self.describe(error, port: port)))
      case .cancelled:
        bound.resolve(.notListening(reason: "the listener stopped before it could bind"))
      case .setup:
        break
      @unknown default:
        bound.resolve(.notListening(reason: "binding port \(port) failed"))
      }
    }
    let handler = ProxyConnectionHandler(
      upstream: upstream, record: record, now: now, readTimeout: readTimeout)
    listener.newConnectionHandler = { [queue, weak self] connection in
      Task {
        if let self, await self.track(connection) {
          await handler.serve(connection, on: queue)
          await self.untrack(connection)
        } else {
          await handler.refuseBusy(connection, on: queue)
        }
      }
    }
    self.listener = listener
    requestedPort = port
    listener.start(queue: queue)

    let outcome = await bound.wait()
    guard case .listening(let boundPort) = outcome, listener === self.listener else {
      // The bind failed, or `stop()` ran while this start was waiting for it. Either way this listener
      // is not the one in service, so it goes away without touching the state the caller reads.
      listener.cancel()
      return outcome
    }
    self.boundPort = boundPort
    return outcome
  }

  /// Cancels the listener, releases the port and cancels every connection still in flight.
  func stop() async {
    listener?.cancel()
    listener = nil
    requestedPort = nil
    boundPort = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
  }

  /// Remembers an accepted connection so ``stop()`` can cancel it.
  /// Tracks one accepted connection, or answers `false` when the proxy is already at its limit.
  private func track(_ connection: NWConnection) -> Bool {
    guard connections.count < maximumConnections else { return false }
    connections[ObjectIdentifier(connection)] = connection
    return true
  }

  private func untrack(_ connection: NWConnection) {
    connections[ObjectIdentifier(connection)] = nil
  }

  /// The port for a listener, or `nil` when `port` is not in `0...65535`. `0` is a real request — an
  /// ephemeral port, which is what the tests ask for and what ``boundPort`` then reports.
  private static func networkPort(_ port: Int) -> NWEndpoint.Port? {
    guard (0...Int(UInt16.max)).contains(port) else { return nil }
    return NWEndpoint.Port(rawValue: UInt16(port))
  }

  /// One phrase for a listener error, short enough to sit on the end of the model's sentence. Never
  /// a description of an `NWError` as a whole: it would read like a dump, and nothing here carries a
  /// header value.
  private static func describe(_ error: any Error, port: Int) -> String {
    guard let failure = error as? NWError else { return "the port could not be bound" }
    switch failure {
    case .posix(let code) where code == .EADDRINUSE:
      return "port \(port) is already in use"
    case .posix(let code) where code == .EACCES:
      return "macOS refused permission to bind port \(port)"
    case .posix(let code):
      return "binding port \(port) failed (\(code.rawValue))"
    default:
      return "binding port \(port) failed"
    }
  }
}

/// Resumes one continuation exactly once, whichever side gets there first.
///
/// The listener reports its bind result on its own queue while ``UsageProxyServer/start(port:)`` waits
/// on the caller's task, so the two genuinely race. The lock makes the handshake order-independent,
/// and it is the only shared mutable state on this path.
private final class OneShotResume<Value: Sendable>: Sendable {
  private struct Pending {
    var value: Value?
    var continuation: CheckedContinuation<Value, Never>?
  }

  private let pending = Mutex(Pending())

  /// Records the outcome; resumes a waiting ``wait()``, or leaves the value for one that comes later.
  func resolve(_ value: Value) {
    let waiting = pending.withLock { state -> CheckedContinuation<Value, Never>? in
      guard state.value == nil else { return nil }
      state.value = value
      defer { state.continuation = nil }
      return state.continuation
    }
    waiting?.resume(returning: value)
  }

  /// Waits for ``resolve(_:)``, or returns at once when it already happened.
  func wait() async -> Value {
    await withCheckedContinuation { continuation in
      let resolved = pending.withLock { state -> Value? in
        guard state.value == nil else { return state.value }
        state.continuation = continuation
        return nil
      }
      if let resolved { continuation.resume(returning: resolved) }
    }
  }
}

// MARK: - One connection

/// Serves one accepted connection: read one request, forward it, write the response back.
///
/// A `struct` with no mutable state: everything a connection owns lives on the `async` stack of the
/// task that serves it, which is what keeps this path free of locks and `@unchecked` conformances.
private struct ProxyConnectionHandler: Sendable {
  let upstream: any ProxyUpstream
  let record: ProxyUsageRecorder
  let now: @Sendable () -> Date
  /// How long one read may take before the client is refused (``UsageProxyServer`` owns the policy).
  let readTimeout: TimeInterval

  /// Answers a connection the proxy has no room for, then closes it.
  func refuseBusy(_ connection: NWConnection, on queue: DispatchQueue) async {
    connection.start(queue: queue)
    defer { connection.cancel() }
    try? await Self.write(Self.busy, over: connection)
  }

  /// Serves one connection to completion.
  ///
  /// One request per connection: every response carries `Connection: close`, so there is nothing to
  /// keep alive for and no second request to parse.
  func serve(_ connection: NWConnection, on queue: DispatchQueue) async {
    connection.start(queue: queue)
    defer { connection.cancel() }
    do {
      let request = try await readRequest(from: connection)
      try await forward(request, over: connection)
    } catch let refusal as ProxyRefusal {
      try? await Self.write(refusal, over: connection)
    } catch {
      // The client went away, or the connection failed under the request. There is nobody left to
      // answer, and nothing to record: a request that never completed was never billed.
    }
  }

  // MARK: - Reading

  /// Reads one request: the head, then exactly the `Content-Length` bytes it announced.
  private func readRequest(from connection: NWConnection) async throws -> ProxyUpstreamRequest {
    var buffer = Data()
    var headByteCount: Int?
    while headByteCount == nil {
      if buffer.count > Self.maximumHeadBytes {
        throw ProxyRefusal(status: 431, sentence: Self.headTooLarge)
      }
      guard let chunk = try await Self.receive(from: connection, within: readTimeout) else {
        throw ProxyConnectionEnded()
      }
      buffer.append(chunk)
      if let terminator = buffer.range(of: Self.headTerminator) {
        headByteCount = buffer.distance(from: buffer.startIndex, to: terminator.upperBound)
      }
    }
    guard let headByteCount else { throw ProxyConnectionEnded() }

    let head = try Self.parseHead(Data(buffer.prefix(headByteCount)))
    try Self.refuseUnsupported(head)
    if head.expectsContinue {
      // The client is holding its body back until it hears this; without it, a client that sent
      // `Expect: 100-continue` and the proxy would wait for each other.
      try await Self.send(
        Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), isComplete: false, over: connection)
    }

    let bodyLength = head.declaredBodyLength ?? 0
    var body = Data(buffer.dropFirst(headByteCount))
    while body.count < bodyLength {
      guard let chunk = try await Self.receive(from: connection, within: readTimeout) else {
        throw ProxyConnectionEnded()
      }
      body.append(chunk)
    }
    // Bytes past `Content-Length` would belong to a request this proxy does not implement; they end
    // with the connection, which closes after the answer.
    let exactBody = Data(body.prefix(bodyLength))
    return ProxyUpstreamRequest(
      method: head.method, path: head.target,
      headers: head.forwardedHeaders(bodyCount: exactBody.count), body: exactBody)
  }

  /// The request line and the headers, or the refusal that answers a head this proxy cannot read.
  private static func parseHead(_ bytes: Data) throws -> ProxyRequestHead {
    guard let text = String(bytes: bytes, encoding: .utf8) else {
      throw ProxyRefusal(status: 400, sentence: "The request head is not UTF-8 text.")
    }
    var lines = text.components(separatedBy: "\r\n")
    // The head ends with the blank line that terminated it; whatever followed is already the body.
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    guard let requestLine = lines.first else {
      throw ProxyRefusal(status: 400, sentence: "The request has no request line.")
    }
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
      throw ProxyRefusal(
        status: 400, sentence: "The request line is not a method, a target and a version.")
    }

    var headers: [ProxyHeader] = []
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else {
        throw ProxyRefusal(status: 400, sentence: "A request header line has no colon.")
      }
      let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      // A bare line break inside a header is how a request smuggles a second one past a proxy that
      // splits by lines; it never reaches the upstream from here.
      guard !name.isEmpty, !name.contains("\r"), !name.contains("\n"),
        !value.contains("\r"), !value.contains("\n")
      else {
        throw ProxyRefusal(status: 400, sentence: "A request header contains a bare line break.")
      }
      headers.append(ProxyHeader(name: name, value: value))
    }
    return ProxyRequestHead(
      method: String(parts[0]).uppercased(), target: String(parts[1]), headers: headers)
  }

  /// Refuses what this proxy does not forward, before any of the body is read or any of the request
  /// leaves the machine.
  private static func refuseUnsupported(_ head: ProxyRequestHead) throws {
    guard head.method == "GET" || head.method == "POST" else {
      throw ProxyRefusal(
        status: 405, sentence: "The usage proxy forwards GET and POST only.",
        headers: [ProxyHeader(name: "Allow", value: "GET, POST")])
    }
    guard head.target.hasPrefix("/") else {
      throw ProxyRefusal(
        status: 400,
        sentence:
          "This proxy forwards to api.deepseek.com only: send an origin-form path such as "
          + "/chat/completions, not an absolute URL.")
    }
    guard head.header("transfer-encoding") == nil else {
      throw ProxyRefusal(
        status: 501, sentence: "Chunked request bodies are not supported; send a Content-Length.")
    }
    guard let bodyLength = head.declaredBodyLength else {
      throw ProxyRefusal(status: 400, sentence: "The Content-Length header is not a byte count.")
    }
    guard bodyLength <= maximumBodyBytes else {
      throw ProxyRefusal(
        status: 413,
        sentence: "The request body is larger than this proxy reads (\(maximumBodyBytes) bytes).")
    }
  }

  // MARK: - Forwarding

  /// Sends the request upstream and writes what came back.
  private func forward(_ request: ProxyUpstreamRequest, over connection: NWConnection) async throws
  {
    let response: ProxyUpstreamResponse
    do {
      response = try await upstream.send(request)
    } catch ProxyUpstreamError.unusableURL {
      // Nothing has been written to the client yet, so the reason it failed is still available and
      // worth saying: a target the proxy cannot turn into a path is a 400, not an upstream outage.
      try await Self.write(Self.invalidTarget, over: connection)
      return
    } catch {
      // Nothing has been written to the client yet, so the truth is still available: one 502, and no
      // record, because a request that never completed was never billed.
      try await Self.write(Self.upstreamFailure, over: connection)
      return
    }
    if Self.isEventStream(response.header(named: "content-type")) {
      try await stream(response, over: connection)
    } else {
      try await buffer(response, over: connection)
    }
  }

  /// The one answer for a proxy that is already serving as many connections as it will.
  private static let busy = ProxyRefusal(
    status: 503, sentence: "The local proxy is busy; try again in a moment.")

  /// The one answer for an upstream that never completed, or completed only part of its body.
  private static let upstreamFailure = ProxyRefusal(
    status: 502, sentence: "The upstream request to api.deepseek.com failed.")

  /// A target Foundation cannot turn into a path is the client's mistake, not the upstream's.
  private static let invalidTarget = ProxyRefusal(
    status: 400, sentence: "The request target is not a valid path for api.deepseek.com.")

  /// The one answer for a client that connected and then stopped sending.
  private static let readTimedOut = "The request was not received in time."

  /// A response that is not a stream: read it whole, then write it back with the upstream's status,
  /// its headers and the `Content-Length` of the bytes actually written.
  private func buffer(_ response: ProxyUpstreamResponse, over connection: NWConnection) async throws
  {
    var body = Data()
    do {
      for try await chunk in response.body.chunks { body.append(chunk) }
    } catch {
      // The upstream failed mid-body, and nothing has been written to the client yet — so it can still
      // be told the truth. A truncated body is also no place to read usage from.
      response.body.cancel()
      try await Self.write(Self.upstreamFailure, over: connection)
      return
    }

    var answer = Data(
      Self.responseHead(
        response.statusCode, headers: response.headers, framing: .contentLength(body.count)
      )
      .utf8)
    answer.append(body)
    try await Self.send(answer, isComplete: true, over: connection)
    await recordIfUsage(in: body, contentType: response.header(named: "content-type"))
  }

  /// A `text/event-stream` response: the status and headers go out first, then each chunk as it
  /// arrives, framed as chunked transfer coding so the client can tell where the body ends without
  /// the proxy holding it. The same bytes go to the usage reader, which keeps only the newest
  /// usage-bearing line — the counters, the model and the id, never the content beside them.
  private func stream(_ response: ProxyUpstreamResponse, over connection: NWConnection) async throws
  {
    let head = Self.responseHead(response.statusCode, headers: response.headers, framing: .chunked)
    try await Self.send(Data(head.utf8), isComplete: false, over: connection)

    var tap = ProxyUsageReader.StreamTap()
    do {
      for try await chunk in response.body.chunks where !chunk.isEmpty {
        try await Self.send(Self.chunk(chunk), isComplete: false, over: connection)
        tap.consume(chunk)
      }
      try await Self.send(Self.chunkTerminator, isComplete: true, over: connection)
    } catch {
      // Either the client went away or the upstream failed mid-stream. The response is already
      // truncated at the client and cannot be taken back, and nothing is recorded from it: usage
      // rides the response's own last line, so a body that did not finish is not a measurement.
      response.body.cancel()
      return
    }

    guard let usage = tap.usage(recordedAt: now()) else { return }
    await record(usage)
  }

  /// Reads the usage out of a whole body and hands it to the recorder, once.
  private func recordIfUsage(in body: Data, contentType: String?) async {
    guard
      let usage = ProxyUsageReader.usage(from: body, contentType: contentType, recordedAt: now())
    else { return }
    await record(usage)
  }

  // MARK: - Writing

  /// A response head: the status line, the passthrough headers, the framing and `Connection: close`.
  private static func responseHead(
    _ statusCode: Int, headers: [ProxyHeader], framing: Framing
  ) -> String {
    var text = statusLine(statusCode)
    for header in passthroughHeaders(headers) { text += "\(header.name): \(header.value)\r\n" }
    switch framing {
    case .contentLength(let count): text += "Content-Length: \(count)\r\n"
    case .chunked: text += "Transfer-Encoding: chunked\r\n"
    }
    return text + "Connection: close\r\n\r\n"
  }

  /// How a response body is delimited on this hop. One request per connection, so every response
  /// says `Connection: close` and the framing only has to say where the body ends.
  private enum Framing {
    /// A buffered body: its whole length is known before the first byte goes out.
    case contentLength(Int)
    /// A streamed body: chunked transfer coding, which lets an SSE body keep arriving while it is
    /// produced instead of being held whole first.
    case chunked
  }

  /// The upstream's headers minus the ones that describe the upstream's own connection and framing,
  /// which the proxy answers for itself.
  private static func passthroughHeaders(_ headers: [ProxyHeader]) -> [ProxyHeader] {
    headers.filter { !droppedResponseHeaders.contains($0.name.lowercased()) }
  }

  /// `Content-Length` is recomputed from the bytes the proxy writes, `Transfer-Encoding` describes a
  /// coding the proxy has already undone by reading the body, and the rest belong to the connection
  /// between the proxy and the upstream, which is not the connection the client has.
  private static let droppedResponseHeaders: Set<String> = [
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade", "content-length",
  ]

  /// Writes one response the proxy generated itself: a short JSON body with a single sentence, and
  /// the `Content-Length` of exactly the bytes that go with it.
  private static func write(_ refusal: ProxyRefusal, over connection: NWConnection) async throws {
    let body = jsonError(refusal.sentence)
    var head = statusLine(refusal.status)
    for header in refusal.headers { head += "\(header.name): \(header.value)\r\n" }
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var answer = Data(head.utf8)
    answer.append(body)
    try await Self.send(answer, isComplete: true, over: connection)
  }

  /// The one JSON object a proxy-generated response carries. Serialised rather than assembled by
  /// hand, so a sentence can never break its own body.
  private static func jsonError(_ sentence: String) -> Data {
    let object: [String: Any] = ["error": ["message": sentence, "type": "proxy_error"]]
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  /// One chunk of a `Transfer-Encoding: chunked` body: its length in hexadecimal, the bytes, then the
  /// chunk's own line break.
  private static func chunk(_ bytes: Data) -> Data {
    var framed = Data("\(String(bytes.count, radix: 16))\r\n".utf8)
    framed.append(bytes)
    framed.append(contentsOf: Array("\r\n".utf8))
    return framed
  }

  private static let chunkTerminator = Data("0\r\n\r\n".utf8)

  /// The HTTP clients read is the number; the phrase is here so the status line is well formed. The
  /// phrases below cover the proxy's own answers and the upstream statuses a client is most likely to
  /// end up reading.
  private static func statusLine(_ statusCode: Int) -> String {
    "HTTP/1.1 \(statusCode) \(reasonPhrase(statusCode))\r\n"
  }

  private static func reasonPhrase(_ statusCode: Int) -> String {
    switch statusCode {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 402: return "Payment Required"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 413: return "Payload Too Large"
    case 429: return "Too Many Requests"
    case 431: return "Request Header Fields Too Large"
    case 500: return "Internal Server Error"
    case 501: return "Not Implemented"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    default: return "Upstream Response"
    }
  }

  /// The response is a stream when the upstream says so, with the same tolerant `contains` the usage
  /// reader uses: a gateway may append a charset.
  private static func isEventStream(_ contentType: String?) -> Bool {
    contentType?.lowercased().contains("text/event-stream") ?? false
  }

  // MARK: - The socket

  /// The next bytes from the client, or `nil` when the connection ended; throws when the client has
  /// not sent anything for `seconds`. The loser of the race is cancelled, and the connection is
  /// closed by the caller, which is what unblocks a receive that is still waiting.
  private static func receive(
    from connection: NWConnection, within seconds: TimeInterval
  ) async throws -> Data? {
    try await withThrowingTaskGroup(of: Data?.self) { group in
      group.addTask { try await receive(from: connection) }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw ProxyRefusal(status: 408, sentence: readTimedOut)
      }
      defer { group.cancelAll() }
      return try await group.next() ?? nil
    }
  }

  /// The next bytes from the client, or `nil` when the connection ended.
  private static func receive(from connection: NWConnection) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: maximumReceiveBytes) {
        data, _, _, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else {
          // No bytes and no error means the stream ended: there is nothing more to read.
          continuation.resume(returning: nil)
        }
      }
    }
  }

  /// Writes `data` and waits for the socket to take it. Throws when the connection failed, which is
  /// how a client that went away is noticed.
  private static func send(
    _ data: Data,
    isComplete: Bool,
    over connection: NWConnection
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data, isComplete: isComplete,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        })
    }
  }

  /// The longest request head this reads. A head longer than this is refused rather than buffered
  /// without bound.
  private static let maximumHeadBytes = 64 * 1024
  /// The largest request body this reads. A chat completion has a prompt in it, so this is generous;
  /// it exists so a client cannot make the proxy allocate arbitrary memory.
  private static let maximumBodyBytes = 32 * 1024 * 1024
  private static let maximumReceiveBytes = 64 * 1024
  private static let headTerminator = Data("\r\n\r\n".utf8)

  /// The refusal for a head that never ended.
  private static let headTooLarge = "The request head is larger than this proxy reads."
}

/// One request's head as parsed off the wire.
private struct ProxyRequestHead {
  let method: String
  let target: String
  let headers: [ProxyHeader]

  /// The last value of `name`, matched case-insensitively.
  func header(_ name: String) -> String? {
    let wanted = name.lowercased()
    return headers.last { $0.name.lowercased() == wanted }?.value
  }

  /// The body length the client declared: `0` when it declared none, `nil` when the header is there
  /// but is not a byte count.
  var declaredBodyLength: Int? {
    guard let raw = header("content-length") else { return 0 }
    guard let length = Int(raw), length >= 0 else { return nil }
    return length
  }

  /// `true` when the client holds its body back until it is told to continue.
  var expectsContinue: Bool {
    header("expect")?.lowercased().contains("100-continue") == true
  }

  /// The headers that go upstream: the client's minus the ones that describe this hop, or a body the
  /// proxy has already read, plus the `Content-Length` of the body it is sending.
  ///
  /// `Host` and `Connection` name the hop the client made; `Keep-Alive` and `Proxy-Connection` are
  /// spare spellings of its keep-alive request; `Transfer-Encoding` and `Content-Length` cannot
  /// describe a body that has already been buffered; `Expect` was answered on this hop; and
  /// `Accept-Encoding` is the proxy's decision, because ``URLSessionProxyUpstream`` decodes whatever
  /// encoding it negotiates with the upstream.
  func forwardedHeaders(bodyCount: Int) -> [ProxyHeader] {
    // RFC 7230 §6.1: the client's `Connection` header names tokens that apply to that connection
    // only, and they must not travel on. The static list covers the usual ones even when a client
    // omits the header; this covers anything a client chooses to name.
    var dropped = Self.droppedRequestHeaders
    for header in headers where header.name.lowercased() == "connection" {
      for token in header.value.split(separator: ",") {
        dropped.insert(token.trimmingCharacters(in: .whitespaces).lowercased())
      }
    }
    var forwarded = headers.filter { !dropped.contains($0.name.lowercased()) }
    forwarded.append(ProxyHeader(name: "Content-Length", value: "\(bodyCount)"))
    return forwarded
  }

  private static let droppedRequestHeaders: Set<String> = [
    "host", "connection", "keep-alive", "proxy-connection", "proxy-authorization", "te",
    "trailer", "transfer-encoding", "upgrade", "content-length",
    "expect", "accept-encoding",
  ]
}

/// A response the proxy writes itself instead of forwarding: a status, one sentence, and the headers
/// that answer belongs with.
private struct ProxyRefusal: Error {
  let status: Int
  let sentence: String
  var headers: [ProxyHeader] = []
}

/// The connection ended before a request was complete. Nothing to answer and nothing to record.
private struct ProxyConnectionEnded: Error {}
