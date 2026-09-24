// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The two facts that outlive the process but are not settings: the last successful reading and the
/// last time the user was told the balance is low. Nothing here can hold a secret (AGENTS.md §5), and
/// a value a future build cannot read must never stop the app from launching.
@Suite("Launch state store", .serialized)
@MainActor
struct LaunchStateStoreTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.launchstate"

  @Test("a reading round-trips with the instant it was fetched")
  func readingRoundTrips() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let store = LaunchStateStore(defaults: defaults)
      #expect(store.loadReading() == nil)

      let reading = LaunchStateStore.Reading(
        balance: usdBalance("7.00"), fetchedAt: Date(timeIntervalSince1970: 1_770_000_000))
      store.saveReading(reading)

      #expect(store.loadReading() == reading)
    }
  }

  @Test("an unreadable stored reading is dropped rather than repaired")
  func corruptReadingIsDropped() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      defaults.set(
        Data("not a reading".utf8), forKey: "io.github.genoma.deeptally.last-reading")
      #expect(LaunchStateStore(defaults: defaults).loadReading() == nil)
    }
  }

  @Test("no alert ever posted is nil, not a distant past instant")
  func neverNotifiedIsNil() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let store = LaunchStateStore(defaults: defaults)
      #expect(store.loadLastNotified() == nil)

      let stamped = Date(timeIntervalSince1970: 1_770_000_000)
      store.saveLastNotified(stamped)

      #expect(store.loadLastNotified() == stamped)
    }
  }
}
