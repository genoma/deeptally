// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persists `AppSettings` as one JSON object inside a caller-supplied `UserDefaults` domain.
///
/// The store never touches the shared standard domain: the app injects its own and tests inject a
/// throwaway suite, so nothing here can read or write preferences the caller did not offer.
public struct SettingsStore: Sendable {
  /// `UserDefaults` is documented thread-safe but is not annotated `Sendable` in the SDK, so the
  /// conformance needs this one escape hatch.
  private nonisolated(unsafe) let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults, key: String = "io.github.genoma.deeptally.settings") {
    self.defaults = defaults
    self.key = key
  }

  /// The stored settings, validated. `AppSettings.default` when nothing is stored, when the blob is
  /// corrupt, or when it is not a JSON object — bad preferences must never stop the app.
  public func load() -> AppSettings {
    guard let data = defaults.data(forKey: key),
      let stored = try? JSONDecoder().decode(AppSettings.self, from: data)
    else {
      return .default
    }
    return stored.validated()
  }

  /// Stores the settings, validated first, so an out-of-range value never reaches the domain.
  public func save(_ settings: AppSettings) {
    guard let data = try? JSONEncoder().encode(settings.validated()) else { return }
    defaults.set(data, forKey: key)
  }
}
