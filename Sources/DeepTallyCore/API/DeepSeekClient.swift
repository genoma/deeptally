// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Minimal DeepSeek HTTP client. Only the balance lives here: DeepSeek exposes no usage or spend
/// endpoint, and this app records no per-call usage of its own.
public struct DeepSeekClient: Sendable {
  public enum APIError: Swift.Error, Sendable, Equatable {
    case missingAPIKey
    case http(status: Int, message: String)
    case decoding(String)
    case transport(String)
  }

  public static let defaultBaseURL = URL(string: "https://api.deepseek.com")!

  private let baseURL: URL
  private let session: URLSession
  private let keyProvider: @Sendable () -> String?

  public init(
    baseURL: URL = DeepSeekClient.defaultBaseURL,
    session: URLSession = .shared,
    keyProvider: @escaping @Sendable () -> String?
  ) {
    self.baseURL = baseURL
    self.session = session
    self.keyProvider = keyProvider
  }

  public func balance() async throws -> Balance {
    try await get("/user/balance")
  }

  // MARK: - Transport

  private func get<T: Decodable>(_ path: String) async throws -> T {
    guard let key = keyProvider(), !key.isEmpty else {
      throw APIError.missingAPIKey
    }

    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "GET"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw APIError.transport(String(describing: error))
    }

    guard let http = response as? HTTPURLResponse else {
      throw APIError.transport("non-HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw APIError.http(status: http.statusCode, message: Self.serverMessage(from: data))
    }

    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw APIError.decoding(String(describing: error))
    }
  }

  /// DeepSeek error bodies are not contractual; prefer HTTP status, fall back to the message field.
  static func serverMessage(from data: Data) -> String {
    struct Envelope: Decodable {
      struct Inner: Decodable { let message: String? }
      let error: Inner?
    }
    if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      let message = envelope.error?.message, !message.isEmpty
    {
      return message
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  /// Human-facing description. Never includes the API key.
  public static func describe(_ error: Swift.Error) -> String {
    switch error {
    case APIError.missingAPIKey:
      return "No API key. Set DEEPSEEK_API_KEY or add one in Settings."
    case APIError.http(let status, let message):
      switch status {
      case 401: return "Authentication failed (401). Check the API key."
      case 402: return "Insufficient balance (402)."
      case 429: return "Rate limited (429). Try again shortly."
      default: return message.isEmpty ? "HTTP \(status)." : "HTTP \(status): \(message)"
      }
    case APIError.decoding(let detail):
      return "Unexpected response format: \(detail)"
    case APIError.transport(let detail):
      return "Network error: \(detail)"
    default:
      return String(describing: error)
    }
  }
}
