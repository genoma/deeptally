// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A rejected argument, described as a sentence fragment. The command being parsed supplies the usage
/// line and the command name, so this type stays reusable and carries nothing command-specific.
///
/// Internal, not private: the CLI's argument parsing is the one part of it that is worth a test, and
/// `DeepTallyCLITests` proves the rejections without shelling out to the built binary.
enum OptionError: Error, Equatable {
  case unexpectedArgument(String)
  case needsValue(option: String, expected: String)
  case invalidValue(option: String, value: String, expected: String)

  /// The failure as a sentence without a trailing period: the command prints
  /// `deeptally <command>: <sentence>.` followed by its usage line.
  var sentence: String {
    switch self {
    case .unexpectedArgument(let argument):
      return "unexpected argument \"\(argument)\""
    case .needsValue(let option, let expected):
      return "\(option) needs a value (\(expected))"
    case .invalidValue(let option, let value, let expected):
      return "\(option) must be \(expected), not \"\(value)\""
    }
  }
}

/// `deeptally import [--full]`.
struct ImportOptions: Equatable {
  /// Rescan opencode from the beginning instead of resuming at the ledger's watermark. This is the
  /// repair pass for a row that arrived with a timestamp at or before the stored watermark; it costs
  /// a full scan, so it is not the normal path.
  var full = false

  static func parse(_ arguments: [String]) throws -> ImportOptions {
    var options = ImportOptions()
    for argument in arguments {
      switch argument {
      case "--full": options.full = true
      default: throw OptionError.unexpectedArgument(argument)
      }
    }
    return options
  }
}

/// `deeptally usage [--json] [--days N]`.
struct UsageOptions: Equatable {
  /// The per-model window when `--days` is absent. The headline windows (today, 7, 30) are fixed.
  static let defaultDays = 30

  var json = false
  var days = defaultDays

  static func parse(_ arguments: [String]) throws -> UsageOptions {
    var options = UsageOptions()
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--json":
        options.json = true
        index += 1
      case "--days":
        let raw = try value("--days", at: index + 1, in: arguments)
        guard let days = Int(raw), days > 0 else {
          throw OptionError.invalidValue(
            option: "--days", value: raw, expected: "a positive whole number")
        }
        options.days = days
        index += 2
      default:
        throw OptionError.unexpectedArgument(arguments[index])
      }
    }
    return options
  }

  /// The value after an option, or the failure that names what was expected. `--days=7` is not
  /// accepted: every flag in this CLI is a separate argv element, so there is one spelling per flag.
  private static func value(
    _ option: String, at index: Int, in arguments: [String]
  ) throws -> String {
    guard index < arguments.count else {
      throw OptionError.needsValue(option: option, expected: "a positive whole number")
    }
    return arguments[index]
  }
}

/// `deeptally ledger prune --days N`. `--days` is required: the CLI never chooses a prune horizon for
/// the user, because the app's own policy (400 days) is a policy and not a command-line default.
struct PruneOptions: Equatable {
  var days: Int

  static func parse(_ arguments: [String]) throws -> PruneOptions {
    var days: Int?
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--days":
        guard index + 1 < arguments.count else {
          throw OptionError.needsValue(
            option: "--days", expected: "a positive whole number of days")
        }
        let raw = arguments[index + 1]
        guard let value = Int(raw), value > 0 else {
          throw OptionError.invalidValue(
            option: "--days", value: raw, expected: "a positive whole number of days")
        }
        days = value
        index += 2
      default:
        throw OptionError.unexpectedArgument(arguments[index])
      }
    }
    guard let days else {
      throw OptionError.needsValue(option: "--days", expected: "a positive whole number of days")
    }
    return PruneOptions(days: days)
  }
}
