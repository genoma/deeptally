// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DeepTallyCore
import Foundation
import Synchronization

/// The one uninstaller, behind two entry points: the popover's *Uninstall DeepTally…* button and
/// `DeepTally --uninstall`, which `Scripts/uninstall.sh` calls.
///
/// It removes a fixed list and nothing else — never a path outside it, and never a whole directory
/// that holds anything the app does not own:
///
/// 1. the login item, unregistered through ``LoginItemControl`` (`SMAppService`);
/// 2. the API key, through ``KeychainStore``;
/// 3. `~/Library/Application Support/DeepTally` — the app's data directory, removed whole;
/// 4. the preferences domain `io.github.genoma.deeptally`;
/// 5. `~/Library/Caches/io.github.genoma.deeptally`;
/// 6. `~/Library/Saved Application State/io.github.genoma.deeptally.savedState`, when macOS wrote one;
/// 7. the app bundle itself, moved to the Trash so it stays recoverable.
///
/// Everything that leaves the process — the file manager, the login item, the Keychain, the
/// preferences daemon and the Trash move — is an injectable seam: the popover and `--uninstall` run
/// the shipping choices, while a test runs the whole plan against throwaway paths and never touches
/// the real Trash, Keychain or login item.
///
/// A step that fails does not stop the others. A locked Keychain item must not leave the app data
/// behind, and the report names what could not be done so the exit code is not the only signal.
@MainActor
struct Uninstaller {
  /// The bundle identifier, which is also the `UserDefaults` domain macOS stores this app's
  /// preferences under (`~/Library/Preferences/io.github.genoma.deeptally.plist`).
  static let preferencesDomain = "io.github.genoma.deeptally"

  // MARK: - Options

  /// What to remove, and where it lives.
  ///
  /// `home` and `bundleURL` are injected so a test — and the release gate — can run the whole plan
  /// against throwaway paths; the shipped defaults are this Mac's home and the running bundle.
  struct Options: Equatable, Sendable {
    var home: URL
    var bundleURL: URL
    /// `--trash-dir`: where the bundle goes. `nil` means the user's real Trash, through
    /// ``Uninstaller/moveToTrash(_:into:)``.
    var trashDirectory: URL?
    /// `--keep-data`: keep `~/Library/Application Support/DeepTally`, remove everything else.
    var keepsData = false
    /// `--keep-keychain`: keep the API key.
    var keepsKeychain = false
    /// `--keep-login-item`: leave the macOS login item registered. For the release gate on a
    /// developer's machine, where unregistering the real registration would be a side effect.
    var keepsLoginItem = false
    /// `--print-only`: report the plan and change nothing.
    var printOnly = false

    /// The shipped choices: this Mac's home, the bundle this process runs from and the user's Trash.
    static func shipping() -> Options {
      Options(
        home: FileManager.default.homeDirectoryForCurrentUser, bundleURL: Bundle.main.bundleURL)
    }

    /// `true` when the plan targets the home directory this process really lives in. Exactly one step
    /// cares — see ``Uninstaller/preferencesLine(performing:)``.
    var usesRealHome: Bool {
      home.standardizedFileURL.path
        == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }
  }

  // MARK: - Seams

  /// Every collaborator that leaves the process.
  struct Seams {
    var fileManager: FileManager = .default
    var loginItem: LoginItemControl = .system
    /// Existence only: `hasItem()` never reads the secret (AGENTS.md §5).
    var hasKeychainItem: @MainActor () -> Bool = { KeychainStore().hasItem() }
    /// Deleting an item that is not there is a no-op, not an error (``KeychainStore/delete()``).
    var deleteKeychainItem: @MainActor () throws -> Void = { try KeychainStore().delete() }
    /// Removes the preferences domain through `cfprefsd`, which is the only way to make the deletion
    /// stick for the domain this process owns (AGENTS.md §9.12).
    var removePreferencesDomain: @MainActor () -> Void = {
      UserDefaults.standard.removePersistentDomain(forName: Uninstaller.preferencesDomain)
    }
    /// Moves the bundle out of the way, returning where it went.
    var moveToTrash: @MainActor (_ url: URL, _ trashDirectory: URL?) throws -> URL =
      Uninstaller.moveToTrash

    /// The shipping seams for the app's own key and login item, so the popover's button and
    /// `--uninstall` act on exactly the item the app stored.
    static func shipping(loginItem: LoginItemControl, keychain: KeychainStore) -> Seams {
      var seams = Seams()
      seams.loginItem = loginItem
      seams.hasKeychainItem = { keychain.hasItem() }
      seams.deleteKeychainItem = { try keychain.delete() }
      return seams
    }
  }

  let options: Options
  let seams: Seams

  init(options: Options, seams: Seams = Seams()) {
    self.options = options
    self.seams = seams
  }

  /// The shipping uninstaller of a running app.
  static func shipping(loginItem: LoginItemControl, keychain: KeychainStore) -> Uninstaller {
    Uninstaller(options: .shipping(), seams: .shipping(loginItem: loginItem, keychain: keychain))
  }

  // MARK: - Running

  /// The plan without the work: what the confirmation alert lists and what `--print-only` prints.
  /// It answers "does this exist" for the fixed list and nothing more.
  func plan() -> Report { collect(performing: false) }

  /// Removes everything in the list, line by line. `--print-only` turns this into ``plan()``.
  func run() -> Report {
    options.printOnly ? plan() : collect(performing: true)
  }

  private func collect(performing: Bool) -> Report {
    Report(
      lines: [
        loginItemLine(performing: performing),
        apiKeyLine(performing: performing),
        appDataLine(performing: performing),
        preferencesLine(performing: performing),
        cachesLine(performing: performing),
        savedStateLine(performing: performing),
        appBundleLine(performing: performing),
      ],
      isPlan: !performing)
  }

  // MARK: - The items

  /// The login item macOS holds for this app. `notRegistered` and `notFound` both mean there is
  /// nothing to remove — `notFound` is what macOS reports when no item is registered for this
  /// bundle, and calling `unregister` then only collects an "Operation not permitted".
  private func loginItemLine(performing: Bool) -> Report.Line {
    let detail = "Launch at login (SMAppService)"
    guard !options.keepsLoginItem else {
      return Report.Line(
        status: .skipped, name: "login item", detail: detail, note: "kept: --keep-login-item")
    }
    switch seams.loginItem.status() {
    case .notRegistered, .notFound:
      return Report.Line(status: .absent, name: "login item", detail: detail)
    case .enabled, .requiresApproval, .unknown:
      guard performing else {
        return Report.Line(status: .planned, name: "login item", detail: detail)
      }
      do {
        try seams.loginItem.unregister()
        return Report.Line(status: .removed, name: "login item", detail: detail)
      } catch {
        // `LoginItem.describe` is the sentence the popover shows for a failed toggle: it names the
        // fallback in System Settings, which is exactly what a user needs after a refusal.
        return Report.Line(
          status: .failed, name: "login item", detail: detail,
          note: LoginItem.describe(error))
      }
    }
  }

  /// The Keychain item the app stores the key in. `hasItem()` answers existence without reading the
  /// secret, and `delete()` is still called when nothing was found: a locked keychain makes
  /// `hasItem()` report `false` while the item is really there, and that delete failure is the only
  /// way to learn it.
  private func apiKeyLine(performing: Bool) -> Report.Line {
    // The service is the bundle identifier, so the detail names the one item a user would find in
    // Keychain Access without spelling the account out a second time (``KeychainStore`` owns it).
    let detail = "Keychain item (service \(Self.preferencesDomain))"
    guard !options.keepsKeychain else {
      return Report.Line(
        status: .skipped, name: "API key", detail: detail, note: "kept: --keep-keychain")
    }
    let existed = seams.hasKeychainItem()
    guard performing else {
      return Report.Line(status: existed ? .planned : .absent, name: "API key", detail: detail)
    }
    do {
      try seams.deleteKeychainItem()
      return Report.Line(status: existed ? .removed : .absent, name: "API key", detail: detail)
    } catch {
      return Report.Line(
        status: .failed, name: "API key", detail: detail, note: Self.describe(error))
    }
  }

  /// The app data directory, removed whole: it holds the launch diagnostics, and one removal covers
  /// all of it without naming any file.
  private func appDataLine(performing: Bool) -> Report.Line {
    let url = appDataURL
    guard !options.keepsData else {
      return Report.Line(
        status: .skipped, name: "app data", detail: url.path, note: "kept: --keep-data")
    }
    return removeItem(named: "app data", at: url, performing: performing)
  }

  /// The preferences domain, removed through one of two mechanisms.
  ///
  /// With the real home this goes through `UserDefaults.removePersistentDomain`: deleting the plist
  /// file is not enough, because `cfprefsd` owns it and writes it straight back (AGENTS.md §9.12).
  /// With an injected `--home` — the tests and the release gate — there is no such domain in this
  /// process, so the plist under that home is deleted as a plain file.
  ///
  /// `removePersistentDomain` is also called when no plist file was found yet: the daemon may hold
  /// values it has not flushed, and a preference that outlives its uninstall is exactly the residue
  /// this step exists to prevent.
  private func preferencesLine(performing: Bool) -> Report.Line {
    let name = "preferences"
    if options.usesRealHome {
      let detail = "\(Self.preferencesDomain) (removePersistentDomain)"
      guard performing else {
        let existed = seams.fileManager.fileExists(atPath: preferencesPlistURL.path)
        return Report.Line(status: existed ? .planned : .absent, name: name, detail: detail)
      }
      seams.removePreferencesDomain()
      return Report.Line(status: .removed, name: name, detail: detail)
    }
    return removeItem(named: name, at: preferencesPlistURL, performing: performing)
  }

  private func cachesLine(performing: Bool) -> Report.Line {
    removeItem(named: "caches", at: cachesURL, performing: performing)
  }

  /// macOS's own window-state directory. It only exists if the app ever had a restorable window, so
  /// "absent" is the normal answer, not a problem.
  private func savedStateLine(performing: Bool) -> Report.Line {
    removeItem(named: "saved state", at: savedStateURL, performing: performing)
  }

  /// The bundle itself, moved rather than deleted so the user can change their mind in the Finder.
  ///
  /// Two refusals, both reported instead of attempted:
  /// - **App Translocation** (`/AppTranslocation/` in the path, the rule ``AppModel/isTranslocated``
  ///   uses): that path is a random read-only copy macOS made for this launch. Moving it is pointless
  ///   and would silently leave the real `DeepTally.app` where it was. The rest of the plan still
  ///   runs, so the data is gone either way; the run exits non-zero because the app was not removed.
  /// - **not an `.app`**: a bare `swift build` binary has no bundle to move, and moving the directory
  ///   that holds it would delete unrelated build products.
  private func appBundleLine(performing: Bool) -> Report.Line {
    let bundle = options.bundleURL
    let destination = options.trashDirectory?.path ?? "the Trash"
    guard bundle.pathExtension == "app" else {
      return Report.Line(
        status: .refused, name: "app bundle", detail: bundle.path,
        note: "not an app bundle; nothing was moved")
    }
    guard !bundle.path.contains("/AppTranslocation/") else {
      return Report.Line(
        status: .refused, name: "app bundle", detail: bundle.path,
        note:
          "running from a temporary read-only copy; move DeepTally to /Applications and run this "
          + "again")
    }
    let detail = "\(bundle.path) → \(destination)"
    guard performing else {
      return Report.Line(status: .planned, name: "app bundle", detail: detail)
    }
    do {
      let moved = try seams.moveToTrash(bundle, options.trashDirectory)
      return Report.Line(
        status: .trashed, name: "app bundle", detail: "\(bundle.path) → \(moved.path)")
    } catch {
      return Report.Line(
        status: .failed, name: "app bundle", detail: bundle.path, note: Self.describe(error))
    }
  }

  /// Removes one path, reporting which of the three things happened. `removeItem` is the only place
  /// a path is deleted, and it deletes exactly the path it was given.
  private func removeItem(named name: String, at url: URL, performing: Bool) -> Report.Line {
    guard seams.fileManager.fileExists(atPath: url.path) else {
      return Report.Line(status: .absent, name: name, detail: url.path)
    }
    guard performing else {
      return Report.Line(status: .planned, name: name, detail: url.path)
    }
    do {
      try seams.fileManager.removeItem(at: url)
      return Report.Line(status: .removed, name: name, detail: url.path)
    } catch {
      return Report.Line(
        status: .failed, name: name, detail: url.path, note: Self.describe(error))
    }
  }

  // MARK: - Paths

  private var applicationSupportURL: URL {
    options.home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
  }

  /// Everything the app owns under Application Support.
  private var appDataURL: URL {
    applicationSupportURL.appending(path: "DeepTally", directoryHint: .isDirectory)
  }

  private var preferencesPlistURL: URL {
    options.home
      .appending(path: "Library/Preferences", directoryHint: .isDirectory)
      .appending(path: "\(Self.preferencesDomain).plist")
  }

  private var cachesURL: URL {
    options.home
      .appending(path: "Library/Caches", directoryHint: .isDirectory)
      .appending(path: Self.preferencesDomain, directoryHint: .isDirectory)
  }

  private var savedStateURL: URL {
    options.home
      .appending(path: "Library/Saved Application State", directoryHint: .isDirectory)
      .appending(path: "\(Self.preferencesDomain).savedState", directoryHint: .isDirectory)
  }

  // MARK: - Moving the bundle

  /// The shipping Trash move: `NSWorkspace.recycle` prints for the real Trash, so the app stays
  /// recoverable through the Finder's "Put Back", or one `FileManager.moveItem` into the injected
  /// `--trash-dir`.
  ///
  /// `recycle` is asynchronous and — measured on this machine — calls its completion handler on the
  /// queue it was called from, which is the main queue here. A semaphore would deadlock on that same
  /// thread, so the run loop is pumped until the handler has run: the uninstaller is one-shot and has
  /// nothing else to do while it waits.
  static func moveToTrash(_ url: URL, into trashDirectory: URL?) throws -> URL {
    let manager = FileManager.default
    guard let trashDirectory else {
      let outcome = Mutex<Result<URL, any Error>?>(nil)
      NSWorkspace.shared.recycle([url]) { newURLs, error in
        outcome.withLock { value in
          if let moved = newURLs[url] {
            value = .success(moved)
          } else {
            value = .failure(error ?? UninstallError.notMoved)
          }
        }
      }
      let deadline = Date().addingTimeInterval(trashTimeout)
      while outcome.withLock({ $0 == nil }), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
      }
      guard let result = outcome.withLock({ $0 }) else { throw UninstallError.trashTimedOut }
      return try result.get()
    }
    // The injected directory stands in for the user's Trash in tests and in the release gate's
    // throwaway home; the real one always exists.
    try manager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
    let destination = trashDirectory.appending(path: url.lastPathComponent)
    try manager.moveItem(at: url, to: destination)
    return destination
  }

  /// How long `NSWorkspace.recycle` is given before the step is called a failure. Generous: the move
  /// is a rename inside the same volume and has never taken a noticeable fraction of this, and a
  /// failure reports rather than hangs.
  private static let trashTimeout: TimeInterval = 30

  /// One short phrase for a failure. A `KeychainError` is reduced to its status code — the bridged
  /// `NSError` description of it says nothing a user can act on, and no case carries the secret
  /// (AGENTS.md §5).
  private static func describe(_ error: any Error) -> String {
    if let keychainError = error as? KeychainError {
      switch keychainError {
      case .unexpectedStatus(let status): return "the Keychain reported status \(status)"
      case .invalidSecret: return "the stored value is not a usable key"
      }
    }
    let localized = (error as NSError).localizedDescription
    return localized.isEmpty ? String(describing: error) : localized
  }
}

/// The two failures the Trash move itself can have. Both are one sentence, so a report line never
/// carries an `NSError` dump.
enum UninstallError: LocalizedError {
  case notMoved
  case trashTimedOut

  var errorDescription: String? {
    switch self {
    case .notMoved: return "macOS did not move the app to the Trash."
    case .trashTimedOut: return "macOS did not finish moving the app to the Trash in time."
    }
  }
}

// MARK: - The report

extension Uninstaller {
  /// One run's outcome, line by line, plus the one-sentence summary.
  struct Report: Equatable, Sendable {
    /// What happened to one item, in the vocabulary the CLI prints.
    enum Status: String, Equatable, Sendable {
      case removed
      case trashed
      case planned
      case absent
      case skipped
      case refused
      case failed

      /// The item is gone because this run removed it.
      var isChange: Bool { self == .removed || self == .trashed }
      /// Something could not be done, which is what makes a run incomplete.
      var isBlocked: Bool { self == .failed || self == .refused }
    }

    struct Line: Equatable, Sendable {
      let status: Status
      /// The item's name. Stable across runs, so a test can name the item it is asserting about:
      /// `login item`, `API key`, `app data`, `preferences`, `caches`, `saved state`, `app bundle`.
      let name: String
      /// The path or identifier the item is, so a bug report says which file was meant.
      let detail: String
      /// Why this is not a removal: the flag that kept it, or the failure.
      var note: String?

      /// `removed  app data      /Users/…/Library/Application Support/DeepTally`
      var text: String {
        status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
          + name.padding(toLength: 12, withPad: " ", startingAt: 0)
          + detail
          + (note.map { " (\($0))" } ?? "")
      }
    }

    let lines: [Line]
    /// `true` for a `--print-only` report: nothing was attempted, so nothing was changed.
    let isPlan: Bool

    /// No step was refused or failed, so there is nothing left to remove.
    var isComplete: Bool { !lines.contains { $0.status.isBlocked } }

    var summary: String {
      let changed = lines.filter { $0.status.isChange }.count
      let blocked = lines.filter { $0.status.isBlocked }.count
      let kept = lines.filter { $0.status == .skipped }.count
      if isPlan {
        let planned = lines.filter { $0.status == .planned }.count
        return "Plan only: \(planned) \(Self.noun(planned)) would be removed, nothing was changed."
      }
      guard blocked == 0 else {
        return "DeepTally is not fully removed: \(changed) \(Self.noun(changed)) removed, "
          + "\(blocked) refused or failed."
      }
      var sentence = "DeepTally is uninstalled: \(changed) \(Self.noun(changed)) removed."
      if kept > 0 { sentence += " \(kept) \(Self.noun(kept)) kept as requested." }
      return sentence
    }

    /// Every line and the summary. What `--uninstall` prints and what the popover's closing alert
    /// shows.
    var text: String { (lines.map(\.text) + [summary]).joined(separator: "\n") }

    /// The plan as the confirmation alert shows it: one bullet per item that would actually change,
    /// then what is not kept. Built from the same lines the run produces, so the alert cannot promise
    /// something the uninstaller does not do.
    var confirmationText: String {
      let kept = lines.filter { $0.status == .skipped }
      let bullets = lines.filter { $0.status != .absent }.map { line in
        "• \(line.name): \(line.detail)" + (line.note.map { " (\($0))" } ?? "")
      }
      let closing =
        kept.isEmpty
        ? "Nothing is kept."
        : "Kept as requested: \(kept.map(\.name).joined(separator: ", "))."
      return (bullets + ["", closing]).joined(separator: "\n")
    }

    private static func noun(_ count: Int) -> String { count == 1 ? "item" : "items" }
  }
}
