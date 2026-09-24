// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import Testing

@testable import DeepTallyCore

// Tests use only service names under this test prefix, never the shipped one, and delete the item on
// both ends, so a run never leaves a test key in the developer's Keychain.
private let storeService = "io.github.genoma.deeptally.tests.keychain-store"
private let sourceService = "io.github.genoma.deeptally.tests.api-key-source"
private let testAccount = "api-key"
private let fakeKey = "sk-test-not-a-real-key"
private let envKey = "sk-test-not-a-real-env-key"

/// Records what an injected `ShellRunner` was asked to do, so a test can prove the built-in
/// login-shell process never ran. `@unchecked Sendable` is safe here: only the thread that called
/// the runner reads the recorder.
private final class RunnerRecorder: @unchecked Sendable {
  private(set) var calls: [(shell: ShellKind, timeout: TimeInterval)] = []

  func record(_ shell: ShellKind, _ timeout: TimeInterval) {
    calls.append((shell, timeout))
  }
}

@Suite("Keychain store")
final class KeychainStoreTests: Sendable {
  private let store: KeychainStore

  init() throws {
    // Swift Testing runs tests in parallel, and two threads sharing one Keychain record fail with
    // transient `errSecDuplicateItem`/`errSecInvalidRecord` errors — so every test case owns an item.
    store = KeychainStore(service: "\(storeService).\(UUID().uuidString)", account: testAccount)
    try store.delete()
  }

  deinit {
    try? store.delete()
  }

  @Test("store then read round-trips the secret")
  func roundTrip() throws {
    try store.store(fakeKey)
    #expect(try store.read() == fakeKey)
    #expect(store.hasItem())
  }

  @Test("reading a missing item returns nil")
  func missingItemReadsNil() throws {
    #expect(try store.read() == nil)
    #expect(!store.hasItem())
  }

  @Test("storing twice replaces the value")
  func storeReplaces() throws {
    try store.store(fakeKey)
    try store.store("sk-test-replaced")
    #expect(try store.read() == "sk-test-replaced")
  }

  @Test("surrounding whitespace is trimmed before the secret is stored")
  func storeTrims() throws {
    try store.store("  \(fakeKey)  ")
    #expect(try store.read() == fakeKey)
  }

  @Test("delete removes the item")
  func deleteRemoves() throws {
    try store.store(fakeKey)
    try store.delete()
    #expect(try store.read() == nil)
    #expect(!store.hasItem())
  }

  @Test("deleting a missing item is a no-op")
  func deleteMissingIsIdempotent() throws {
    try store.delete()
    #expect(!store.hasItem())
  }

  @Test(
    "unusable secrets are rejected",
    arguments: [
      "",
      "   ",
      "has\nnewline",
      "has\rreturn",
      String(repeating: "a", count: 300),
    ])
  func rejectsUnusableSecrets(secret: String) throws {
    #expect(throws: KeychainError.invalidSecret) { try store.store(secret) }
    #expect(!store.hasItem())
  }

  @Test("a rejected secret never appears in the error")
  func rejectedSecretStaysOutOfTheError() throws {
    let oversized = "sk-test-not-a-real-key-" + String(repeating: "x", count: 300)
    do {
      try store.store(oversized)
      Issue.record("expected the oversized secret to be rejected")
    } catch {
      #expect(error as? KeychainError == .invalidSecret)
      #expect(!String(describing: error).contains("sk-test"))
      #expect(!String(describing: error).contains(oversized))
    }
  }
}

@Suite("API key source")
final class APIKeySourceTests: Sendable {
  private let store: KeychainStore

  init() throws {
    // One Keychain record per test case; see `KeychainStoreTests.init`.
    store = KeychainStore(service: "\(sourceService).\(UUID().uuidString)", account: testAccount)
    try store.delete()
  }

  deinit {
    try? store.delete()
  }

  private func source(
    environment: [String: String] = [:],
    runner: APIKeySource.ShellRunner? = nil,
    keychainReader: APIKeySource.KeychainReader? = nil
  ) -> APIKeySource {
    APIKeySource(
      keychain: store,
      environment: environment,
      shellRunner: runner,
      keychainReader: keychainReader
    )
  }

  @Test("currentKey prefers the Keychain over the environment")
  func currentKeyPrefersKeychain() throws {
    try store.store(fakeKey)
    let source = source(environment: ["DEEPSEEK_API_KEY": envKey])
    #expect(try source.currentKey() == fakeKey)
  }

  @Test("currentKey falls back to the environment when the Keychain is empty")
  func currentKeyFallsBackToEnvironment() throws {
    let source = source(environment: ["DEEPSEEK_API_KEY": envKey])
    #expect(try source.currentKey() == envKey)
  }

  @Test("currentKey is nil when neither source has a key")
  func currentKeyIsNilWhenNeitherSourceHasOne() throws {
    let source = source()
    #expect(try source.currentKey() == nil)
  }

  @Test("currentKey falls back to the environment when the Keychain read itself fails")
  func currentKeyUsesEnvironmentAfterKeychainFailure() throws {
    let source = source(
      environment: ["DEEPSEEK_API_KEY": envKey],
      keychainReader: { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) })

    #expect(try source.currentKey() == envKey)
  }

  @Test("resolve() reports the Keychain, the key and no problem when an item exists")
  func resolvePrefersKeychain() throws {
    try store.store(fakeKey)

    let resolution = source(environment: ["DEEPSEEK_API_KEY": envKey]).resolve()

    #expect(resolution.origin == .keychain)
    #expect(resolution.key == fakeKey)
    #expect(resolution.keychainProblem == nil)
  }

  @Test("resolve() falls back to the environment when the Keychain is empty")
  func resolveFallsBackToEnvironment() {
    let resolution = source(environment: ["DEEPSEEK_API_KEY": envKey]).resolve()

    #expect(resolution.origin == .environment)
    #expect(resolution.key == envKey)
    #expect(resolution.keychainProblem == nil)
  }

  /// The finding this covers: a Keychain read error used to be rethrown, so a valid `DEEPSEEK_API_KEY`
  /// was never consulted and the app reported "unreadable" while a usable key sat right there.
  @Test("a failed Keychain read still uses DEEPSEEK_API_KEY and reports the failure")
  func resolveUsesEnvironmentAfterKeychainFailure() {
    let resolution = source(
      environment: ["DEEPSEEK_API_KEY": envKey],
      keychainReader: { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
    ).resolve()

    #expect(resolution.origin == .environment)
    #expect(resolution.key == envKey)
    let problem = resolution.keychainProblem
    #expect(problem != nil)
    // The diagnostic names the status and nothing that could be part of a secret.
    #expect(problem?.contains("\(errSecInteractionNotAllowed)") == true)
    #expect(problem?.contains(fakeKey) != true)
    #expect(problem?.contains(envKey) != true)
  }

  @Test("a denied item ACL reports the failure and no origin")
  func resolveReportsDeniedKeychainWithoutEnvironment() {
    let resolution = source(
      keychainReader: { throw KeychainError.unexpectedStatus(errSecAuthFailed) }
    ).resolve()

    #expect(resolution.origin == .none)
    #expect(resolution.key == nil)
    #expect(resolution.keychainProblem?.contains("\(errSecAuthFailed)") == true)
  }

  @Test("resolve() is .none with no problem when nothing has a key")
  func resolveWithoutAnyKey() {
    #expect(source().resolve() == KeyResolution(origin: .none, key: nil, keychainProblem: nil))
  }

  @Test("currentKey treats a blank environment value as absent")
  func currentKeyTreatsBlankEnvironmentAsAbsent() throws {
    let source = source(environment: ["DEEPSEEK_API_KEY": "   "])
    #expect(try source.currentKey() == nil)
  }

  @Test("currentKey never runs the shell")
  func currentKeyNeverShellsOut() throws {
    let recorder = RunnerRecorder()
    let source = source(
      environment: ["DEEPSEEK_API_KEY": envKey],
      runner: { shell, timeout in
        recorder.record(shell, timeout)
        return fakeKey
      })

    #expect(try source.currentKey() == envKey)
    #expect(recorder.calls.isEmpty)
  }

  @Test("importFromShell stores and returns the trimmed stdout")
  func importStoresAndReturnsTrimmedOutput() throws {
    let recorder = RunnerRecorder()
    let source = source(runner: { shell, timeout in
      recorder.record(shell, timeout)
      return "  \(fakeKey)\n"
    })

    // The injected runner is the only thing that can run: the built-in login shell would return the
    // developer's own key, or nothing, never this sentinel.
    let imported = try source.importFromShell(.zsh)

    #expect(imported == fakeKey)
    #expect(try store.read() == fakeKey)
    #expect(try source.currentKey() == fakeKey)
    #expect(recorder.calls.count == 1)
    #expect(recorder.calls.map(\.shell) == [.zsh])
    #expect(recorder.calls.map(\.timeout) == [8])
  }

  @Test("importFromShell forwards the chosen shell and timeout")
  func importForwardsShellAndTimeout() throws {
    let recorder = RunnerRecorder()
    let source = source(runner: { shell, timeout in
      recorder.record(shell, timeout)
      return fakeKey
    })

    _ = try source.importFromShell(.bash, timeout: 2.5)

    #expect(recorder.calls.count == 1)
    #expect(recorder.calls.map(\.shell) == [.bash])
    #expect(recorder.calls.map(\.timeout) == [2.5])
  }

  @Test("empty shell output is notFoundInShell", arguments: ["", "   \n"])
  func emptyShellOutputThrowsNotFound(output: String) throws {
    let source = source(runner: { _, _ in output })
    #expect(throws: KeyImportError.notFoundInShell) { try source.importFromShell(.zsh) }
    #expect(!store.hasItem())
  }

  @Test("a runner timeout surfaces as shellTimedOut")
  func runnerTimeoutSurfacesAsShellTimedOut() throws {
    let timeoutDouble: APIKeySource.ShellRunner = { _, _ in
      throw KeyImportError.shellTimedOut
    }
    let source = source(runner: timeoutDouble)
    #expect(throws: KeyImportError.shellTimedOut) { try source.importFromShell(.bash) }
    #expect(!store.hasItem())
  }

  @Test("an unstorable shell value never appears in the error")
  func importErrorStaysOutOfTheSecret() throws {
    let oversized = "sk-test-not-a-real-key-" + String(repeating: "y", count: 300)
    let source = source(runner: { _, _ in oversized })

    do {
      _ = try source.importFromShell(.zsh)
      Issue.record("expected the oversized shell value to be rejected")
    } catch {
      #expect(error as? KeyImportError == .emptySecret)
      #expect(!String(describing: error).contains("sk-test"))
      #expect(!String(describing: error).contains(oversized))
    }
    #expect(!store.hasItem())
  }

  @Test("deleteKey removes the stored key")
  func deleteKeyRemovesTheStoredKey() throws {
    try store.store(fakeKey)
    let source = source()
    try source.deleteKey()
    #expect(try source.currentKey() == nil)
  }

  @Test("the built-in runner is a login shell that never puts the key on a command line")
  func builtInRunnerShape() {
    #expect(ShellKind.zsh.executablePath == "/bin/zsh")
    #expect(ShellKind.bash.executablePath == "/bin/bash")
    #expect(ShellKind.zsh.importArguments == ["-lic", "printenv DEEPSEEK_API_KEY"])
    #expect(ShellKind.bash.importArguments == ["-lic", "printenv DEEPSEEK_API_KEY"])
  }
}
