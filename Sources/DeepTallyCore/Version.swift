// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The release version the CLI reports.
///
/// The value travels as a resource file, not as a compiled constant: `Bundle.module` already finds the
/// price table and holiday calendar in every build — development, tarball and Homebrew `libexec` — so the
/// same lookup works for the version. `Scripts/release-assets.sh` overwrites the staged bundle's copy
/// with the version being released and refuses to publish a tarball whose CLI reports anything else;
/// a development build reads the checked-in `dev`.
public enum CoreVersion {
  /// The stamped release version, or `dev` when no release pipeline stamped the bundle.
  public static let release: String = {
    guard let url = Bundle.module.url(forResource: "Version", withExtension: "txt"),
      let data = try? Data(contentsOf: url),
      let raw = String(data: data, encoding: .utf8)
    else { return "dev" }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "dev" : trimmed
  }()
}
