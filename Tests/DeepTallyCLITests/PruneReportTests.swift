// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import deeptally

/// `deeptally ledger prune` says what actually happens. The rollups are kept **and read**: `deeptally
/// usage` still reports the pruned days, but as whole UTC days, so a window that only partly covers one
/// cannot use it — and a reprice, which reads raw rows, can no longer revise them. The old wording ("the
/// daily rollups were kept") promised totals the CLI did not show, and the wording before this one said
/// the range was gone, which the rollup reader made false.
@Suite("Prune report")
struct PruneReportTests {
  @Test("the report says usage still shows the pruned days, as whole UTC days")
  func honestReport() {
    let report = CLI.pruneReport(removed: 3, days: 400)

    #expect(report.contains("Pruned 3 raw rows older than 400 days"))
    #expect(report.contains("still reports those days' aggregate"))
    #expect(report.contains("read from the daily rollups as whole UTC days"))
    #expect(report.contains("`ledger reprice` can no longer revise pruned rows"))
    #expect(!report.contains("no longer appears in"))
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
    let help = unwrapped(CLI.usageText)

    #expect(
      help.contains("still reports those days, read from the daily rollups as whole UTC days"))
    #expect(help.contains("a reprice can no longer revise pruned rows"))
    #expect(!help.contains("no longer appears in"))
    #expect(!help.contains("(the rollups are kept)"))
  }

  /// The help text with every run of whitespace collapsed to one space, so an assertion is about the
  /// words and not about where the 100-column wrap happens to fall.
  private func unwrapped(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }
}
