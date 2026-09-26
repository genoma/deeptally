// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization

/// One header, as it arrived: name and value, in the order the sender wrote them.
///
/// A list rather than a dictionary because HTTP allows a name to repeat and because the order is the
/// order it travelled in; the server forwards the list it received minus its own hop's headers.
struct ProxyHeader: Sendable, Equatable {
  let name: String
  let value: String
}

/// One request the proxy forwards, as the upstream seam takes it.
struct ProxyUpstreamRequest: Sendable, Equatable {
  /// The client's method, verbatim: `GET` or `POST`, because the server refuses everything else.
  let method: String
  /// The client's request target, which is always an origin-form path with the query still on it.
  /// The upstream URL is `URLSessionProxyUpstream.baseURL` + this, so no other host can be reached.
  let path: String
  /// The client's headers minus the ones that describe its own hop and its own framing, plus the
  /// `Content-Length` the proxy computed from ``body``.
  let headers: [ProxyHeader]
  /// The request body exactly as it arrived. The proxy never rewrites it: DeepSeek sends its `usage`
  /// object even without `stream_options.include_usage`, so there is nothing to add.
  let body: Data
}

/// What the upstream answered: the status, the headers, and the body as it arrives.
///
/// The headers must describe ``body``. An implementation that decodes a `Content-Encoding` — URLSession
/// does, transparently — must not pass the encoding header on, or the client would try to decode bytes
/// that are already decoded. `Content-Length` is never carried: the proxy computes its own from the
/// bytes it writes.
struct ProxyUpstreamResponse: Sendable {
  let statusCode: Int
  let headers: [ProxyHeader]
  let body: ProxyUpstreamBody

  /// The last value of `name`, matched case-insensitively, or `nil`.
  func header(named name: String) -> String? {
    let wanted = name.lowercased()
    return headers.last { $0.name.lowercased() == wanted }?.value
  }
}

/// The body of an upstream response: the chunks in the order they arrived, plus the handle that stops
/// the transfer.
///
/// `cancel` is explicit rather than a stream-termination handler because the caller that notices the
/// client is gone is the one that has to stop reading upstream — and because reaching the pump task
/// through the stream's own termination handler would keep that stream alive through the very task
/// that feeds it.
struct ProxyUpstreamBody: Sendable {
  /// The entity body, chunk by chunk, in the order the upstream sent it. Ends when the upstream ends
  /// it; a thrown error means the body was truncated.
  let chunks: AsyncThrowingStream<Data, any Error>
  /// Stops reading the upstream. Idempotent, and safe to call after the body has ended.
  let cancel: @Sendable () -> Void

  /// A body that is already whole: a non-streaming response, or a test's canned answer.
  init(_ bytes: Data) {
    self.init(chunks: [bytes])
  }

  /// A body delivered as the given chunks, in order. Unlike ``init(_:)`` this preserves a stream's
  /// shape, which is what the tests use to prove a response is forwarded piece by piece.
  init(chunks: [Data]) {
    self.init(
      chunks: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      },
      cancel: {})
  }

  init(chunks: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void) {
    self.chunks = chunks
    self.cancel = cancel
  }
}

/// Where the proxy sends a request and gets the response back.
///
/// A protocol rather than a direct `URLSession` call so that the whole server — parsing, refusals,
/// framing, streaming, recording — is testable against a stub with no network at all. The shipping
/// implementation is ``URLSessionProxyUpstream``.
protocol ProxyUpstream: Sendable {
  /// Sends one request to `api.deepseek.com` and returns the response once its headers are in.
  ///
  /// Throws only when the request never completed: a connection failure, a timeout, a refused
  /// handshake. A 4xx or 5xx *response* is not an error — the proxy forwards it, because the client
  /// asked for it and its body may still be the only thing the client gets to see.
  func send(_ request: ProxyUpstreamRequest) async throws -> ProxyUpstreamResponse
}

/// The shipping upstream: `URLSession` against `https://api.deepseek.com`, the one host the proxy
/// forwards to (AGENTS.md §1).
///
/// `bytes(for:)` rather than `data(for:)`, because an SSE body has to arrive while it is produced
/// instead of being held whole first.
struct URLSessionProxyUpstream: ProxyUpstream {
  /// The only host this proxy talks to. A client cannot reach anything else: the request target must
  /// be an origin-form path, and this base is what any such path is resolved against.
  static let baseURL = URL(string: "https://api.deepseek.com")!

  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func send(_ request: ProxyUpstreamRequest) async throws -> ProxyUpstreamResponse {
    guard let url = URL(string: Self.baseURL.absoluteString + request.path) else {
      throw ProxyUpstreamError.unusableURL
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    var fields: [String: String] = [:]
    for header in request.headers { fields[header.name] = header.value }
    // The proxy asks for an identity body: URLSession decodes whatever encoding it negotiates while
    // leaving the upstream's `Content-Encoding` header in place (measured), and the client must
    // receive bytes and headers that agree with each other.
    fields["Accept-Encoding"] = "identity"
    urlRequest.allHTTPHeaderFields = fields

    let (bytes, response) = try await session.bytes(for: urlRequest)
    guard let http = response as? HTTPURLResponse else { throw ProxyUpstreamError.unusableResponse }
    return ProxyUpstreamResponse(
      statusCode: http.statusCode, headers: Self.headers(of: http), body: Self.body(of: bytes))
  }

  /// The upstream's headers, minus the two that no longer describe the bytes this backend delivers.
  ///
  /// `Content-Length` is recomputed by the proxy from what it writes, and `Content-Encoding` is
  /// dropped because URLSession decodes the body transparently while keeping the header: a gzipped
  /// response comes back decompressed with `Content-Encoding: gzip` still set, so passing it on would
  /// make the client decode plain bytes.
  private static func headers(of response: HTTPURLResponse) -> [ProxyHeader] {
    var headers: [ProxyHeader] = []
    for (key, value) in response.allHeaderFields {
      let name = "\(key)"
      guard !undescribedBodyHeaders.contains(name.lowercased()) else { continue }
      headers.append(ProxyHeader(name: name, value: "\(value)"))
    }
    return headers
  }

  private static let undescribedBodyHeaders: Set<String> = ["content-length", "content-encoding"]

  /// The body as the upstream delivers it, from a byte sequence.
  ///
  /// Generic over the sequence rather than typed to `URLSession.AsyncBytes` so the coalescing — the
  /// part that decides when a client sees an SSE line — is testable without a network.
  ///
  /// Network bytes arrive one at a time, so they are coalesced into the unit an SSE client acts on —
  /// a completed line — and at ``maximumChunkBytes`` otherwise, which keeps a long completion from
  /// being held whole while never delaying a `data:` line behind the next one. The concatenation is
  /// byte-identical to what the upstream sent.
  static func body<Bytes: AsyncSequence & Sendable>(of bytes: Bytes) -> ProxyUpstreamBody
  where Bytes.Element == UInt8, Bytes.Failure == any Error {
    let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let pump = Mutex<Task<Void, Never>?>(nil)
    let body = ProxyUpstreamBody(
      chunks: chunks,
      cancel: { pump.withLock { $0 }?.cancel() })
    let task = Task {
      var buffer = Data()
      do {
        for try await byte in bytes {
          buffer.append(byte)
          if byte == newlineByte || buffer.count >= maximumChunkBytes {
            continuation.yield(buffer)
            buffer.removeAll(keepingCapacity: false)
          }
        }
        if !buffer.isEmpty { continuation.yield(buffer) }
        continuation.finish()
      } catch {
        // Whatever arrived before the failure is a real prefix of the body; the error says the rest
        // will never come, which is what tells the server the response was truncated.
        if !buffer.isEmpty { continuation.yield(buffer) }
        continuation.finish(throwing: error)
      }
    }
    pump.withLock { $0 = task }
    return body
  }

  private static let newlineByte = UInt8(ascii: "\n")
  /// The longest chunk a body is delivered in when the bytes carry no line break to flush on.
  private static let maximumChunkBytes = 16 * 1024
}

/// Why the shipping upstream could not produce a response at all. `URLSession`'s own errors travel
/// beside these: both only ever become the proxy's one 502 sentence, never a message of their own.
enum ProxyUpstreamError: Error {
  case unusableURL
  case unusableResponse
}
