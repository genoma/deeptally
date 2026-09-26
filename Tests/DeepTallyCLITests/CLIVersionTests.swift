// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import deeptally

/// The CLI's reported version comes from the resource bundle that ships beside it, which
/// `Scripts/release-assets.sh` stamps with the release version. These tests pin both halves of that
/// contract: a stamped bundle is read (including through a Homebrew-style symlink), and a development
/// build falls back to `dev` instead of inventing a version.
@Suite("CLI version resolution")
struct CLIVersionTests {
  @Test("a resource bundle stamped with a version is what the CLI reports")
  func stampedBundleIsRead() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try writeCoreBundle(in: directory, version: "9.9.9")
    let executable = directory.appendingPathComponent("deeptally")
    try Data().write(to: executable)

    #expect(CLIVersion.resolve(executableURL: executable) == "9.9.9")
  }

  @Test("a Homebrew-style symlink is resolved before the bundle is looked for")
  func symlinkedExecutableResolvesToTheRealDirectory() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let realDirectory = directory.appendingPathComponent("libexec")
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    _ = try writeCoreBundle(in: realDirectory, version: "1.2.3")
    let realExecutable = realDirectory.appendingPathComponent("deeptally")
    try Data().write(to: realExecutable)

    let binDirectory = directory.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let symlink = binDirectory.appendingPathComponent("deeptally")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realExecutable)

    #expect(CLIVersion.resolve(executableURL: symlink) == "1.2.3")
  }

  @Test("a bundle without the key and a missing bundle both report dev")
  func developmentBuildsReportDev() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try writeCoreBundle(in: directory, version: nil)
    let executable = directory.appendingPathComponent("deeptally")
    try Data().write(to: executable)
    #expect(CLIVersion.resolve(executableURL: executable) == "dev")

    let emptyDirectory = directory.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
    let lonelyExecutable = emptyDirectory.appendingPathComponent("deeptally")
    try Data().write(to: lonelyExecutable)
    #expect(CLIVersion.resolve(executableURL: lonelyExecutable) == "dev")

    #expect(CLIVersion.resolve(executableURL: nil) == "dev")
  }

  // MARK: - Fixtures

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("deeptally-version-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Writes `DeepTally_DeepTallyCore.bundle/Contents/Info.plist`, with or without the version key —
  /// the same shape SwiftPM builds and the release script stages.
  @discardableResult
  private func writeCoreBundle(in directory: URL, version: String?) throws -> URL {
    let bundle = directory.appendingPathComponent(CLIVersion.bundleName)
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = version.map { ["CFBundleShortVersionString": $0] } ?? [:]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return bundle
  }
}
