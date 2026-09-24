// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import deeptally

/// The CLI's argument parsers. A rejected flag must fail with a sentence that names the option and
/// what it wanted, because the exit code is the only other thing a script sees.
@Suite("CLI options")
struct OptionsTests {
  @Test("usage takes --json and --days in any order")
  func usageAcceptsFlags() throws {
    #expect(try UsageOptions.parse([]) == UsageOptions(json: false, days: 30))
    #expect(try UsageOptions.parse(["--json"]) == UsageOptions(json: true, days: 30))
    #expect(try UsageOptions.parse(["--days", "7"]) == UsageOptions(json: false, days: 7))
    #expect(try UsageOptions.parse(["--days", "7", "--json"]) == UsageOptions(json: true, days: 7))
    #expect(try UsageOptions.parse(["--json", "--days", "1"]) == UsageOptions(json: true, days: 1))
  }

  @Test("usage rejects a flag it cannot honour, and says which")
  func usageRejectsBadArguments() {
    #expect(throws: OptionError.unexpectedArgument("--verbose")) {
      try UsageOptions.parse(["--verbose"])
    }
    #expect(throws: OptionError.unexpectedArgument("7")) {
      try UsageOptions.parse(["--days", "7", "7"])
    }
    #expect(throws: OptionError.needsValue(option: "--days", expected: "a positive whole number")) {
      try UsageOptions.parse(["--days"])
    }
    #expect(
      throws: OptionError.invalidValue(
        option: "--days", value: "0", expected: "a positive whole number")
    ) {
      try UsageOptions.parse(["--days", "0"])
    }
    #expect(
      throws: OptionError.invalidValue(
        option: "--days", value: "seven", expected: "a positive whole number")
    ) {
      try UsageOptions.parse(["--days", "seven"])
    }
  }

  @Test("import takes --full and nothing else")
  func importFlags() throws {
    #expect(try ImportOptions.parse([]) == ImportOptions(full: false))
    #expect(try ImportOptions.parse(["--full"]) == ImportOptions(full: true))
    #expect(throws: OptionError.unexpectedArgument("--opencode")) {
      try ImportOptions.parse(["--opencode"])
    }
  }

  @Test("prune requires --days and rejects everything else")
  func pruneFlags() throws {
    #expect(try PruneOptions.parse(["--days", "400"]) == PruneOptions(days: 400))
    #expect(throws: OptionError.unexpectedArgument("400")) {
      try PruneOptions.parse(["400"])
    }
    #expect(
      throws: OptionError.needsValue(
        option: "--days", expected: "a positive whole number of days")
    ) {
      try PruneOptions.parse([])
    }
    #expect(
      throws: OptionError.invalidValue(
        option: "--days", value: "-1", expected: "a positive whole number of days")
    ) {
      try PruneOptions.parse(["--days", "-1"])
    }
  }

  @Test("a rejection reads as a sentence fragment")
  func errorSentences() {
    #expect(OptionError.unexpectedArgument("--json").sentence == "unexpected argument \"--json\"")

    let needsValue = OptionError.needsValue(
      option: "--days", expected: "a positive whole number")
    #expect(needsValue.sentence == "--days needs a value (a positive whole number)")

    let invalid = OptionError.invalidValue(
      option: "--days", value: "x", expected: "a positive whole number")
    #expect(invalid.sentence == "--days must be a positive whole number, not \"x\"")
  }
}
