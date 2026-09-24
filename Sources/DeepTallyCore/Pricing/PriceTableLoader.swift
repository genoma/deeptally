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
  /// the app from pricing requests. `loadOverride()` still reports that failure to callers that want
  /// to surface it.
  public func load() throws -> PriceTable {
    if let override = try? loadOverride() {
      return override
    }
    return try loadBundled()
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
  }
}
