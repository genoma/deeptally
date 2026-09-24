import Darwin
// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation

let version = "0.1.0-dev"

func printUsage() {
  print(
    """
    deeptally \(version) — DeepSeek usage meter (CLI companion)

    USAGE:
      deeptally balance          Show account balance
      deeptally usage [--json]   Usage summary (lands in Step 4)
      deeptally --version        Print version
      deeptally --help           This help

    The API key is read from DEEPSEEK_API_KEY (the app uses the Keychain instead).
    """)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "balance":
  let client = DeepSeekClient(keyProvider: DeepSeekClient.keyFromEnvironment)
  do {
    let balance = try await client.balance()
    guard let info = balance.primary else {
      fail("No balance information returned.")
    }
    let availability = balance.isAvailable ? "available" : "unavailable"
    print("\(info.currency) \(info.totalBalance)  (\(availability))")
    print("  granted:   \(info.grantedBalance)")
    print("  topped up: \(info.toppedUpBalance)")
  } catch {
    fail(DeepSeekClient.describe(error), code: 2)
  }

case "usage":
  if arguments.contains("--json") {
    print(#"{"status":"not_implemented","step":4}"#)
  } else {
    print("Usage summary lands in Step 4 (see docs/PLAN.md).")
  }

case "--version", "version":
  print("deeptally \(version)")

case "--help", "-h", nil:
  printUsage()

default:
  printUsage()
  exit(1)
}
