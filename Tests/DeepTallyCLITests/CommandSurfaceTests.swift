// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Testing

@testable import deeptally

/// The command surface that needs no key and no network: what the CLI accepts, what it refuses, and
/// the exit codes a script branches on. `balance` is deliberately absent — it would resolve the real
/// Keychain and call the API (its arithmetic is covered by ``BalanceExitCodeTests``).
@Suite("CLI command surface")
struct CommandSurfaceTests {
  @Test("the retained commands are accepted")
  func retainedCommands() async {
    // `rate` reads the bundled price table only: no key, no network, no ledger.
    #expect(await CLI.run(["rate"]) == 0)
    #expect(await CLI.run(["--help"]) == 0)
    #expect(await CLI.run(["--version"]) == 0)
    // A bare `deeptally` prints the help and exits 0, which the help text promises.
    #expect(await CLI.run([]) == 0)
  }

  @Test("a command deleted with the usage half is an unknown command, not a silent success")
  func removedCommandsAreUnknown() async {
    #expect(await CLI.run(["usage"]) == 1)
    #expect(await CLI.run(["import"]) == 1)
    #expect(await CLI.run(["ledger", "export", "/tmp/x.csv"]) == 1)
  }

  @Test("an unknown command, a lone key subcommand and an unknown flag all fail as usage errors")
  func usageErrors() async {
    #expect(await CLI.run(["typo"]) == 1)
    #expect(await CLI.run(["key"]) == 1)
    #expect(await CLI.run(["rate", "--nonsense"]) == 1)
  }
}
