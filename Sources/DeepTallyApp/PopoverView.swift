// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// The popover: notices, the balance, what the account is paying right now, the login item, the
/// settings and the way out.
///
/// Fixed at 320pt wide with 14pt padding, and the content scrolls: the settings block is taller than
/// any sane menu bar window, and a popover that grows to fit it would run off the bottom of the
/// screen. The sections themselves own their internal layout — this file only places them.
struct PopoverView: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 14) {
        bannerStack
        BalanceSection(state: model.balanceState, isLoading: model.isRefreshing) {
          model.refresh()
        }
        Divider()
        RateNowPanel(display: model.rateNow)
        Divider()
        LocalUsageSection(
          analytics: model.localUsageAnalytics,
          currency: model.ledgerCurrencyCode,
          isRefreshing: model.isLocalUsageRefreshing,
          note: model.localUsageNote,
          onRefresh: { model.refreshLocalUsage() })
        Divider()
        LedgerTransferSection(
          isTransferring: model.isTransferringLedger,
          message: model.ledgerTransferMessage,
          onExport: { model.exportLedger() },
          onImport: { model.importLedger() })
        Divider()
        startupSection
        Divider()
        settingsSection
        Divider()
        footer
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 320, height: 420)
  }

  // MARK: - Notices

  /// A translocation warning or a broken price table changes how everything below should be read, so
  /// the banners sit on top. Nothing is drawn at all while there is nothing to say.
  @ViewBuilder private var bannerStack: some View {
    if !model.banners.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(model.banners) { banner in
          StatusBanner(kind: banner.kind, message: banner.message)
        }
      }
    }
  }

  // MARK: - Login item

  /// The login item is a macOS registration, not a stored preference, so it has its own row outside
  /// `SettingsPanel` and its own status line: a toggle alone cannot say "waiting for approval".
  private var startupSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Startup")
        .font(.caption)
        .foregroundStyle(.secondary)

      Toggle("Launch at login", isOn: launchAtLogin)
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.isTranslocated)
        .help(
          model.isTranslocated
            ? "Not available while DeepTally runs from a temporary copy."
            : "Register DeepTally as a login item with macOS."
        )
        .accessibilityLabel("Launch DeepTally at login")

      if let note = model.loginItemStatusNote {
        Text(note)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The toggle reads from the registration status and writes by registering or unregistering, so the
  /// row can never show "on" for something macOS did not accept.
  private var launchAtLogin: Binding<Bool> {
    Binding(
      get: { model.launchAtLoginEnabled },
      set: { model.setLaunchAtLogin($0) }
    )
  }

  // MARK: - Settings

  private var settingsSection: some View {
    SettingsPanel(
      settings: $model.settings,
      isImportingKey: model.isImportingKey,
      importMessage: model.importMessage,
      alertsUnavailable: model.alertsUnavailable,
      onImportFromShell: { model.importKey(from: $0) },
      onDeleteKey: { model.deleteKey() }
    )
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        Text("DeepTally \(DeepTallyVersion.current)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Text("local-only").font(.caption2).foregroundStyle(.secondary)
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.link)
          .font(.caption2)
          .help("Quit DeepTally (⌘Q)")
      }
      HStack(spacing: 12) {
        // Which store supplies the key, never the key. Worth a line: an environment key works now and
        // stops working in the next terminal (see docs/USAGE.md).
        Text(model.keyOriginLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button("Uninstall DeepTally…") { confirmUninstall() }
          .buttonStyle(.link)
          .font(.caption2)
          .disabled(model.isTransferringLedger)
          .help(
            model.isTransferringLedger
              ? "A CSV transfer is in progress; the ledger cannot be removed until it finishes."
              : "Remove DeepTally, its ledger, its caches, its preferences and the Keychain item."
          )
      }
    }
  }

  // MARK: - Uninstall

  /// The confirmation, and the only place the popover decides anything about the removal: the alert
  /// lists what the uninstaller would remove, and the model does the work.
  ///
  /// *Export CSV First…* writes the ledger where the user chooses and then continues with the
  /// uninstall, which is the whole point of offering it here: the ledger is the one file that cannot
  /// be recreated later.
  private func confirmUninstall() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Uninstall DeepTally?"
    alert.informativeText = model.uninstallPlanText
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Export CSV First…")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      uninstallAndReport()
    case .alertSecondButtonReturn:
      // The export runs in the model's own task, so the continuation is a task too; a cancelled
      // save panel or a failed write ends here, with the ledger still in place.
      Task { @MainActor in
        guard await model.exportLedgerThenUninstall() else { return }
        uninstallAndReport()
      }
    default:
      break
    }
  }

  /// Runs the uninstall and reports it. When everything was removed the bundle is already in the
  /// Trash, so the only button offered is the one that ends the process; a refusal or a failure
  /// leaves the app where it is and says so.
  private func uninstallAndReport() {
    model.uninstall()
    guard let report = model.uninstallReport else { return }
    let alert = NSAlert()
    alert.messageText =
      report.isComplete ? "DeepTally has been uninstalled" : "DeepTally was not fully removed"
    alert.informativeText = report.text
    if report.isComplete {
      alert.addButton(withTitle: "Quit DeepTally")
      alert.runModal()
      NSApplication.shared.terminate(nil)
    } else {
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }
}

enum DeepTallyVersion {
  static let current =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
