// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation

// MARK: - Command-line contract

/// Process exit codes. Contractual for scripts: 0 success, 2 a missing or unusable key, 1 a usage
/// error or any other failure that is not about the key.
private enum ExitCode: Int32 {
  case ok = 0
  case failure = 1
  case key = 2
}

/// A failure that ends the process with one message on stderr. Messages are assembled from origins,
/// shapes and status codes, so no value of this type can carry the secret.
private struct CommandFailure: Error {
  let message: String
  let code: ExitCode
}

/// The CLI companion to the app: same key precedence, same price table, no second opinion.
enum CLI {
  /// `0.1.0-dev` until Step 7 tags the first release.
  static let version = "0.1.0-dev"

  /// `--help` output. One line per command, descriptions aligned like the Makefile's `help` target.
  static let usageText = """
    deeptally \(version) — DeepSeek usage meter (CLI companion)

    USAGE:
      deeptally balance            Show the account balance
      deeptally rate               Show the peak/off-peak window in force and its prices
      deeptally key status         Show which store supplies the API key
      deeptally key import         Store the key from the login shell in the Keychain
      deeptally key delete         Remove the stored key from the Keychain
      deeptally usage [--json]     Usage summary (lands in Step 4)
      deeptally --version          Print version
      deeptally --help             This help

    OPTIONS:
      --shell zsh|bash             Login shell for `key import` (default: zsh)

    KEY:
      Read from the Keychain first, then from DEEPSEEK_API_KEY. Import it once with:
        deeptally key import --shell zsh

    EXIT CODES:
      0 ok, 2 no usable key, 1 usage error or any other failure
    """

  /// Runs one invocation and returns the process exit code. Failures go to stderr here, so exactly
  /// one place decides what an error looks like.
  static func run(_ arguments: [String]) async -> Int32 {
    do {
      try await dispatch(arguments)
      return ExitCode.ok.rawValue
    } catch let failure as CommandFailure {
      writeToStandardError(failure.message)
      return failure.code.rawValue
    } catch {
      // Every command maps the failures it expects, so this is a bug: report it and keep the exit
      // codes contractual by failing like a usage error rather than like a key problem.
      writeToStandardError("Unexpected error: \(error)")
      return ExitCode.failure.rawValue
    }
  }

  // MARK: - Dispatch

  /// A bare `deeptally` prints the help (exit 0); an unknown command prints it too, but on stderr
  /// and with exit code 1.
  private static func dispatch(_ arguments: [String]) async throws {
    guard let command = arguments.first else {
      print(usageText)
      return
    }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "balance": try await balance(rest)
    case "rate": try rate(rest)
    case "key": try key(rest)
    case "usage": try usage(rest)
    case "--version", "version": print("deeptally \(version)")
    case "--help", "-h": print(usageText)
    default:
      throw CommandFailure(
        message: "Unknown command \"\(command)\".\n\n\(usageText)", code: .failure)
    }
  }

  // MARK: - balance

  /// The account balance exactly as the API reports it: the currency is shown as-is, never
  /// converted. Resolves the key but never imports one — importing is an explicit user action.
  private static func balance(_ arguments: [String]) async throws {
    try reject(arguments, command: "balance")
    let resolution = try resolveKey()
    guard let key = resolution.key else {
      throw CommandFailure(message: missingKeyMessage, code: .key)
    }
    let client = DeepSeekClient(keyProvider: { key })
    let balance: Balance
    do {
      balance = try await client.balance()
    } catch {
      throw CommandFailure(message: DeepSeekClient.describe(error), code: .key)
    }
    guard let info = balance.primary else {
      throw CommandFailure(message: "No balance information returned.", code: .failure)
    }
    let availability = balance.isAvailable ? "available" : "unavailable"
    print("\(info.currency) \(info.totalBalance)  (\(availability))")
    print("  granted:   \(info.grantedBalance)")
    print("  topped up: \(info.toppedUpBalance)")
    if case .environment = resolution {
      // On stderr, so a script reading the balance from stdout is unaffected.
      writeToStandardError(environmentHint)
    }
  }

  /// Says what is wrong and the one command that fixes it.
  private static let missingKeyMessage = """
    No API key: the Keychain has none and DEEPSEEK_API_KEY is not set.
    Import it once with: deeptally key import --shell zsh
    """

  /// Printed after a balance that was paid for by the environment: correct, but it has to be set
  /// again in every new shell.
  private static let environmentHint = """
    hint: the key came from DEEPSEEK_API_KEY. `deeptally key import --shell zsh` stores it in the
    Keychain, so the terminal and the app use the same one.
    """

  // MARK: - rate

  /// The peak/off-peak window in force right now, when it ends, and the effective price of every
  /// model for as long as it lasts. The classification is a UTC question answered by
  /// ``PeakOffPeakEngine`` against the merged holiday calendar; the times are the user's own local
  /// clock, because that is the clock they act on. Needs no key.
  private static func rate(_ arguments: [String]) throws {
    try reject(arguments, command: "rate")
    let table: PriceTable
    let calendar: HolidayCalendar
    do {
      // The loader's precedence, so a user override of PriceTable.json applies here too.
      table = try PriceTableLoader().load()
      calendar = try HolidayCalendar.loadBundled()
        .merging(HolidayCalendar(source: "PriceTable.json", dates: table.holidays))
    } catch let error as PricingDataError {
      throw CommandFailure(
        message: "Could not load the pricing data: \(describe(error))", code: .failure)
    }
    let engine = PeakOffPeakEngine(table: table, holidayCalendar: calendar)
    let presenter = RateNowPresenter(table: table, engine: engine, timeZone: .current)
    print(render(presenter.display(at: Date()), table: table))
  }

  /// The rate display as text: a headline, three context lines, one line per model.
  private static func render(_ display: RateNowDisplay, table: PriceTable) -> String {
    let holiday = display.holidayNote.map { ", \($0)" } ?? ""
    let nameWidth = display.models.map { $0.model.count }.max() ?? 0
    var lines = [
      "\(display.periodLabel)  (\(display.multiplierLabel)\(holiday))",
      "  window ends:  \(display.windowEndsLocal) local, \(display.countdown) left",
      "  next change:  \(display.nextTransitionLocal)",
      "  prices:       \(table.currency) per 1M tokens, price table \(table.version)",
    ]
    for rate in display.models {
      let name = rate.model.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
      let hit = "cache hit \(rate.cacheHit)"
      let miss = "cache miss \(rate.cacheMiss)"
      let output = "output \(rate.output)"
      lines.append("    \(name)   \(hit)   \(miss)   \(output)")
    }
    return lines.joined(separator: "\n")
  }

  /// `PricingDataError` as a sentence. `detail` is kept: it names the offending field.
  private static func describe(_ error: PricingDataError) -> String {
    switch error {
    case .resourceMissing(let name):
      return "\(name) is missing or unreadable."
    case .decodeFailed(let name, let detail):
      return "\(name) is not valid JSON for its schema: \(detail)"
    case .noModels:
      return "the price table lists no models."
    case .invalidOffPeakMultiplier(let value):
      return "the off-peak multiplier \(value) is not in (0, 1]."
    case .invalidPeakWindow(let start, let end):
      return "the peak window \(start)-\(end) UTC is not a valid hour range."
    }
  }

  // MARK: - key

  private static let keyUsage = "usage: deeptally key <status|import|delete>"

  private static func key(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CommandFailure(message: keyUsage, code: .failure)
    }
    let rest = Array(arguments.dropFirst())
    switch subcommand {
    case "status": try keyStatus(rest)
    case "import": try keyImport(rest)
    case "delete": try keyDelete(rest)
    default:
      throw CommandFailure(
        message: "Unknown key subcommand \"\(subcommand)\".\n\(keyUsage)", code: .failure)
    }
  }

  /// Where the key comes from, and its shape. The shape is deliberately coarse: a length and, only
  /// for DeepSeek's fixed `sk-` prefix, that prefix.
  private static func keyStatus(_ arguments: [String]) throws {
    try reject(arguments, command: "key status")
    let resolution = try resolveKey()
    print("source: \(resolution.origin)")
    guard let key = resolution.key else {
      print("run:    deeptally key import --shell zsh")
      return
    }
    print("shape:  \(shape(of: key))")
  }

  /// Imports the key from the login shell once and stores it in the Keychain. The only command that
  /// runs a shell; nothing else here shells out.
  private static func keyImport(_ arguments: [String]) throws {
    let shell = try importShell(from: arguments)
    let key: String
    do {
      key = try APIKeySource().importFromShell(shell)
    } catch let error as KeyImportError {
      throw CommandFailure(message: describe(error, shell: shell), code: .key)
    } catch {
      throw CommandFailure(
        message: "Importing from the \(shell.rawValue) login shell failed.", code: .key)
    }
    print("Stored the key from your \(shell.rawValue) login shell (\(shape(of: key))).")
  }

  /// Removes the stored key. Deleting when nothing is stored is a no-op, not an error, so the
  /// command is safe to run twice.
  private static func keyDelete(_ arguments: [String]) throws {
    try reject(arguments, command: "key delete")
    let keychain = KeychainStore()
    let hadKey = keychain.hasItem()
    do {
      try APIKeySource(keychain: keychain).deleteKey()
    } catch let error as KeychainError {
      throw CommandFailure(
        message: "Could not remove the stored key (\(describe(error))).", code: .key)
    } catch {
      throw CommandFailure(message: "Could not remove the stored key.", code: .key)
    }
    print(hadKey ? "Removed the stored key from the Keychain." : "No stored key in the Keychain.")
    if case .environment? = try? KeyResolution.resolve() {
      writeToStandardError(environmentStillSet)
    }
  }

  /// Printed when the environment still supplies the key that was just deleted, so the user is not
  /// told the key is gone while the CLI keeps working.
  private static let environmentStillSet =
    "note: DEEPSEEK_API_KEY is still exported; the CLI keeps using it."

  /// `--shell zsh|bash`, defaulting to zsh. The shell is never guessed: the rc file that exports
  /// the key differs per shell, and zsh is what macOS ships as the login shell.
  private static func importShell(from arguments: [String]) throws -> ShellKind {
    switch arguments.count {
    case 0:
      return .zsh
    case 1 where arguments.first == "--shell":
      throw CommandFailure(
        message: "key import: --shell needs a value (zsh or bash).\n\(importUsage)", code: .failure)
    case 2 where arguments.first == "--shell":
      guard let shell = ShellKind(rawValue: arguments[1]) else {
        let message = "key import: unknown shell \"\(arguments[1])\"; use zsh or bash."
        throw CommandFailure(message: "\(message)\n\(importUsage)", code: .failure)
      }
      return shell
    default:
      throw CommandFailure(
        message: "key import: unexpected arguments.\n\(importUsage)", code: .failure)
    }
  }

  private static let importUsage = "usage: deeptally key import [--shell zsh|bash]"

  /// `KeyImportError` as a sentence. No case carries the secret or any shell output.
  private static func describe(_ error: KeyImportError, shell: ShellKind) -> String {
    switch error {
    case .notFoundInShell:
      let files = rcFiles(shell)
      return "No DEEPSEEK_API_KEY from your \(shell.rawValue) login shell (\(files))."
    case .emptySecret:
      return "The \(shell.rawValue) login shell printed a value that is not a usable key."
    case .shellTimedOut:
      return "The \(shell.rawValue) login shell did not finish in time."
    case .shellFailed(let status):
      return "The \(shell.rawValue) login shell exited with status \(status)."
    case .keychain(let status):
      return "Storing the key in the Keychain failed (status \(status))."
    }
  }

  /// `KeychainError` as a sentence: status codes and a validation flag, never the secret.
  private static func describe(_ error: KeychainError) -> String {
    switch error {
    case .unexpectedStatus(let status): return "Keychain status \(status)"
    case .invalidSecret: return "the value is not a usable key"
    }
  }

  /// Where the import looks: `-l -i` sources the profile and the rc file, so both are named.
  private static func rcFiles(_ shell: ShellKind) -> String {
    switch shell {
    case .zsh: return "~/.zprofile, ~/.zshrc"
    case .bash: return "~/.bash_profile, ~/.bashrc"
    }
  }

  // MARK: - usage

  /// The ledger lands in Step 4; until then this is the stub it always was.
  private static func usage(_ arguments: [String]) throws {
    switch arguments {
    case []:
      print("Usage summary lands in Step 4 (see docs/PLAN.md).")
    case ["--json"]:
      print(#"{"status":"not_implemented","step":4}"#)
    default:
      throw CommandFailure(message: "usage: deeptally usage [--json]", code: .failure)
    }
  }

  // MARK: - Shared

  /// A key's shape, never its value: the length, plus the `sk-` prefix when it is there. Only that
  /// prefix is echoed, because it is the same three characters in every DeepSeek key; any other
  /// leading character could be part of the secret.
  private static func shape(of key: String) -> String {
    let length = "\(key.count) chars"
    return key.hasPrefix(skPrefix) ? "\(length), starts with \(skPrefix)" : length
  }

  private static let skPrefix = "sk-"

  /// Resolves the key through ``KeyResolution``; an unreadable store is an unusable key (exit 2),
  /// not a usage error.
  private static func resolveKey() throws -> KeyResolution {
    do {
      return try KeyResolution.resolve()
    } catch let error as KeychainError {
      throw CommandFailure(
        message: "Could not read the API key from the Keychain (\(describe(error))).", code: .key)
    } catch {
      throw CommandFailure(message: "Could not read the API key from the Keychain.", code: .key)
    }
  }

  /// A command that takes no arguments rejects them rather than ignoring them: a typo'd flag must
  /// not silently change what ran.
  private static func reject(_ arguments: [String], command: String) throws {
    guard let first = arguments.first else { return }
    throw CommandFailure(
      message: "deeptally \(command): unexpected argument \"\(first)\".", code: .failure)
  }

  /// Errors go to stderr so stdout stays parseable.
  private static func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}

// MARK: - Key resolution

/// The key the CLI will use, and the store it came from. One precedence order, shared with the app:
/// Keychain first, then `DEEPSEEK_API_KEY`.
private enum KeyResolution {
  case keychain(String)
  case environment(String)
  /// Neither store has one.
  case none

  /// The secret itself, or `nil` for ``none``.
  var key: String? {
    switch self {
    case .keychain(let key), .environment(let key): return key
    case .none: return nil
    }
  }

  /// The origin name `key status` prints.
  var origin: String {
    switch self {
    case .keychain: return "keychain"
    case .environment: return "environment"
    case .none: return "none"
    }
  }

  /// Asks ``APIKeySource`` twice — once with the environment withheld — rather than re-implementing
  /// its rules (trimmed, non-empty), so "which key won" cannot drift from "which key is used".
  static func resolve(
    keychain: KeychainStore = KeychainStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> KeyResolution {
    if let key = try APIKeySource(keychain: keychain, environment: [:]).currentKey() {
      return .keychain(key)
    }
    if let key = try APIKeySource(keychain: keychain, environment: environment).currentKey() {
      return .environment(key)
    }
    return .none
  }
}
