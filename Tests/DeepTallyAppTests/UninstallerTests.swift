// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyApp

/// The uninstaller, run against throwaway state only: a temporary home, a temporary bundle, a
/// temporary Trash and stubs for the two items that are not files (the login item and the Keychain
/// item). No test here touches this Mac's real Trash, Keychain or login item.
@Suite("Uninstaller", .serialized)
@MainActor
struct UninstallerTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.uninstall"

  /// The seven items the plan names, in the order it removes them.
  private static let itemNames = [
    "login item", "API key", "app data", "preferences", "caches", "saved state", "app bundle",
  ]

  // MARK: - The whole plan

  @Test("the plan removes every item, keeps every sibling, and names each item in the report")
  func fullPlanRemovesExactlyTheList() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }
    let loginItem = LoginItemStub()
    loginItem.status = .enabled
    let keychain = StubKeychainItem(isPresent: true)

    let report = makeUninstaller(scenery, loginItem: loginItem, keychain: keychain).run()

    #expect(report.isComplete)
    #expect(report.summary == "DeepTally is uninstalled: 7 items removed.")
    #expect(report.lines.map(\.name) == Self.itemNames)
    // Every item gone...
    for url in scenery.removedItems {
      #expect(!FileManager.default.fileExists(atPath: url.path), "still there: \(url.path)")
    }
    // ... the sibling next to each of them untouched...
    for url in scenery.siblings {
      #expect(FileManager.default.fileExists(atPath: url.path), "removed a sibling: \(url.path)")
    }
    // ... and the app itself recoverable, in the Trash this run was pointed at.
    #expect(report.lines[6].status == .trashed)
    #expect(
      report.lines[6].detail.hasSuffix("→ \(scenery.trash.appending(path: "DeepTally.app").path)"))
    #expect(
      FileManager.default.fileExists(
        atPath: scenery.trash.appending(path: "DeepTally.app").path))
    // The two items that are not files were acted on through their seams.
    #expect(loginItem.unregistrations == 1)
    #expect(keychain.deletes == 1)
    #expect(report.lines[0].status == .removed)
    #expect(report.lines[1].status == .removed)
  }

  @Test("the report names each path, so a bug report says which file was meant")
  func reportNamesEveryPath() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }

    let report = makeUninstaller(scenery).run()

    for path in [
      scenery.appSupport.path, scenery.preferences.path, scenery.caches.path,
      scenery.savedState.path, scenery.bundle.path,
    ] {
      #expect(report.text.contains(path), "the report never names \(path)")
    }
    for name in Self.itemNames {
      #expect(report.text.contains(name), "the report never names \(name)")
    }
  }

  // MARK: - The flags

  @Test("--keep-data keeps the ledger and the logs, and still removes preferences and caches")
  func keepDataKeepsTheLedger() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }

    let report = makeUninstaller(scenery, keepsData: true).run()

    #expect(FileManager.default.fileExists(atPath: scenery.ledger.path))
    #expect(
      FileManager.default.fileExists(atPath: scenery.appSupport.appending(path: "launch.log").path))
    #expect(!FileManager.default.fileExists(atPath: scenery.preferences.path))
    #expect(!FileManager.default.fileExists(atPath: scenery.caches.path))
    #expect(!FileManager.default.fileExists(atPath: scenery.savedState.path))
    let kept = try #require(report.lines.first { $0.name == "app data" })
    #expect(kept.status == .skipped)
    #expect(kept.note == "kept: --keep-data")
    #expect(
      report.summary == "DeepTally is uninstalled: 5 items removed. 1 item kept as requested.")
  }

  @Test("--keep-keychain leaves the key behind and removes everything else")
  func keepKeychainLeavesTheKey() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }
    let keychain = StubKeychainItem(isPresent: true)

    let report = makeUninstaller(scenery, keychain: keychain, keepsKeychain: true).run()

    #expect(keychain.isPresent)
    #expect(keychain.deletes == 0)
    #expect(!FileManager.default.fileExists(atPath: scenery.appSupport.path))
    let kept = try #require(report.lines.first { $0.name == "API key" })
    #expect(kept.status == .skipped)
    #expect(kept.note == "kept: --keep-keychain")
  }

  @Test("--keep-login-item leaves the registration alone and removes everything else")
  func keepLoginItemLeavesTheRegistration() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }
    let loginItem = LoginItemStub()
    loginItem.status = .enabled
    let keychain = StubKeychainItem(isPresent: true)

    let report = makeUninstaller(
      scenery, loginItem: loginItem, keychain: keychain, keepsLoginItem: true
    ).run()

    // The release gate runs this on a machine whose login item must survive.
    #expect(loginItem.unregistrations == 0)
    #expect(loginItem.status == .enabled)
    let kept = try #require(report.lines.first { $0.name == "login item" })
    #expect(kept.status == .skipped)
    #expect(kept.note == "kept: --keep-login-item")
    // Everything else still goes, including the items the other keep flags guard.
    #expect(keychain.deletes == 1)
    for url in scenery.removedItems {
      #expect(!FileManager.default.fileExists(atPath: url.path), "still there: \(url.path)")
    }
    for url in scenery.siblings {
      #expect(FileManager.default.fileExists(atPath: url.path))
    }
    #expect(report.isComplete)
    #expect(
      report.summary == "DeepTally is uninstalled: 6 items removed. 1 item kept as requested.")
  }

  @Test("--print-only leaves everything in place and prints the plan")
  func printOnlyChangesNothing() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }
    let loginItem = LoginItemStub()
    loginItem.status = .enabled
    let keychain = StubKeychainItem(isPresent: true)

    let report = makeUninstaller(
      scenery, loginItem: loginItem, keychain: keychain, printOnly: true
    ).run()

    #expect(report.isPlan)
    #expect(report.lines.allSatisfy { $0.status == .planned })
    #expect(report.summary == "Plan only: 7 items would be removed, nothing was changed.")
    for url in scenery.removedItems {
      #expect(FileManager.default.fileExists(atPath: url.path), "was removed: \(url.path)")
    }
    #expect(keychain.deletes == 0)
    #expect(keychain.isPresent)
    #expect(report.text.contains("planned"))
  }

  @Test("an item that is already gone is absent, not a failure")
  func absentItemsAreNotFailures() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }
    // The saved state directory is macOS's own, and it may never have existed.
    try FileManager.default.removeItem(at: scenery.savedState)

    let report = makeUninstaller(scenery, keychain: StubKeychainItem(isPresent: false)).run()

    #expect(report.isComplete)
    #expect(report.lines.first { $0.name == "saved state" }?.status == .absent)
    #expect(report.lines.first { $0.name == "API key" }?.status == .absent)
    #expect(report.summary == "DeepTally is uninstalled: 4 items removed.")
  }

  // MARK: - Refusals

  @Test("a translocated bundle is refused while the data purge still happens")
  func translocatedBundleIsRefused() throws {
    // The rule the app already uses: a path under /AppTranslocation/ is a read-only copy macOS made
    // for this launch, so moving it would leave the real bundle where it was.
    let scenery = try UninstallScenery(bundleRelativePath: "AppTranslocation/ABC-123/DeepTally.app")
    defer { scenery.removeAll() }
    let loginItem = LoginItemStub()
    loginItem.status = .enabled

    let report = makeUninstaller(scenery, loginItem: loginItem).run()

    #expect(!report.isComplete)
    let bundle = try #require(report.lines.first { $0.name == "app bundle" })
    #expect(bundle.status == .refused)
    #expect(bundle.note?.contains("temporary read-only copy") == true)
    // The move did not happen...
    #expect(FileManager.default.fileExists(atPath: scenery.bundle.path))
    #expect(
      !FileManager.default.fileExists(atPath: scenery.trash.appending(path: "DeepTally.app").path))
    // ...but nothing else was spared.
    #expect(!FileManager.default.fileExists(atPath: scenery.appSupport.path))
    #expect(!FileManager.default.fileExists(atPath: scenery.caches.path))
    #expect(!FileManager.default.fileExists(atPath: scenery.preferences.path))
    #expect(
      report.summary == "DeepTally is not fully removed: 6 items removed, 1 refused or failed.")
  }

  @Test("a bare binary that is not an .app bundle is refused rather than moved")
  func nonBundleIsRefused() throws {
    let scenery = try UninstallScenery(bundleRelativePath: "Applications/deeptally")
    defer { scenery.removeAll() }

    let report = makeUninstaller(scenery).run()

    let bundle = try #require(report.lines.first { $0.name == "app bundle" })
    #expect(bundle.status == .refused)
    #expect(bundle.note?.contains("not an app bundle") == true)
    #expect(FileManager.default.fileExists(atPath: scenery.bundle.path))
    #expect(!FileManager.default.fileExists(atPath: scenery.appSupport.path))
  }

  @Test("a failed Keychain delete does not stop the rest of the plan")
  func failedStepDoesNotStopTheOthers() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }
    let keychain = StubKeychainItem(isPresent: true)
    keychain.deleteFailure = KeychainErrorStub()

    let report = makeUninstaller(scenery, keychain: keychain).run()

    #expect(!report.isComplete)
    #expect(report.lines.first { $0.name == "API key" }?.status == .failed)
    #expect(report.lines.filter { $0.status == .removed }.count == 4)
    #expect(report.lines.first { $0.name == "app bundle" }?.status == .trashed)
    #expect(!FileManager.default.fileExists(atPath: scenery.appSupport.path))
    #expect(!FileManager.default.fileExists(atPath: scenery.bundle.path))
  }

  // MARK: - The command

  @Test("the command parses every documented flag, and refuses anything else")
  func commandParsesFlags() throws {
    let scenario = Uninstaller.Options(
      home: URL(fileURLWithPath: "/tmp/deeptally-home"),
      bundleURL: URL(fileURLWithPath: "/tmp/deeptally-home/Applications/DeepTally.app"),
      trashDirectory: URL(fileURLWithPath: "/tmp/deeptally-home/Trash"))

    let invocation = try UninstallCommand.parse(
      [
        "--yes", "--keep-data", "--keep-keychain", "--keep-login-item", "--print-only",
        "--home", "/tmp/other-home", "--trash-dir", "/tmp/other-trash",
      ],
      base: scenario)
    guard case .run(let options) = invocation else {
      Issue.record("expected a run invocation, got \(invocation)")
      return
    }
    #expect(options.printOnly)
    #expect(options.keepsData)
    #expect(options.keepsKeychain)
    #expect(options.keepsLoginItem)
    #expect(options.home.path == "/tmp/other-home")
    #expect(options.trashDirectory?.path == "/tmp/other-trash")
    // Without the two path flags the base is used unchanged.
    guard case .run(let inherited) = try UninstallCommand.parse(["--yes"], base: scenario) else {
      Issue.record("expected a run invocation")
      return
    }
    #expect(inherited == scenario)

    #expect(throws: UninstallCommand.ParseError.unknownFlag("--bogus")) {
      try UninstallCommand.parse(["--bogus"])
    }
    #expect(throws: UninstallCommand.ParseError.missingValue("--home")) {
      try UninstallCommand.parse(["--home"])
    }
    // Another flag is not a path: `--home --print-only` must not delete anything under a directory
    // called `--print-only`.
    #expect(throws: UninstallCommand.ParseError.missingValue("--home")) {
      try UninstallCommand.parse(["--home", "--print-only"])
    }
    #expect(throws: UninstallCommand.ParseError.missingValue("--trash-dir")) {
      try UninstallCommand.parse(["--trash-dir"])
    }
  }

  @Test("--help exits 0 and names every flag; an unknown flag exits 2")
  func helpAndUsageErrors() throws {
    for flag in [
      "--yes", "--print-only", "--home", "--keep-data", "--keep-keychain", "--keep-login-item",
      "--trash-dir", "--help",
    ] {
      #expect(UninstallCommand.helpText.contains(flag), "the help never names \(flag)")
    }
    #expect(try UninstallCommand.parse(["--help"]) == .help)
    #expect(UninstallCommand.run(["--help"]) == 0)
    #expect(UninstallCommand.run(["--bogus"]) == 2)
    #expect(UninstallCommand.run(["--home"]) == 2)
  }

  @Test("the command removes a throwaway home end to end, and --print-only does not")
  func commandRunsThePlan() throws {
    let scenery = try UninstallScenery()
    defer { scenery.removeAll() }
    let seams = makeSeams()

    // --print-only first: the same invocation that follows must still find everything.
    let planned = UninstallCommand.run(
      ["--print-only", "--home", scenery.home.path, "--trash-dir", scenery.trash.path],
      base: scenery.options(),
      seams: seams)
    #expect(planned == 0)
    for url in scenery.removedItems {
      #expect(FileManager.default.fileExists(atPath: url.path))
    }

    let removed = UninstallCommand.run(
      ["--yes", "--home", scenery.home.path, "--trash-dir", scenery.trash.path],
      base: scenery.options(),
      seams: seams)
    #expect(removed == 0)
    for url in scenery.removedItems {
      #expect(!FileManager.default.fileExists(atPath: url.path), "still there: \(url.path)")
    }
    for url in scenery.siblings {
      #expect(FileManager.default.fileExists(atPath: url.path))
    }
  }

  @Test("the command exits 1 when the app cannot be moved, and 0 for the plan that says so")
  func commandExitCodeForRefusal() throws {
    let scenery = try UninstallScenery(bundleRelativePath: "AppTranslocation/ABC-123/DeepTally.app")
    defer { scenery.removeAll() }
    let seams = makeSeams()

    #expect(UninstallCommand.run(["--print-only"], base: scenery.options(), seams: seams) == 0)
    #expect(UninstallCommand.run(["--yes"], base: scenery.options(), seams: seams) == 1)
    #expect(!FileManager.default.fileExists(atPath: scenery.appSupport.path))
  }

  // MARK: - The model

  @Test("the model reports a successful uninstall, using no real Trash, Keychain or login item")
  func modelReportsSuccess() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let scenery = try UninstallScenery()
      defer { scenery.removeAll() }
      let loginItem = LoginItemStub()
      loginItem.status = .enabled
      let keychain = StubKeychainItem(isPresent: true)
      let fixture = makeFixture(
        defaults: defaults,
        uninstaller: makeUninstaller(scenery, loginItem: loginItem, keychain: keychain))

      // What the confirmation alert would list.
      #expect(fixture.model.uninstallPlanText.contains(scenery.bundle.path))
      #expect(fixture.model.uninstallPlanText.contains("Export CSV First…"))

      fixture.model.uninstall()

      let report = try #require(fixture.model.uninstallReport)
      #expect(report.isComplete)
      #expect(loginItem.unregistrations == 1)
      #expect(keychain.deletes == 1)
      #expect(!FileManager.default.fileExists(atPath: scenery.appSupport.path))
      #expect(!FileManager.default.fileExists(atPath: scenery.bundle.path))
    }
  }

  @Test("the model removes nothing while a CSV transfer is in flight")
  func modelWaitsForTheTransfer() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let scenery = try UninstallScenery()
      defer { scenery.removeAll() }
      let fixture = makeFixture(
        defaults: defaults, uninstaller: makeUninstaller(scenery))
      let url = scenery.root.appending(path: "usage.csv")

      fixture.model.exportLedger(to: url)
      // The flag flips synchronously, so the click that follows cannot start a removal.
      #expect(fixture.model.isTransferringLedger)
      fixture.model.uninstall()
      #expect(fixture.model.uninstallReport == nil)

      await waitUntil("the export to finish") { !fixture.model.isTransferringLedger }
      #expect(FileManager.default.fileExists(atPath: scenery.appSupport.path))

      // And once the transfer is over the removal runs as usual.
      fixture.model.uninstall()
      #expect(fixture.model.uninstallReport?.isComplete == true)
      #expect(!FileManager.default.fileExists(atPath: scenery.appSupport.path))
    }
  }

  // MARK: - Helpers

  private func makeUninstaller(
    _ scenery: UninstallScenery,
    loginItem: LoginItemStub = LoginItemStub(),
    keychain: StubKeychainItem = StubKeychainItem(),
    printOnly: Bool = false,
    keepsData: Bool = false,
    keepsKeychain: Bool = false,
    keepsLoginItem: Bool = false
  ) -> Uninstaller {
    Uninstaller(
      options: scenery.options(
        printOnly: printOnly, keepsData: keepsData, keepsKeychain: keepsKeychain,
        keepsLoginItem: keepsLoginItem),
      seams: makeSeams(loginItem: loginItem, keychain: keychain))
  }

  /// The login item and the Keychain item as test doubles. The real ones act on this process and on
  /// this Mac, which no test may do.
  private func makeSeams(
    loginItem: LoginItemStub = LoginItemStub(),
    keychain: StubKeychainItem = StubKeychainItem()
  ) -> Uninstaller.Seams {
    var seams = Uninstaller.Seams()
    seams.loginItem = loginItem.control
    keychain.apply(to: &seams)
    return seams
  }
}

// MARK: - Fixtures

/// One throwaway home, app bundle and Trash, with every item the plan removes in place — and, beside
/// each of them, a sibling the run must never touch. `init` creates the whole tree; ``removeAll``
/// deletes it.
@MainActor
struct UninstallScenery {
  let root: URL
  let home: URL
  let bundle: URL
  let trash: URL
  let appSupport: URL
  let ledger: URL
  let preferences: URL
  let caches: URL
  let savedState: URL
  /// The paths the plan removes: the app-support directory (which holds the ledger, its side files
  /// and the Step 2 logs), the preferences plist, the caches, the saved state and the bundle.
  let removedItems: [URL]
  /// One unrelated sibling next to each removed item, at every level of the tree.
  let siblings: [URL]

  /// `bundleRelativePath` is the bundle's place inside the scenery: `Applications/DeepTally.app` for
  /// the normal case, an `/AppTranslocation/` path for the refusal, a bare binary for the other one.
  init(bundleRelativePath: String = "Applications/DeepTally.app") throws {
    let manager = FileManager.default
    root = manager.temporaryDirectory
      .appending(path: "deeptally-uninstall-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    bundle = root.appending(path: bundleRelativePath)
    trash = root.appending(path: "Trash", directoryHint: .isDirectory)
    appSupport = home.appending(
      path: "Library/Application Support/DeepTally", directoryHint: .isDirectory)
    ledger = appSupport.appending(path: "ledger.sqlite")
    preferences =
      home
      .appending(path: "Library/Preferences", directoryHint: .isDirectory)
      .appending(path: "io.github.genoma.deeptally.plist")
    caches =
      home
      .appending(path: "Library/Caches", directoryHint: .isDirectory)
      .appending(path: "io.github.genoma.deeptally", directoryHint: .isDirectory)
    savedState =
      home
      .appending(path: "Library/Saved Application State", directoryHint: .isDirectory)
      .appending(path: "io.github.genoma.deeptally.savedState", directoryHint: .isDirectory)

    removedItems = [appSupport, preferences, caches, savedState, bundle]
    siblings = [
      home.appending(path: "Library/Application Support/OtherApp/notes.txt"),
      home.appending(path: "Library/Preferences/other.plist"),
      home.appending(path: "Library/Caches/io.github.genoma.deeptally-cache/index.bin"),
      home.appending(
        path: "Library/Saved Application State/io.github.genoma.other.savedState/data.bin"),
      root.appending(path: "Applications/Other.app/Contents/Info.plist"),
    ]

    // Every item the plan removes, in the shape macOS would leave it: the ledger with its two side
    // files, the Step 2 logs and marker, a plist, two directories with content inside.
    try manager.createDirectory(at: appSupport, withIntermediateDirectories: true)
    for name in ["ledger.sqlite", "ledger.sqlite-wal", "ledger.sqlite-shm", "launch.log"] {
      try Data("x".utf8).write(to: appSupport.appending(path: name))
    }
    try Data("{}".utf8).write(to: appSupport.appending(path: "last-launch.json"))
    try Data("".utf8).write(to: appSupport.appending(path: "spike-enabled"))
    try manager.createDirectory(
      at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("plist".utf8).write(to: preferences)
    try manager.createDirectory(at: caches, withIntermediateDirectories: true)
    try Data("cache".utf8).write(to: caches.appending(path: "balance.json"))
    try manager.createDirectory(at: savedState, withIntermediateDirectories: true)
    try Data("state".utf8).write(to: savedState.appending(path: "windows.data"))
    try manager.createDirectory(
      at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
    try Data("plist".utf8).write(to: bundle.appending(path: "Contents/Info.plist"))
    try manager.createDirectory(at: trash, withIntermediateDirectories: true)
    for sibling in siblings {
      try manager.createDirectory(
        at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("keep me".utf8).write(to: sibling)
    }
  }

  /// The options a test runs with: this scenery's home, bundle and Trash, so nothing reaches the
  /// real ones.
  func options(
    printOnly: Bool = false, keepsData: Bool = false, keepsKeychain: Bool = false,
    keepsLoginItem: Bool = false
  ) -> Uninstaller.Options {
    Uninstaller.Options(
      home: home, bundleURL: bundle, trashDirectory: trash, keepsData: keepsData,
      keepsKeychain: keepsKeychain, keepsLoginItem: keepsLoginItem, printOnly: printOnly)
  }

  func removeAll() {
    try? FileManager.default.removeItem(at: root)
  }
}

/// The Keychain seam as a test double. No test in this suite opens a real Keychain item: existence
/// and the delete are recorded, never performed.
@MainActor
final class StubKeychainItem {
  private(set) var isPresent: Bool
  private(set) var deletes = 0
  /// When set, `deleteKeychainItem` throws it — the locked-keychain path.
  var deleteFailure: (any Error)?

  init(isPresent: Bool = true) {
    self.isPresent = isPresent
  }

  func apply(to seams: inout Uninstaller.Seams) {
    seams.hasKeychainItem = { [self] in isPresent }
    seams.deleteKeychainItem = { [self] in
      deletes += 1
      if let deleteFailure { throw deleteFailure }
      isPresent = false
    }
  }
}

/// A stand-in for a Keychain failure, so the failed-step test needs no real one.
struct KeychainErrorStub: Error {}
