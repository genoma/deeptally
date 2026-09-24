// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Typed failures from the shipped pricing data. Everything a packaging bug or a hand-edited user
/// file can break is a case here, so no pricing path has to trap.
public enum PricingDataError: Swift.Error, Equatable, Sendable {
  /// The resource is missing from the bundle, or the file could not be read.
  case resourceMissing(name: String)
  /// The file exists but does not match its schema.
  case decodeFailed(name: String, detail: String)
  /// A table with no models can price nothing.
  case noModels
  /// `off_peak_multiplier` must be in `(0, 1]`.
  case invalidOffPeakMultiplier(Decimal)
  /// A peak window must satisfy `0 <= start < end <= 24`.
  case invalidPeakWindow(startHourUTC: Int, endHourUTC: Int)
  /// The same alias is listed twice, so which row it resolves to would depend on table order.
  case duplicateAlias(alias: String)
}

/// Loads the versioned price table.
///
/// Precedence: a valid user override at `~/.config/deeptally/PriceTable.json` wins, otherwise
/// `Resources/PriceTable.json` from the bundle. Prices are volatile data, not logic (AGENTS.md
/// §9.11), so no price is ever written in Swift.
public struct PriceTableLoader: Sendable {
  /// The override's location relative to the home directory.
  public static let overrideRelativePath = ".config/deeptally/PriceTable.json"

  private static let bundledResourceName = "PriceTable"

  private let bundle: Bundle
  private let homeDirectory: URL

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.init(bundle: .module, homeDirectory: homeDirectory)
  }

  init(bundle: Bundle, homeDirectory: URL) {
    self.bundle = bundle
    self.homeDirectory = homeDirectory
  }

  /// The override this loader reads, whether or not the file exists.
  public var overrideURL: URL {
    homeDirectory.appending(path: Self.overrideRelativePath)
  }

  /// The override when present and valid, otherwise the bundled table.
  ///
  /// A present-but-broken override is ignored rather than fatal: a typo in a user file must not stop
  /// the app from pricing requests. The reason is dropped here — a caller that has somewhere to show
  /// it calls ``loadWithDiagnostics()`` instead.
  public func load() throws -> PriceTable {
    try loadWithDiagnostics().table
  }

  /// The table to price with, plus why a user override was not used.
  ///
  /// A valid override wins. A present-but-broken override — unreadable file, invalid JSON, failed
  /// validation — yields the bundled table and a sentence naming the file and the reason, so a
  /// caller can surface it. The bundled file is the last resort, so a failure there is still thrown.
  public func loadWithDiagnostics() throws -> (table: PriceTable, overrideProblem: String?) {
    let override: PriceTable?
    do {
      override = try loadOverride()
    } catch {
      return (try loadBundled(), Self.overrideProblem(at: overrideURL, error: error))
    }
    guard let override else { return (try loadBundled(), nil) }
    return (override, nil)
  }

  /// The bundled table, ignoring any override.
  public func loadBundled() throws -> PriceTable {
    let name = "\(Self.bundledResourceName).json"
    guard let url = bundle.url(forResource: Self.bundledResourceName, withExtension: "json") else {
      throw PricingDataError.resourceMissing(name: name)
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw PricingDataError.resourceMissing(name: name)
    }
    return try Self.decode(data, name: name)
  }

  /// The user override, or `nil` when no override file exists.
  public func loadOverride() throws -> PriceTable? {
    let path = overrideURL.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: overrideURL)
    } catch {
      throw PricingDataError.resourceMissing(name: path)
    }
    return try Self.decode(data, name: overrideURL.lastPathComponent)
  }

  /// A rejected override as one sentence: which file, and why it was not used. The full path is
  /// named rather than the file name, because the location is the actionable part.
  static func overrideProblem(at url: URL, error: any Error) -> String {
    let path = url.path(percentEncoded: false)
    return "The price override at \(path) was ignored: \(reason(for: error))."
      + " The bundled price table is in use."
  }

  /// A decode failure's detail can carry an entire `NSError` dump - `NSDebugDescription=`, a
  /// `UserInfo` dictionary, an error domain and code. That is developer noise in a user-facing
  /// banner, so keep the one clause a person editing the file can act on.
  static func shortDetail(_ detail: String) -> String {
    var text = detail
    if let clause = text.range(of: "NSDebugDescription=") {
      text = String(text[clause.upperBound...])
      if let end = text.firstIndex(where: { $0 == "," || $0 == "}" }) {
        text = String(text[..<end])
      }
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      return "the file could not be read"
    }
    return text.count > 160 ? String(text.prefix(157)) + "..." : text
  }

  /// The reason half of ``overrideProblem(at:error:)``. A decode failure keeps its detail, which
  /// names the offending field — the one thing a user editing the file needs.
  static func reason(for error: any Error) -> String {
    guard let pricing = error as? PricingDataError else { return String(describing: error) }
    switch pricing {
    case .resourceMissing:
      return "the file is missing or unreadable"
    case .decodeFailed(_, let detail):
      return "the file is not valid JSON for the price-table schema (\(shortDetail(detail)))"
    case .noModels:
      return "the table lists no models"
    case .invalidOffPeakMultiplier(let value):
      return "the off-peak multiplier \(value) is not in (0, 1]"
    case .invalidPeakWindow(let start, let end):
      return "the peak window \(start)-\(end) UTC is not a valid hour range"
    case .duplicateAlias(let alias):
      return "the alias \"\(alias)\" is listed on more than one model"
    }
  }

  /// Decodes and validates one table. `name` only appears in thrown errors.
  static func decode(_ data: Data, name: String) throws -> PriceTable {
    let table: PriceTable
    do {
      table = try JSONDecoder().decode(PriceTable.self, from: data)
    } catch {
      throw PricingDataError.decodeFailed(name: name, detail: String(describing: error))
    }
    try validate(table)
    return table
  }

  /// The rules that make a table safe to bill with. The bundled file and every override pass here.
  static func validate(_ table: PriceTable) throws {
    guard !table.models.isEmpty else { throw PricingDataError.noModels }
    guard table.offPeakMultiplier > 0, table.offPeakMultiplier <= 1 else {
      throw PricingDataError.invalidOffPeakMultiplier(table.offPeakMultiplier)
    }
    for window in table.peakWindowsUTC {
      guard window.startHourUTC >= 0, window.startHourUTC < window.endHourUTC,
        window.endHourUTC <= 24
      else {
        throw PricingDataError.invalidPeakWindow(
          startHourUTC: window.startHourUTC, endHourUTC: window.endHourUTC)
      }
    }
    // An alias claimed by two rows would be priced by table order, which no reader of the file can
    // see. Rejecting the table is loud; falling back to the bundled one prices correctly.
    var claimedAliases: Set<String> = []
    for price in table.models {
      for alias in price.aliases where !claimedAliases.insert(alias).inserted {
        throw PricingDataError.duplicateAlias(alias: alias)
      }
    }
  }
}
