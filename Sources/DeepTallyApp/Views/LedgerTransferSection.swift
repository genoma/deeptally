// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The local-usage file exchange: export the ledger as CSV, or import a CSV this app or the
/// `deeptally` CLI wrote.
///
/// Deliberately its own section rather than more rows inside `SettingsPanel`: it is about the
/// ledger's data, it has its own progress state, and the analytics section above already carries the
/// quiet caveat line for local usage. The buttons only report taps — every path and every sentence
/// comes from `AppModel`.
struct LedgerTransferSection: View {
  let isTransferring: Bool
  let message: String?
  let onExport: () -> Void
  let onImport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Local usage file")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Button("Export CSV…") { onExport() }
          .controlSize(.small)
          .disabled(isTransferring)
          .accessibilityLabel("Export the ledger as a CSV file")
          .help("Write every stored row to a CSV file.")
        Button("Import CSV…") { onImport() }
          .controlSize(.small)
          .disabled(isTransferring)
          .accessibilityLabel("Import rows from a CSV file")
          .help("Add rows from a CSV written by DeepTally or the deeptally CLI.")
        if isTransferring {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Transferring the ledger")
        }
        Spacer(minLength: 8)
      }

      // Caller-supplied: an export or import report, or one sentence about why it failed. Never a
      // file's contents, which the ledger is not allowed to log (AGENTS.md §5).
      if let message {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("CSV transfer status")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// Previews use `PreviewProvider` rather than `#Preview`: the `#Preview` macro needs the
// `PreviewsMacros` plugin, which ships with Xcode and not with Command Line Tools (AGENTS.md §9.13).
struct LedgerTransferSectionPreviews: PreviewProvider {
  static var previews: some View {
    VStack(alignment: .leading, spacing: 20) {
      LedgerTransferSection(
        isTransferring: false,
        message: "Exported 5,275 rows to DeepTally-usage-2026-09-26.csv.",
        onExport: {},
        onImport: {})
      LedgerTransferSection(
        isTransferring: true,
        message: nil,
        onExport: {},
        onImport: {})
    }
    .padding(14)
    .frame(width: 320)
  }
}
