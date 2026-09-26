// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The key lifecycle: where the key in use comes from, and the rule that an error a previous key
/// produced cannot outlive the key change that replaced it.
@Suite("App model key changes", .serialized)
@MainActor
struct AppModelKeyTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.key"
  /// A test-only Keychain service: the shipped item is never read or written here, and the test item
  /// is deleted at both ends so a run leaves nothing behind.
  private static let storeService = "io.github.genoma.deeptally.tests.appmodel.keychanges"
  private static let storedKey = "sk-test-stored-key"

  @Test("forgetting the key clears the failing fetch's banner and reports no key")
  func forgettingTheKeyClearsTheErrorBanner() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let store = Self.makeStore()
      try store.store(Self.storedKey)
      defer { try? store.delete() }

      let fixture = makeFixture(
        defaults: defaults, outcome: .failure(.http(status: 401, message: "")),
        key: testKeySource(.store(store)))
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)
      #expect(model.keyOrigin == .keychain)
      #expect(model.keyOriginLabel == "API key: Keychain")
      #expect(model.banners.map(\.id) == ["refresh"])

      model.deleteKey()

      #expect(model.importMessage == "Removed the stored key from the Keychain.")
      #expect(model.keyOrigin == .none)
      #expect(model.keychainProblem == nil)
      // An unresolvable store must not leave a "401" on screen next to "No API key yet".
      #expect(model.banners.map(\.id) == ["no-key"])
    }
  }

  @Test("importing a key clears the error banner and the next request uses the new key")
  func importingAKeyClearsTheErrorBanner() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let store = Self.makeStore()
      try store.store(Self.storedKey)
      defer { try? store.delete() }
      let importedKey = "sk-test-imported-key"

      let fixture = makeFixture(
        defaults: defaults, outcome: .failure(.http(status: 401, message: "")),
        key: testKeySource(.store(store), shellRunner: { _, _ in importedKey }))
      let model = fixture.model

      model.refresh()
      await settleRefresh(model)
      #expect(model.banners.map(\.id) == ["refresh"])

      // Hold the request the import queues open, so the assertion lands on the key change itself
      // rather than on the fetch that follows it.
      fixture.fetcher.holdRequestsOpen()
      model.importKey(from: .zsh)
      await waitUntil("the import to run the next request") { fixture.fetcher.callCount == 2 }

      #expect(model.importMessage == "Imported the key from your zsh login shell.")
      #expect(!model.isImportingKey)
      #expect(!model.banners.contains { $0.id == "refresh" })
      #expect(!model.banners.contains { $0.id == "key-import" })
      #expect(model.keyOrigin == .keychain)
      // The new key is not captured at launch: the queued request already uses it.
      #expect(fixture.fetcher.keysUsed == [Self.storedKey, importedKey])

      fixture.fetcher.setOutcome(.balance(usdBalance("12.34")))
      fixture.fetcher.release()
      await settleRefresh(model)
      #expect(model.banners.isEmpty)
      #expect(model.balanceState?.amountText == "$12.34")
    }
  }

  @Test(
    "an import that finds no key is reported as a banner and leaves the app unusable rather than broken"
  )
  func failedImportIsReported() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let shell: ShellKind = .bash
      let fixture = makeFixture(
        defaults: defaults,
        key: testKeySource(.none, shellRunner: { _, _ in throw KeyImportError.notFoundInShell }))
      let model = fixture.model

      model.importKey(from: shell)
      await waitUntil("the import to fail") { model.importMessage != nil }

      let banner = try #require(model.banners.first { $0.id == "key-import" })
      #expect(banner.kind == .error)
      #expect(
        banner.message
          == "No DEEPSEEK_API_KEY in your bash login shell. Export it in ~/.bash_profile or "
          + "~/.bashrc and try again.")
      #expect(!model.isImportingKey)
      #expect(model.keyOrigin == .none)
      #expect(fixture.fetcher.callCount == 0)
    }
  }

  /// A Keychain store on a test-only service. The item is deleted on both ends.
  private static func makeStore() -> KeychainStore {
    let store = KeychainStore(service: storeService, account: "api-key")
    try? store.delete()
    return store
  }
}
