// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import DeepTallyCore

/// The version the CLI reports comes from a resource the release pipeline stamps. These tests pin the
/// half that lives in the source tree: the file ships, it is readable through `Bundle.module`, and a
/// development build therefore reports `dev` rather than a stale release number. The release half —
/// that `Scripts/release-assets.sh` overwrites the staged copy and refuses to publish a CLI reporting
/// anything else — is enforced by the release gate itself.
@Suite("Core version")
struct VersionTests {
  @Test("a development build reports dev, and never an empty string")
  func developmentBuildReportsDev() {
    #expect(CoreVersion.release == "dev")
  }
}
