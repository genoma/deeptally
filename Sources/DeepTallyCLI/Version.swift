// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The version the `deeptally` CLI reports.
///
/// The CLI is not a bundle, so there is no `Info.plist` of its own to read — but the resource bundle it
/// already needs for its price table and holiday calendar travels beside the binary in the release
/// tarball, and `Scripts/release-assets.sh` stamps the release version into that bundle. Reading it from
/// there makes the reported version impossible to drift from the tag: a release that forgot to stamp it
/// fails the release gate instead of shipping.
///
/// A development build (`swift run deeptally`, `swift test`) has no stamped bundle next to it and
/// reports `dev`.
enum CLIVersion {
  /// The SwiftPM resource bundle for `DeepTallyCore`, shipped at the archive root next to the binary.
  static let bundleName = "DeepTally_DeepTallyCore.bundle"

  /// The version for the process that is running.
  static let current = resolve(executableURL: Bundle.main.executableURL)

  /// Reads `CFBundleShortVersionString` from the resource bundle in the executable's directory.
  ///
  /// The executable path is resolved through symlinks first: Homebrew installs the real binary under
  /// `libexec` and puts a symlink on `PATH`, so the bundle lives beside the resolved file, not beside
  /// the path the user typed.
  static func resolve(executableURL: URL?, bundleName: String = CLIVersion.bundleName) -> String {
    guard let executableURL else { return "dev" }
    let bundleURL =
      executableURL
      .resolvingSymlinksInPath()
      .deletingLastPathComponent()
      .appendingPathComponent(bundleName, isDirectory: true)
    guard let bundle = Bundle(url: bundleURL),
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      !version.isEmpty
    else { return "dev" }
    return version
  }
}
