// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import deeptally

/// `DEEPTALLY_LEDGER`: how the process picks the ledger file. It exists because `HOME` does not
/// redirect the standard path — `FileManager` resolves the application-support directory from the
/// real home — so this is the one safe way to run `ledger prune` or `ledger reprice` against a copy.
@Suite("Ledger path resolution")
struct LedgerPathTests {
  @Test("DEEPTALLY_LEDGER names the ledger; unset or empty falls back to the standard path")
  func environmentOverride() {
    let fallback = URL(fileURLWithPath: "/tmp/standard.sqlite")
    #expect(
      CLI.resolvedLedgerURL(
        environment: ["DEEPTALLY_LEDGER": "/tmp/copy.sqlite"], fallback: fallback)
        == URL(fileURLWithPath: "/tmp/copy.sqlite"))
    #expect(CLI.resolvedLedgerURL(environment: [:], fallback: fallback) == fallback)
    #expect(
      CLI.resolvedLedgerURL(environment: ["DEEPTALLY_LEDGER": ""], fallback: fallback) == fallback)
  }
}
