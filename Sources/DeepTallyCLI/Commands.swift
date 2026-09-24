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
      deeptally ledger reprice     Re-price every stored row with the current price table
      deeptally --version          Print version
      deeptally --help             This help

    OPTIONS:
      --json                       Machine-readable output (`usage`, `ledger reprice`)
      --shell zsh|bash             Login shell for `key import` (default: zsh)

    KEY:
      Read from the Keychain first, then from DEEPSEEK_API_KEY. Import it once with:
        deeptally key import --shell zsh

    EXIT CODES:
      0 ok, 2 no usable key, 1 usage error or any other failure
    """

  /// Runs one invocation and returns the process exit code. Failures go to stderr here, so exactly
  /// one place decides what an error looks like.
  ///
  /// `ledgerURL` is injectable for the same reason ``LedgerStore`` takes a URL: a test reads and
  /// writes a throwaway ledger instead of the developer's real one.
  static func run(_ arguments: [String], ledgerURL: URL = LedgerStore.standardURL) async -> Int32 {
    do {
      try await dispatch(arguments, ledgerURL: ledgerURL)
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
  private static func dispatch(_ arguments: [String], ledgerURL: URL) async throws {
    guard let command = arguments.first else {
      print(usageText)
      return
    }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "balance": try await balance(rest)
    case "rate": try rate(rest)
    case "key": try key(rest)
    case "usage": try usage(rest, ledgerURL: ledgerURL)
    case "ledger": try ledger(rest, ledgerURL: ledgerURL)
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
    let resolution = APIKeySource().resolve()
    guard let key = resolution.key else {
      throw CommandFailure(message: missingKeyMessage(for: resolution), code: .key)
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
    if resolution.origin == .environment {
      // On stderr, so a script reading the balance from stdout is unaffected.
      writeToStandardError(environmentHint)
    }
  }

  /// Says what is wrong and the one command that fixes it.
  private static let missingKeyMessage = """
    No API key: the Keychain has none and DEEPSEEK_API_KEY is not set.
    Import it once with: deeptally key import --shell zsh
    """

  /// The missing-key message with the Keychain's own failure when that is the reason: "the Keychain
  /// has none" would be untrue for a locked keychain or a denied item ACL.
  private static func missingKeyMessage(for resolution: KeyResolution) -> String {
    guard let problem = resolution.keychainProblem else { return missingKeyMessage }
    return """
      No API key: \(problem); DEEPSEEK_API_KEY is not set.
      Import it once with: deeptally key import --shell zsh
      """
  }

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
    // The loader's precedence, so a user override of PriceTable.json applies here too.
    let pricing = try pricing()
    let engine = PeakOffPeakEngine(table: pricing.table, holidayCalendar: pricing.calendar)
    let presenter = RateNowPresenter(
      table: pricing.table, engine: engine, timeZone: .current)
    print(render(presenter.display(at: Date()), table: pricing.table))
  }

  /// The price table and holiday calendar every command that prices something works from: the shipped
  /// file (or a valid user override) plus the merged State Council calendar. One place, so `rate`, the
  /// `usage` warning and `ledger reprice` cannot disagree about what a model costs.
  static func pricing() throws -> (table: PriceTable, calendar: HolidayCalendar) {
    do {
      let table = try PriceTableLoader().load()
      let calendar = try HolidayCalendar.loadBundled()
        .merging(HolidayCalendar(source: "PriceTable.json", dates: table.holidays))
      return (table, calendar)
    } catch let error as PricingDataError {
      throw CommandFailure(
        message: "Could not load the pricing data: \(describe(error))", code: .failure)
    }
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

  /// Where the key comes from, its shape and any Keychain problem. The shape is deliberately coarse:
  /// a length and, only for DeepSeek's fixed `sk-` prefix, that prefix. A Keychain read that failed
  /// while a usable `DEEPSEEK_API_KEY` is set still answers (exit 0); the exit code is 2 only when
  /// there is no key at all, the same contract as `balance`.
  private static func keyStatus(_ arguments: [String]) throws {
    try reject(arguments, command: "key status")
    let resolution = APIKeySource().resolve()
    print("source: \(originName(resolution.origin))")
    if let problem = resolution.keychainProblem {
      print("keychain: \(problem)")
    }
    guard let key = resolution.key else {
      throw CommandFailure(message: missingKeyMessage(for: resolution), code: .key)
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
    if APIKeySource(keychain: keychain).resolve().origin == .environment {
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

  // MARK: - ledger

  private static let ledgerUsage = "usage: deeptally ledger reprice [--json]"

  private static func ledger(_ arguments: [String], ledgerURL: URL) throws {
    guard let subcommand = arguments.first else {
      throw CommandFailure(message: ledgerUsage, code: .failure)
    }
    let rest = Array(arguments.dropFirst())
    switch subcommand {
    case "reprice": try ledgerReprice(rest, ledgerURL: ledgerURL)
    default:
      throw CommandFailure(
        message: "Unknown ledger subcommand \"\(subcommand)\".\n\(ledgerUsage)", code: .failure)
    }
  }

  /// `deeptally ledger reprice [--json]` — recompute every stored cost with the current price table.
  ///
  /// A row's cost is written once, at import, and a row whose model id did not resolve then keeps a
  /// zero forever: re-importing cannot fix it, because `raw_hash` makes it a duplicate. This command
  /// is the repair, and the only one that changes what the ledger already recorded.
  private static func ledgerReprice(_ arguments: [String], ledgerURL: URL) throws {
    let wantsJSON: Bool
    switch arguments {
    case []: wantsJSON = false
    case ["--json"]: wantsJSON = true
    default: throw CommandFailure(message: ledgerUsage, code: .failure)
    }

    let outcome = try reprice(ledgerURL: ledgerURL)
    let currency = try pricing().table.currency
    print(
      wantsJSON
        ? try renderJSON(outcome, currency: currency)
        : renderText(outcome, currency: currency))
  }

  /// The reprice itself, separated from the printing so a test can run it without capturing stdout.
  static func reprice(ledgerURL: URL) throws -> RepriceOutcome {
    let store = try openLedger(ledgerURL)
    let pricing = try pricing()
    let engine = CostEngine(table: pricing.table, holidayCalendar: pricing.calendar)
    do {
      return try store.reprice(costing: engine)
    } catch let error as LedgerError {
      throw CommandFailure(
        message: "Could not reprice the ledger: \(describe(error))", code: .failure)
    }
  }

  /// The plain report: what changed, what the raw rows add up to before and after, and which model
  /// ids still have no price. The last part is the actionable one — the fix is a price table entry per
  /// id — so it is named even though the count alone would be shorter.
  static func renderText(_ outcome: RepriceOutcome, currency: String) -> String {
    let table =
      outcome.priceTableVersion.isEmpty
      ? "an unnamed price table" : "price table \(outcome.priceTableVersion)"
    let changed =
      outcome.madeNoChanges ? "nothing changed" : "\(grouped(outcome.rowsChanged)) rows changed"
    var lines = [
      "Repriced \(grouped(outcome.rowsExamined)) rows with \(table) (\(currency)); \(changed)."
    ]
    if outcome.madeNoChanges, outcome.previousPriceTableVersion == outcome.priceTableVersion {
      lines[0] += " The costs already came from this table."
    }
    lines.append("  spend before: \(money(outcome.spendBeforeUSD))")
    lines.append("  spend after:  \(money(outcome.spendAfterUSD))")
    guard outcome.rowsUnpriced > 0 else {
      lines.append("  unpriced:     none")
      return lines.joined(separator: "\n")
    }
    lines.append(
      "  unpriced:     \(grouped(outcome.rowsUnpriced)) rows the table does not price")
    lines.append(contentsOf: unpricedLines(outcome.unpricedModels))
    lines.append("    Add those ids to the price table, then run `deeptally ledger reprice` again.")
    return lines.joined(separator: "\n")
  }

  /// The machine-readable report. Numbers are numbers and money is a six-decimal string — the
  /// ledger's own resolution — so nothing rounds between the file and the reader. `previousPriceTableVersion`
  /// is absent when the ledger has never been repriced (a JSON `null` to any reader).
  static func renderJSON(_ outcome: RepriceOutcome, currency: String) throws -> String {
    let report = RepriceReport(
      currency: currency,
      rowsExamined: outcome.rowsExamined,
      rowsChanged: outcome.rowsChanged,
      spendBefore: money(outcome.spendBeforeUSD),
      spendAfter: money(outcome.spendAfterUSD),
      spendDelta: money(outcome.spendDeltaUSD),
      rowsUnpriced: outcome.rowsUnpriced,
      unpricedModels: outcome.unpricedModels.map {
        RepriceReport.Unpriced(model: $0.model, rows: $0.rows, spend: money($0.spendUSD))
      },
      priceTableVersion: outcome.priceTableVersion,
      previousPriceTableVersion: outcome.previousPriceTableVersion
    )
    let encoder = JSONEncoder()
    // Sorted keys and unescaped slashes: model ids contain `/`, and a report a human reads should
    // print them the way the ledger spells them.
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(report), as: UTF8.self)
  }

  /// The `--json` shape. A script parses this, so the spelling of every key is chosen here and not
  /// left to a property name.
  private struct RepriceReport: Encodable {
    struct Unpriced: Encodable {
      let model: String
      let rows: Int
      let spend: String
    }

    let currency: String
    let rowsExamined: Int
    let rowsChanged: Int
    let spendBefore: String
    let spendAfter: String
    let spendDelta: String
    let rowsUnpriced: Int
    let unpricedModels: [Unpriced]
    let priceTableVersion: String
    let previousPriceTableVersion: String?
  }

  /// One line per unpriced model id, the id column padded so the numbers line up.
  private static func unpricedLines(_ models: [UnpricedModel]) -> [String] {
    let width = models.map { $0.model.count }.max() ?? 0
    return models.map { model in
      let id = model.model.padding(toLength: width, withPad: " ", startingAt: 0)
      return "    \(id)   \(grouped(model.rows)) rows  \(money(model.spendUSD))"
    }
  }

  // MARK: - usage

  /// The ledger lands in Step 4; until then this is the stub it always was, plus the one thing a user
  /// should not have to run a separate command to discover: rows the current price table cannot price.
  private static func usage(_ arguments: [String], ledgerURL: URL) throws {
    switch arguments {
    case []:
      print("Usage summary lands in Step 4 (see docs/PLAN.md).")
      if let warning = try unpricedWarning(ledgerURL: ledgerURL) { print(warning) }
    case ["--json"]:
      print(#"{"status":"not_implemented","step":4}"#)
    default:
      throw CommandFailure(message: "usage: deeptally usage [--json]", code: .failure)
    }
  }

  /// A short warning naming the models nothing can price, or `nil` when there is no ledger to look at
  /// or nothing is missing. The cap is deliberate: a warning that lists thirty model ids is not a
  /// warning, and `ledger reprice` prints all of them.
  static func unpricedWarning(ledgerURL: URL) throws -> String? {
    guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return nil }
    let store = try openLedger(ledgerURL)
    let pricing = try pricing()
    let engine = CostEngine(table: pricing.table, holidayCalendar: pricing.calendar)

    let summary: UnpricedSummary
    do {
      summary = try store.unpricedSummary(costing: engine)
    } catch let error as LedgerError {
      throw CommandFailure(message: "Could not read the ledger: \(describe(error))", code: .failure)
    }
    guard summary.rowsUnpriced > 0 else { return nil }

    let named = summary.models.prefix(3)
      .map { "\($0.model) \(grouped($0.rows))" }
      .joined(separator: ", ")
    let remaining = max(0, summary.models.count - 3)
    let more = remaining > 0 ? ", +\(remaining) more" : ""
    return """
      warning: \(grouped(summary.rowsUnpriced)) of \(grouped(summary.rowsExamined)) ledger rows have no price (\(named)\(more)).
               Fix the price table, then run `deeptally ledger reprice`.
      """
  }

  /// Opens the ledger, mapping the store's typed failures to one sentence. The messages are built
  /// from paths, SQL contexts and sqlite's own diagnostics, none of which carry measured data.
  private static func openLedger(_ url: URL) throws -> LedgerStore {
    do {
      return try LedgerStore(url: url)
    } catch let error as LedgerError {
      throw CommandFailure(message: "Could not open the ledger: \(describe(error))", code: .failure)
    } catch {
      throw CommandFailure(message: "Could not open the ledger.", code: .failure)
    }
  }

  /// `LedgerError` as a sentence. The CSV line number is the one a text editor shows.
  private static func describe(_ error: LedgerError) -> String {
    switch error {
    case .cannotCreateDirectory(let path, let reason):
      return "could not create \(path) (\(reason))"
    case .cannotOpen(let path, let reason):
      return "could not open \(path) (\(reason))"
    case .unsupportedSchemaVersion(let found, let supported):
      return
        "the file was written by a newer DeepTally (schema \(found), this build reads \(supported))"
    case .busy:
      return "another process holds the write lock"
    case .statementFailed(let context, let code, let message):
      return "\(context) failed (sqlite \(code): \(message))"
    case .emptyRawHash(let row):
      return "row \(row) carries no dedupe key"
    case .fileMissing(let path):
      return "\(path) does not exist"
    case .unreadableFile(let path, let reason):
      return "\(path) could not be read (\(reason))"
    case .cannotWrite(let path, let reason):
      return "\(path) could not be written (\(reason))"
    case .malformedCSV(let line, let reason):
      return "line \(line) is not usable CSV (\(reason))"
    }
  }

  /// Money as text: six decimals, POSIX locale, no grouping. Six decimals is the ledger's own
  /// resolution (micro-USD), so no amount rounds on its way to the screen, and the plain report and
  /// the JSON say the same digits.
  static func money(_ amount: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 6
    formatter.maximumFractionDigits = 6
    return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
  }

  /// Row counts as text, grouped for a human and pinned to a POSIX locale so the same ledger prints
  /// the same bytes on every machine.
  static func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }

  // MARK: - Shared

  /// The `key status` name for an origin, the same words the app's footer uses.
  private static func originName(_ origin: KeyResolution.Origin) -> String {
    switch origin {
    case .keychain: return "keychain"
    case .environment: return "environment"
    case .none: return "none"
    }
  }

  /// A key's shape, never its value: the length, plus the `sk-` prefix when it is there. Only that
  /// prefix is echoed, because it is the same three characters in every DeepSeek key; any other
  /// leading character could be part of the secret.
  private static func shape(of key: String) -> String {
    let length = "\(key.count) chars"
    return key.hasPrefix(skPrefix) ? "\(length), starts with \(skPrefix)" : length
  }

  private static let skPrefix = "sk-"

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
