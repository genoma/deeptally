// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Testing

@testable import deeptally

/// `deeptally balance`'s exit-code contract: 2 means "no usable key", never "the request failed".
/// An offline laptop, a rate limit or a server error must not make a script believe the key is bad.
@Suite("Balance exit codes")
struct BalanceExitCodeTests {
  @Test("a missing key and a rejection by the service exit 2")
  func keyFailures() {
    #expect(CLI.balanceExitCode(for: DeepSeekClient.APIError.missingAPIKey).rawValue == 2)
    #expect(
      CLI.balanceExitCode(for: DeepSeekClient.APIError.http(status: 401, message: "")).rawValue == 2
    )
    #expect(
      CLI.balanceExitCode(for: DeepSeekClient.APIError.http(status: 403, message: "")).rawValue == 2
    )
  }

  @Test("a transport failure, a rate limit, a payment problem and a server error all exit 1")
  func ordinaryFailures() {
    #expect(
      CLI.balanceExitCode(for: DeepSeekClient.APIError.transport("offline")).rawValue == 1)
    #expect(
      CLI.balanceExitCode(for: DeepSeekClient.APIError.http(status: 402, message: "")).rawValue == 1
    )
    #expect(
      CLI.balanceExitCode(for: DeepSeekClient.APIError.http(status: 429, message: "")).rawValue == 1
    )
    #expect(
      CLI.balanceExitCode(for: DeepSeekClient.APIError.http(status: 500, message: "")).rawValue == 1
    )
    #expect(
      CLI.balanceExitCode(for: DeepSeekClient.APIError.decoding("bad body")).rawValue == 1)
  }

  @Test("an error from outside the API client is an ordinary failure")
  func foreignError() {
    struct Other: Error {}
    #expect(CLI.balanceExitCode(for: Other()).rawValue == 1)
  }
}
