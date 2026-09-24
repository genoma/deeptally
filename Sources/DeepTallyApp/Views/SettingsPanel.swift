// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import SwiftUI

/// Everything the user can change, as controls over the settings binding the owner supplies.
///
/// The panel writes only through `settings` and reports actions by calling the closures; it runs no
/// shell, opens no Keychain item and knows no key (AGENTS.md §5).
struct SettingsPanel: View {
  // Control bounds come straight from AppSettings, so the UI and the clamping cannot drift apart
  // while validated() stays the single enforcement point.

  @Binding private var settings: AppSettings
  private let isImportingKey: Bool
  private let importMessage: String?
  /// Alerts are switched on but macOS reports them denied: the one calm line that says so, and what
  /// carries a low balance instead.
  private let alertsUnavailable: Bool
  private let onImportFromShell: (ShellKind) -> Void
  private let onDeleteKey: () -> Void

  init(
    settings: Binding<AppSettings>,
    isImportingKey: Bool,
    importMessage: String?,
    alertsUnavailable: Bool = false,
    onImportFromShell: @escaping (ShellKind) -> Void,
    onDeleteKey: @escaping () -> Void
  ) {
    _settings = settings
    self.isImportingKey = isImportingKey
    self.importMessage = importMessage
    self.alertsUnavailable = alertsUnavailable
    self.onImportFromShell = onImportFromShell
    self.onDeleteKey = onDeleteKey
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Settings")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 8) {
        refreshRow
        thresholdRow
        metricRow
      }

      VStack(alignment: .leading, spacing: 8) {
        notificationsRow
        cooldownRow
        if alertsUnavailable {
          Text(Self.alertsUnavailableNote)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Low-balance alerts cannot be delivered")
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        keyRow
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Refresh, threshold, menu bar

  private var refreshRow: some View {
    labeledRow("Refresh every") {
      HStack(spacing: 6) {
        Text("\(settings.refreshIntervalMinutes) min")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Stepper("", value: $settings.refreshIntervalMinutes, in: AppSettings.refreshIntervalRange)
          .labelsHidden()
          .controlSize(.small)
          .accessibilityLabel("Refresh interval in minutes")
      }
    }
  }

  /// Money stays `Decimal` end to end: the field binds the value directly, and `AppSettings` clamps
  /// it when the settings are saved.
  private var thresholdRow: some View {
    labeledRow("Low-balance threshold") {
      TextField("", value: $settings.lowBalanceThreshold, format: .number)
        .textFieldStyle(.roundedBorder)
        .font(.caption.monospacedDigit())
        .multilineTextAlignment(.trailing)
        .frame(width: 68)
        .accessibilityLabel("Low-balance threshold in the account currency")
        .help("Compared with the account balance as reported — never converted.")
    }
  }

  /// Only the balance has a value to show: today's spend and the cache-hit rate need the ledger. They
  /// stay listed instead of disappearing, but disabled and labelled with what they wait for — a picker
  /// option that silently does nothing is worse than a disabled one that explains itself.
  private var metricRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      labeledRow("Menu bar") {
        Picker("Menu bar metric", selection: $settings.menuBarMetric) {
          ForEach(MenuBarMetric.allCases, id: \.self) { metric in
            Text(Self.label(for: metric))
              .tag(metric)
              .disabled(Self.needsLedger(metric))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Menu bar metric")
      }
      Text(Self.ledgerNote)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private static let ledgerNote = "Today's spend and cache-hit rate need the ledger (Step 4)."

  /// Which metrics have a number behind them. Only the balance does until Step 4 lands the ledger.
  private static func needsLedger(_ metric: MenuBarMetric) -> Bool {
    switch metric {
    case .balance: return false
    case .todaySpend, .cacheHitRate: return true
    }
  }

  private static func label(for metric: MenuBarMetric) -> String {
    switch metric {
    case .balance: return "Balance"
    case .todaySpend: return "Today's spend (Step 4)"
    case .cacheHitRate: return "Cache-hit rate (Step 4)"
    }
  }

  // MARK: - Notifications

  private var notificationsRow: some View {
    labeledRow("Notify on low balance") {
      Toggle("", isOn: $settings.notificationsEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel("Notify when the balance is low")
    }
  }

  private var cooldownRow: some View {
    labeledRow("Notify again after") {
      HStack(spacing: 6) {
        Text(Self.cooldownText(settings.notificationCooldownMinutes))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Stepper(
          "",
          value: $settings.notificationCooldownMinutes,
          in: AppSettings.notificationCooldownRange,
          step: 30
        )
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Notification cooldown in minutes")
      }
    }
    .disabled(!settings.notificationsEnabled)
  }

  /// Stated once, calmly, and only while it is true: the menu-bar warning glyph is the fallback, so
  /// a low balance stays visible even when macOS will not deliver the alert.
  private static let alertsUnavailableNote =
    "macOS notifications are off for DeepTally, so low-balance alerts are not delivered. While the "
    + "balance is low the menu bar shows a warning glyph; re-allow DeepTally in System Settings → "
    + "Notifications to get the alert."

  /// Whole hours once the cooldown passes an hour, because "720 min" is a number nobody reads.
  private static func cooldownText(_ minutes: Int) -> String {
    guard minutes >= 60 else { return "\(minutes) min" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
  }

  // MARK: - API key

  private var keyRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      labeledRow("Import from shell") {
        HStack(spacing: 6) {
          ForEach(ShellKind.allCases, id: \.self) { shell in
            Button(shell.rawValue) { onImportFromShell(shell) }
              .controlSize(.small)
              .disabled(isImportingKey)
              .accessibilityLabel("Import API key from \(shell.rawValue)")
          }
        }
      }

      HStack(spacing: 8) {
        Button("Forget key") { onDeleteKey() }
          .controlSize(.small)
          .disabled(isImportingKey)
          .accessibilityLabel("Forget the stored API key")
        Spacer(minLength: 8)
        if isImportingKey {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Importing the API key")
        }
      }

      // Caller-supplied: an import report or an error. Never the key, which only ever goes into the
      // Keychain (AGENTS.md §5).
      if let importMessage {
        Text(importMessage)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Key import status")
      }
    }
  }

  // MARK: - Row layout

  private func labeledRow<Control: View>(
    _ label: String,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.caption)
      Spacer(minLength: 8)
      control()
    }
  }
}

// Previews use `PreviewProvider` rather than `#Preview`: the `#Preview` macro is implemented by the
// `PreviewsMacros` plugin, which ships with Xcode, and this repo builds with Command Line Tools only
// — expanding it there fails with "plugin for module 'PreviewsMacros' not found". Do not rewrite
// these as `#Preview` unless that plugin becomes available.
struct SettingsPanelPreviews: PreviewProvider {
  /// A constant binding: previews cannot hold `@State` here either — that is a `SwiftUIMacros`
  /// plugin macro, unavailable to a Command Line Tools build just like `#Preview`. The controls are
  /// therefore inert in the canvas; the real binding comes from the app.
  static var previews: some View {
    VStack(alignment: .leading, spacing: 20) {
      SettingsPanel(
        settings: .constant(AppSettings.default),
        isImportingKey: false,
        importMessage: "Imported a key from zsh.",
        onImportFromShell: { _ in },
        onDeleteKey: {}
      )
      Divider()
      SettingsPanel(
        settings: .constant(AppSettings.default),
        isImportingKey: false,
        importMessage: nil,
        alertsUnavailable: true,
        onImportFromShell: { _ in },
        onDeleteKey: {}
      )
    }
    .padding(14)
    .frame(width: 320)
  }
}
