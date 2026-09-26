// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import UniformTypeIdentifiers

/// The two AppKit panels the popover uses to pick a CSV path, and the default file name.
///
/// Split out of `AppModel` so the model stays testable: a test drives `exportLedger(to:)` and
/// `importLedger(from:)` over paths it chose itself, and only these functions need a person in front
/// of them. Both panels are modal and run on the main actor, which is what a panel is.
@MainActor
enum LedgerPanels {
  /// A save panel restricted to CSV, with a dated default name.
  static func chooseExportURL(suggestedName: String) -> URL? {
    let panel = NSSavePanel()
    panel.title = "Export Usage as CSV"
    panel.nameFieldStringValue = suggestedName
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// An open panel restricted to CSV files, one at a time: importing two files into one ledger in a
  /// single gesture would make the reported row count ambiguous.
  static func chooseImportURL() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import Usage from CSV"
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// `DeepTally-usage-2026-09-26.csv`, dated in the user's own timezone: the name is for the person
  /// reading a folder, not for a UTC-stamped ledger. Injected clock so a test asserts the format
  /// without waiting for a day.
  static func suggestedExportName(now: Date = Date(), timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return "DeepTally-usage-\(formatter.string(from: now)).csv"
  }
}
