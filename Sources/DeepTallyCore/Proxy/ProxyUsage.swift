// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The usage one proxied response reported, ready for the ledger.
///
/// DeepSeek publishes no usage endpoint, so the `usage` object on each chat completion is the only
/// API-level accounting signal. The proxy is the component that sees the response body as it
/// passes through, and ``ProxyUsageReader`` is what turns that body into this value. It carries no
/// prompt or completion text: only the usage-bearing line is ever decoded, so content cannot leak
/// into a log or a store through this path.
public struct ProxyUsage: Sendable, Equatable {
  /// The response `id`, the dedupe key when the gateway sent one. `nil` when the body omitted it or
  /// sent it empty — that is not a reason to drop the usage, the caller falls back to its own key.
  public let responseID: String?
  /// The model that served the request. Never empty: a body that names no model cannot be
  /// attributed or priced, so the reader reports no usage at all for one.
  public let model: String
  /// The counters with reasoning left **inside** `completionTokens` and also carried as
  /// `reasoningTokens`. The ledger derives `output = completionTokens - reasoningTokens`, so a
  /// reader that subtracted reasoning here would store a completion count that no longer agrees
  /// with the API's own total.
  public let usage: TokenUsage
  /// When the proxy observed the response, supplied by the caller so a record's instant is the
  /// observation's and not a clock read at parse time.
  public let recordedAt: Date

  public init(responseID: String?, model: String, usage: TokenUsage, recordedAt: Date) {
    self.responseID = responseID
    self.model = model
    self.usage = usage
    self.recordedAt = recordedAt
  }
}
