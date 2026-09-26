// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Optional launch diagnostics, used only while `spike-enabled` exists in the app-support directory.
/// The shipped app never writes this file: without the marker, `record()` returns immediately.
///
/// During Step 2 this is how we observe what macOS actually does with a quarantined vs. approved
/// bundle (bundle path, App Translocation, quarantine flag, whether the GUI process inherits
/// `DEEPSEEK_API_KEY` from a shell).
enum LaunchLog {
  static var directory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/DeepTally", directoryHint: .isDirectory)
  }

  static var markerURL: URL { directory.appending(path: "spike-enabled") }
  static var fileURL: URL { directory.appending(path: "launch.log") }

  static let maxLines = 200

  static func record() {
    let manager = FileManager.default
    guard manager.fileExists(atPath: markerURL.path) else { return }

    let snapshot = Spikes.identitySnapshot()
    let line = snapshot.keys.sorted()
      .map { "\($0)=\(snapshot[$0] ?? "")" }
      .joined(separator: " ")
    append(line)

    try? (line + "\n").write(
      to: directory.appending(path: "last-launch.json"), atomically: true, encoding: .utf8)
  }

  private static func append(_ line: String) {
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

    var lines =
      (try? String(contentsOf: fileURL, encoding: .utf8))?
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init) ?? []
    lines.append(line)
    if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    try? (lines.joined(separator: "\n") + "\n").write(
      to: fileURL, atomically: true, encoding: .utf8)
  }
}
