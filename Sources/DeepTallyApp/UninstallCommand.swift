// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `DeepTally --uninstall`: the headless half of the uninstaller, dispatched from `main.swift` before
/// any UI exists, so `Scripts/uninstall.sh` and the release gate drive the same code the popover's
/// *Uninstall DeepTally…* button runs.
///
///   DeepTally --uninstall [--yes] [--print-only] [--home PATH] [--keep-data] [--keep-keychain]
///                        [--keep-login-item] [--trash-dir PATH]
///
/// Exit codes, contractual for the script: `0` success (including `--print-only`, which changes
/// nothing), `2` a usage error, `1` a refusal or a failure — a translocated bundle, a Keychain the
/// process cannot write to, an unremovable file.
enum UninstallCommand {
  /// One parsed invocation.
  enum Invocation: Equatable {
    case help
    case run(Uninstaller.Options)
  }

  /// A flag this command does not know, or a path-taking flag with nothing after it.
  enum ParseError: Error, Equatable {
    case unknownFlag(String)
    case missingValue(String)

    /// The line printed on stderr before the usage line.
    var message: String {
      switch self {
      case .unknownFlag(let flag): return "unknown option \"\(flag)\""
      case .missingValue(let flag): return "option \"\(flag)\" needs a path"
      }
    }
  }

  static let usageLine =
    "usage: DeepTally --uninstall [--yes] [--print-only] [--home PATH] [--keep-data] "
    + "[--keep-keychain] [--keep-login-item] [--trash-dir PATH]"

  /// `--help` output: every flag, what each one does, and the exit codes a script can branch on.
  static let helpText = """
    DeepTally --uninstall — remove DeepTally from this Mac

    Removes, in this order:
      1. the login item (Launch at login)
      2. the DeepSeek API key, the Keychain item
      3. ~/Library/Application Support/DeepTally (the ledger and any Step 2 logs)
      4. the preferences domain io.github.genoma.deeptally
      5. ~/Library/Caches/io.github.genoma.deeptally
      6. ~/Library/Saved Application State/io.github.genoma.deeptally.savedState, when present
      7. the app bundle, moved to the Trash so it stays recoverable
    Nothing outside that list is ever touched. The in-app button runs the same code.

    OPTIONS:
      --yes             the caller has already asked the user: this command never prompts
      --print-only      print the plan and change nothing (always exits 0)
      --home PATH       treat PATH as the home directory (tests and the release gate)
      --keep-data       keep the ledger and the Step 2 logs
      --keep-keychain   keep the API key in the Keychain
      --keep-login-item leave the macOS login item registered (the release gate: no side effect on
                        the machine running it)
      --trash-dir PATH  move the app bundle into PATH instead of the user's Trash
      --help, -h        this help

    EXIT CODES:
      0  removed (or, with --print-only, planned) — the summary line says how many items
      1  refused or failed: at least one item is still there, and its line says why
      2  a usage error

    RUNNING IT:
      "/Applications/DeepTally.app/Contents/MacOS/DeepTally" --uninstall
      Scripts/uninstall.sh does this, with the checks around it.
    """

  /// Parses the flags that follow `--uninstall`. `--help` wins wherever it appears.
  ///
  /// `base` is the starting point, so a test can point the command at a throwaway home and bundle
  /// instead of this Mac's; the shipping default is this home, this bundle and the real Trash.
  static func parse(
    _ arguments: [String], base: Uninstaller.Options = .shipping()
  ) throws -> Invocation {
    var options = base
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      index += 1
      switch flag {
      case "--help", "-h":
        return .help
      case "--yes":
        // Accepted and always taken: the shipped `uninstall.sh` asks the user itself, and a prompt
        // here would hang a script whose stdin is not a terminal.
        break
      case "--print-only":
        options.printOnly = true
      case "--keep-data":
        options.keepsData = true
      case "--keep-keychain":
        options.keepsKeychain = true
      case "--keep-login-item":
        options.keepsLoginItem = true
      case "--home":
        options.home = try path(after: &index, flag: flag, in: arguments)
      case "--trash-dir":
        options.trashDirectory = try path(after: &index, flag: flag, in: arguments)
      default:
        throw ParseError.unknownFlag(flag)
      }
    }
    return .run(options)
  }

  /// Runs one invocation and returns the process exit code. The report goes to stdout, one line per
  /// item plus the summary; a usage error goes to stderr, so a script that reads the report still
  /// sees exactly one thing.
  ///
  /// `base` and `seams` are the injection point: the shipping defaults are this Mac's home, the
  /// bundle this process runs from, the user's Trash and the app's own Keychain and login item, while
  /// a test hands in throwaway paths and stubs and therefore touches none of them.
  ///
  /// Main-actor because the uninstaller is (the login item, `NSWorkspace` and the Trash move all
  /// are); `main.swift` calls this from top-level code, which is main-actor isolated.
  @MainActor
  static func run(
    _ arguments: [String],
    base: Uninstaller.Options = .shipping(),
    seams: Uninstaller.Seams = Uninstaller.Seams()
  ) -> Int32 {
    let invocation: Invocation
    do {
      invocation = try parse(arguments, base: base)
    } catch let error as ParseError {
      writeToStandardError("\(error.message)\n\(usageLine)")
      return 2
    } catch {
      writeToStandardError("\(error)\n\(usageLine)")
      return 2
    }

    switch invocation {
    case .help:
      print(helpText)
      return 0
    case .run(let options):
      let report = Uninstaller(options: options, seams: seams).run()
      print(report.text)
      // A plan reports, it does not act, so `--print-only` is never a failure.
      return report.isPlan || report.isComplete ? 0 : 1
    }
  }

  /// The path that follows a flag. Another flag is not a path: `--home --print-only` must be a usage
  /// error rather than a removal under a directory called `--print-only`.
  private static func path(after index: inout Int, flag: String, in arguments: [String]) throws
    -> URL
  {
    guard index < arguments.count, !arguments[index].hasPrefix("--") else {
      throw ParseError.missingValue(flag)
    }
    defer { index += 1 }
    return URL(fileURLWithPath: arguments[index]).standardizedFileURL
  }

  private static func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
