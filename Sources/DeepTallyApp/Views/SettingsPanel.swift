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
  /// The address clients should be pointed at, with the port the proxy actually bound, or `nil` while
  /// the proxy is off or could not start. Built by the model, because only it knows the bound port.
  private let proxyCaption: String?
  private let onImportFromShell: (ShellKind) -> Void
  private let onDeleteKey: () -> Void

  init(
    settings: Binding<AppSettings>,
    isImportingKey: Bool,
    importMessage: String?,
    alertsUnavailable: Bool = false,
    proxyCaption: String?,
    onImportFromShell: @escaping (ShellKind) -> Void,
    onDeleteKey: @escaping () -> Void
  ) {
    _settings = settings
    self.isImportingKey = isImportingKey
    self.importMessage = importMessage
    self.alertsUnavailable = alertsUnavailable
    self.proxyCaption = proxyCaption
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
        proxyRow
        if settings.proxyEnabled {
          proxyPortRow
          proxyCaptionLine
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

  /// All three metrics have a number behind them: the balance from the API, today's spend and the
  /// cache-hit rate from the app's own import of local usage.
  private var metricRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      labeledRow("Menu bar") {
        Picker("Menu bar metric", selection: $settings.menuBarMetric) {
          ForEach(MenuBarMetric.allCases, id: \.self) { metric in
            Text(Self.label(for: metric))
              .tag(metric)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help(Self.metricHelp)
        .accessibilityLabel("Menu bar metric")
      }
    }
  }

  /// The windows are not visible in the labels, so the picker names them: "today" is the local day,
  /// and the cache-hit rate is the trailing 30 days that ``LocalUsageLedger`` reads.
  private static let metricHelp =
    "Today's spend is today's local day, priced from the local usage ledger. Cache-hit rate covers "
    + "the last 30 days."

  private static func label(for metric: MenuBarMetric) -> String {
    switch metric {
    case .balance: return "Balance"
    case .todaySpend: return "Today's spend"
    case .cacheHitRate: return "Cache-hit rate"
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

  // MARK: - Local usage proxy

  /// The listener toggle. Off by default, and off after every update: this is the only part of the
  /// app that accepts a connection, so it is never on unless the user turned it on (AGENTS.md §1).
  private var proxyRow: some View {
    labeledRow("Local usage proxy") {
      Toggle("", isOn: $settings.proxyEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel("Run the local usage proxy")
        .help(
          "Point an OpenAI-compatible client at the address below and its usage is recorded in the "
            + "local ledger."
        )
    }
  }

  private var proxyPortRow: some View {
    labeledRow("Port") {
      HStack(spacing: 6) {
        Text("\(settings.proxyPort)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Stepper("", value: $settings.proxyPort, in: AppSettings.proxyPortRange)
          .labelsHidden()
          .controlSize(.small)
          .accessibilityLabel("Local usage proxy port")
      }
    }
  }

  /// The caption carries the address with the port the listener actually bound — and it is absent
  /// until it has bound, because an address no listener is answering at is worse than none. A bind
  /// failure has its own line in the banner stack above.
  @ViewBuilder private var proxyCaptionLine: some View {
    if let proxyCaption {
      Text(proxyCaption)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Local usage proxy address")
    }
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
  /// The second panel shows the proxy on, so the canvas carries the port and the caption too.
  private static var proxyEnabled: AppSettings {
    var settings = AppSettings.default
    settings.proxyEnabled = true
    return settings
  }

  private static let proxyCaption =
    "Point clients at http://127.0.0.1:8787 — usage is recorded from each API response."

  /// A constant binding: previews cannot hold `@State` here either — that is a `SwiftUIMacros`
  /// plugin macro, unavailable to a Command Line Tools build just like `#Preview`. The controls are
  /// therefore inert in the canvas; the real binding comes from the app.
  static var previews: some View {
    VStack(alignment: .leading, spacing: 20) {
      SettingsPanel(
        settings: .constant(AppSettings.default),
        isImportingKey: false,
        importMessage: "Imported a key from zsh.",
        proxyCaption: nil,
        onImportFromShell: { _ in },
        onDeleteKey: {}
      )
      Divider()
      SettingsPanel(
        settings: .constant(Self.proxyEnabled),
        isImportingKey: false,
        importMessage: nil,
        alertsUnavailable: true,
        proxyCaption: Self.proxyCaption,
        onImportFromShell: { _ in },
        onDeleteKey: {}
      )
    }
    .padding(14)
    .frame(width: 320)
  }
}
