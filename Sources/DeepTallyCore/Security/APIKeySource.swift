// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Which login shell ran the one-time import. Chosen explicitly by the user, never guessed, because
/// the rc file that exports `DEEPSEEK_API_KEY` differs per shell.
public enum ShellKind: String, Sendable, CaseIterable {
  case zsh
  case bash
}

extension ShellKind {
  /// The login binary. `-l` sources `~/.zprofile`/`~/.bash_profile`, `-i` sources
  /// `~/.zshrc`/`~/.bashrc`; together they cover where the key is usually exported.
  var executablePath: String {
    switch self {
    case .zsh: "/bin/zsh"
    case .bash: "/bin/bash"
    }
  }

  /// The argv for the import. The secret is never an argument: the shell prints it and we read
  /// stdout, so it cannot appear in a process listing.
  var importArguments: [String] { ["-lic", "printenv DEEPSEEK_API_KEY"] }
}

/// Why a one-time shell import failed. No case carries the secret or any shell output.
public enum KeyImportError: Error, Sendable, Equatable {
  /// The login shell produced no output at all — the variable is not exported.
  case notFoundInShell
  /// The shell printed something that cannot be a usable secret: whitespace, or a value
  /// `KeychainStore` rejects (for example an rc file that echoed more than `printenv` did).
  case emptySecret
  /// The shell did not finish within the timeout and was terminated.
  case shellTimedOut
  /// The shell exited non-zero while still producing output.
  case shellFailed(Int32)
  /// Storing the imported secret failed; carries the raw Keychain status.
  case keychain(OSStatus)
}

/// Resolves the DeepSeek API key for a request: Keychain first, then the process environment.
///
/// A GUI-launched app inherits no shell environment (measured, docs/SPIKES.md), so the key is
/// imported once with `importFromShell` and read from the Keychain afterwards.
public struct APIKeySource: Sendable {
  /// Injection seam for tests: a non-nil runner replaces the real login-shell process entirely.
  public typealias ShellRunner = @Sendable (ShellKind, TimeInterval) throws -> String

  private let keychain: KeychainStore
  private let environment: [String: String]
  private let shellRunner: ShellRunner?

  public init(
    keychain: KeychainStore = KeychainStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    shellRunner: ShellRunner? = nil
  ) {
    self.keychain = keychain
    self.environment = environment
    self.shellRunner = shellRunner
  }

  /// The key to use for a request. Never runs a shell — importing is an explicit user action, and a
  /// GUI process cannot rely on `~/.zshrc` being read.
  public func currentKey() throws -> String? {
    if let stored = try keychain.read(),
      !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return stored
    }
    guard let raw = environment["DEEPSEEK_API_KEY"] else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// Imports the key from the user's login shell, stores it in the Keychain and returns it, so the
  /// next call needs no shell.
  ///
  /// Synchronous by contract: a caller on the main actor must wrap this in a detached task, because
  /// a shell can take up to `timeout`. The built-in runner never passes the key on a command line,
  /// never logs shell output and never includes either in an error.
  public func importFromShell(_ shell: ShellKind, timeout: TimeInterval = 8) throws -> String {
    let runner: ShellRunner =
      shellRunner ?? { shell, timeout in
        try Self.runLoginShell(shell, timeout: timeout)
      }
    let output = try runner(shell, timeout)
    let secret = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else { throw KeyImportError.notFoundInShell }
    do {
      try keychain.store(secret)
    } catch KeychainError.invalidSecret {
      throw KeyImportError.emptySecret
    } catch KeychainError.unexpectedStatus(let status) {
      throw KeyImportError.keychain(status)
    }
    return secret
  }

  /// Removes the stored key. Requests have no key again until the next import.
  public func deleteKey() throws {
    try keychain.delete()
  }

  // MARK: - Login shell

  /// Runs `/bin/zsh -lic 'printenv DEEPSEEK_API_KEY'` (or `/bin/bash` for bash) and returns raw
  /// stdout.
  ///
  /// The wait happens on the calling thread; a watchdog queue enforces `timeout` by terminating the
  /// shell, so a shell blocked on input cannot hang the app forever. A non-zero exit is only
  /// reported when output also appeared — `printenv` exits 1 for an unset variable, which is
  /// "not found", not a failure.
  private static func runLoginShell(_ shell: ShellKind, timeout: TimeInterval) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell.executablePath)
    process.arguments = shell.importArguments
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout

    do {
      try process.run()
    } catch {
      throw KeyImportError.shellFailed(-1)
    }

    let handle = ProcessHandle(process)
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      handle.process.waitUntilExit()
      exited.signal()
    }

    guard exited.wait(timeout: .now() + max(0, timeout)) == .success else {
      if handle.process.isRunning { handle.process.terminate() }
      if exited.wait(timeout: .now() + 1) == .timedOut {
        kill(handle.process.processIdentifier, SIGKILL)  // a login shell may trap SIGTERM
        _ = exited.wait(timeout: .now() + 1)
      }
      throw KeyImportError.shellTimedOut
    }

    let data = (try? stdout.fileHandleForReading.readToEnd()) ?? nil
    let output = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    if handle.process.terminationStatus != 0,
      !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw KeyImportError.shellFailed(handle.process.terminationStatus)
    }
    return output
  }
}

/// `Process` is not `Sendable`. After `run()` the watchdog and the waiter touch disjoint state
/// (`terminate()`/`terminationStatus` vs. `waitUntilExit()`), which is the documented way to use
/// `NSTask` across threads.
private final class ProcessHandle: @unchecked Sendable {
  let process: Process

  init(_ process: Process) {
    self.process = process
  }
}
