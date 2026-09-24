// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore

/// The one balance request the app makes, named so a test can stand in for the network.
///
/// `AppEnvironment` already composed the client behind a factory keyed by the key a refresh resolved,
/// so this protocol is only a name for what that factory returns. Without it the app layer's state
/// machine — the failure text, the backoff, the queued refresh, which key a request used — could be
/// observed only by talking to DeepSeek. ``DeepSeekClient`` is the shipping conformance and the only
/// one the app has.
protocol BalanceFetching: Sendable {
  /// `GET /user/balance`. Never includes the API key in anything it throws.
  func balance() async throws -> Balance
}

extension DeepSeekClient: BalanceFetching {}
