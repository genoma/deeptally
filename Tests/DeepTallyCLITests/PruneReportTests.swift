// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import deeptally

/// `deeptally ledger prune` says what actually happens. The rollups are kept but nothing reads them,
/// so the pruned range is gone from `deeptally usage` and a reprice can no longer revise it — the old
/// wording ("the daily rollups were kept") promised totals the CLI cannot show.
@Suite("Prune report")
struct PruneReportTests {
  @Test("the report states the three consequences and drops the old promise")
  func honestReport() {
    let report = CLI.pruneReport(removed: 3, days: 400)

    #expect(report.contains("Pruned 3 raw rows older than 400 days"))
    #expect(report.contains("no longer appears in `deeptally usage`"))
    #expect(report.contains("only its aggregate survives in the daily rollups"))
    #expect(report.contains("`ledger reprice` can no longer revise it"))
    #expect(!report.contains("rollups were kept"))
  }

  @Test("a prune that removes nothing claims nothing")
  func emptyPrune() {
    #expect(
      CLI.pruneReport(removed: 0, days: 30)
        == "Nothing older than 30 days to prune; the daily rollups are unchanged.")
  }

  @Test("the help text describes the same behaviour as the report")
  func helpTextMatchesTheReport() {
    #expect(CLI.usageText.contains("the pruned range's aggregate"))
    #expect(CLI.usageText.contains("a reprice can no longer revise it"))
    #expect(!CLI.usageText.contains("(the rollups are kept)"))
  }
}
