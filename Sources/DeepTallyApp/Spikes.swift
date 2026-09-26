// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import DeepTallyCore
import Foundation
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

/// Step 2 spike helpers. Each command prints one JSON line to stdout and exits; none of this runs
/// on the normal app path. Protocol and results: `docs/SPIKES.md`.
///
/// Usage (from inside the bundle, so bundle identity exists):
///   dist/DeepTally.app/Contents/MacOS/DeepTally --spike identity
///   dist/DeepTally.app/Contents/MacOS/DeepTally --spike keychain-store
enum Spikes {
  static let keychainService = "io.github.genoma.deeptally.spike"
  static let keychainAccount = "spike-account"

  @MainActor
  static func run(_ arguments: ArraySlice<String>) -> Never {
    switch arguments.first {
    case "identity": printJSON(identitySnapshot())
    case "keychain-store": printJSON(storeKeychain())
    case "keychain-read": printJSON(readKeychain())
    case "keychain-delete": printJSON(deleteKeychain())
    case "login-item-register": printJSON(registerLoginItem())
    case "login-item-status": printJSON(loginItemStatus())
    case "login-item-unregister": printJSON(unregisterLoginItem())
    case "notifications": requestNotifications()
    case "render-popover": renderPopover(arguments.dropFirst())
    case "proxy": runProxySpike(arguments.dropFirst())
    case "simulate-wake": simulateWake()
    default: printJSON(["error": "unknown spike command"])
    }
    exit(0)
  }

  // MARK: - UI verification

  /// Renders the real popover with live data to PNG files, so the Step 3 gate can be checked without
  /// a human at the screen — and so README and docs screenshots come from the shipping views instead
  /// of a mockup.
  ///
  ///   --spike render-popover [basePath] [height] [--ledger <path>] [--opencode <path>]
  ///
  /// Defaults to `dist/popover` and a 420pt-tall body. `--ledger`/`--opencode` point the render at a
  /// throwaway store and database instead of the real ones, so the gate can render a seeded value
  /// without writing into the app's own ledger — and can show the fail-soft path with a database that
  /// does not exist.
  ///
  /// It runs the real composition root and the real key precedence, so a successful render with
  /// DEEPSEEK_API_KEY unset is also proof that the Keychain import worked.
  @MainActor
  private static func renderPopover(_ arguments: ArraySlice<String>) -> Never {
    var rest = arguments
    let basePath: String
    if let first = rest.first, !first.hasPrefix("--") {
      basePath = first
      rest = rest.dropFirst()
    } else {
      basePath =
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "dist/popover").path
    }
    // A real popover is 420pt tall and scrolls. The height below only pads the captured canvas:
    // PopoverView pins its own 420pt frame, so the image is the top of the scrolled content and the
    // sections below the fold are not in it. Capture those with their own render, as the settings
    // panel does.
    var height = 420.0
    if let first = rest.first, !first.hasPrefix("--") {
      height = Double(first) ?? height
      rest = rest.dropFirst()
    }
    var ledgerPath: String?
    var openCodePath: String?
    while let flag = rest.first {
      rest = rest.dropFirst()
      switch flag {
      case "--ledger":
        ledgerPath = rest.first
        rest = rest.dropFirst()
      case "--opencode":
        openCodePath = rest.first
        rest = rest.dropFirst()
      default:
        break
      }
    }

    let environment = AppEnvironment(
      ledgerURL: ledgerPath.map { URL(fileURLWithPath: $0) } ?? LedgerStore.standardURL,
      openCodeDatabaseURL: openCodePath.map { URL(fileURLWithPath: $0) }
        ?? OpenCodeImporter.standardDatabaseURL)
    let model = AppModel(environment: environment)
    model.start()
    let deadline = Date().addingTimeInterval(20)
    // Wait for a settled state: a persisted reading can make balanceState non-nil before the live fetch
    // finishes, which would bake a permanent "Refreshing…" into the screenshot.
    while (model.balanceState == nil || model.isRefreshing) && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    // The ledger metrics are half of what this render reports, so wait for the first pass too. The
    // first pass on a real profile imports the whole local database, which is slower than a poll; the
    // loop ends as soon as that pass finishes either way. A longer budget than the balance's, because
    // a full scan of a large opencode database is the expected first run.
    let usageDeadline = Date().addingTimeInterval(90)
    while model.localUsage == nil && model.isLocalUsageRefreshing && Date() < usageDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    let menuBar = model.menuBarPresentation

    printJSON([
      "command": "render-popover",
      "balance": model.balanceState?.amountText ?? "none",
      "status": model.balanceState?.statusText ?? "",
      "keyOrigin": String(describing: model.keyOrigin),
      "period": model.rateNow?.periodLabel ?? "none",
      "countdown": model.rateNow?.countdown ?? "none",
      "lowBalanceThreshold": "\(model.settings.lowBalanceThreshold)",
      // The menu-bar fallback facts a PNG cannot show: the Step 3 review could not see the status
      // item at all, so the render now reports what the button would carry.
      "menuBarTitle": menuBar.title, "menuBarWarningGlyph": menuBar.showsLowBalanceWarning,
      "menuBarTooltip": menuBar.tooltip ?? "",
      "notificationsEnabled": model.settings.notificationsEnabled,
      "alertsAvailable": model.alertAuthorization == .authorized,
      "alertsAuthorization": Self.authorizationName(model.alertAuthorization),
      // The selected metric and the ledger-backed numbers behind it. Added for the Step 4 gate; the
      // fields above are unchanged.
      "menuBarMetric": model.settings.menuBarMetric.rawValue,
      "metricLabel": model.menuBarLabel,
      "todaySpendLabel": model.todaySpendText ?? "none",
      "cacheHitRateLabel": model.cacheHitRateText,
      "localUsageProblem": model.localUsageProblem ?? "",
      "ledgerPath": environment.ledgerURL.path,
    ])

    for (suffix, scheme) in [("", ColorScheme.light), ("-dark", .dark)] {
      // The real popover draws on the system material, which an offscreen render has no equivalent
      // for: without an explicit background the dark variant renders white text on nothing. The
      // neutral fill below is a rendering aid for screenshots, not a product colour.
      let chrome: Color = scheme == .dark ? Color(white: 0.13) : Color(white: 0.97)
      let root = PopoverView(model: model)
        .environment(\.colorScheme, scheme)
        .background(chrome)
      writePNG(
        AnyView(root), size: NSSize(width: 320, height: height),
        to: URL(fileURLWithPath: basePath + suffix + ".png"))
    }

    // The settings block sits below the popover's 420pt scroll fold, so it gets its own render —
    // otherwise the gate can never see the controls that matter most on first run.
    var fixture = AppSettings.default
    let panel = SettingsPanel(
      settings: Binding(get: { fixture }, set: { fixture = $0 }),
      isImportingKey: false,
      importMessage: nil,
      alertsUnavailable: model.alertsUnavailable,
      proxyCaption: model.proxyCaption,
      onImportFromShell: { _ in },
      onDeleteKey: {}
    )
    writePNG(
      AnyView(
        panel.padding(14)
          .environment(\.colorScheme, .light)
          .background(Color(white: 0.97))),
      size: NSSize(width: 320, height: 620),
      to: URL(fileURLWithPath: basePath + "-settings.png"))
    exit(0)
  }

  // MARK: - The usage proxy

  /// The Step 6.5 spike: the real proxy in the foreground, against the real ledger and the real
  /// upstream. A spike, not a user feature — the shipping path is the settings toggle, and this is
  /// what the release gate drives.
  ///
  ///   --spike proxy [port] [--ledger PATH]
  ///
  /// Defaults to port 8787 and the standard ledger. It prints one JSON line with the port the
  /// listener actually bound — pass 0 to ask for an ephemeral one — and then runs until it is killed.
  /// It needs no API key of its own: the client's own `Authorization` header is what travels
  /// upstream, and the ledger records only counters, model and response id.
  @MainActor
  private static func runProxySpike(_ arguments: ArraySlice<String>) -> Never {
    var port = 8787
    var ledgerPath = LedgerStore.standardURL.path
    var rest = arguments
    if let first = rest.first, !first.hasPrefix("--") {
      port = Int(first) ?? port
      rest = rest.dropFirst()
    }
    while let flag = rest.first {
      rest = rest.dropFirst()
      switch flag {
      case "--ledger":
        if let path = rest.first {
          ledgerPath = path
          rest = rest.dropFirst()
        }
      default:
        break
      }
    }

    let ledgerURL = URL(fileURLWithPath: ledgerPath)
    let environment = AppEnvironment(ledgerURL: ledgerURL)
    let ledger = environment.makeLocalUsageLedger()
    let calendar = environment.calendar
    let server = environment.makeUsageProxyServer(recording: { usage in
      // The ledger the app itself writes to, priced the same way: this spike exists to prove the
      // shipping path rather than a parallel one.
      _ = await ledger.record(usage, now: Date(), calendar: calendar)
    })
    Task {
      switch await server.start(port: port) {
      case .listening(let boundPort):
        printJSON([
          "command": "proxy",
          "port": boundPort,
          "ledger": ledgerURL.path,
          "upstream": URLSessionProxyUpstream.baseURL.absoluteString,
        ])
      case .notListening(let reason):
        printJSON(["command": "proxy", "error": reason, "ledger": ledgerURL.path])
        exit(3)
      }
    }
    // The listener is this process's foreground work: it stays up until it is killed.
    RunLoop.main.run()
    exit(0)
  }

  /// Offscreen hosting has no window, so it has no appearance and no material behind it: without an
  /// explicit colorScheme *and* background the content resolves dark-on-nothing and renders
  /// white-on-white (learned the hard way, 2026-09-24). Every caller sets both.
  /// Proves the wake handler. It starts the model, waits for the first fetch, posts the same
  /// notification macOS posts when the machine wakes, and reports whether another fetch followed.
  ///
  /// This exercises OUR handler; the delivery of that notification on a real lid-open remains macOS
  /// behaviour and is not simulated here.
  @MainActor
  private static func simulateWake() -> Never {
    let model = AppModel()
    model.start()
    let deadline = Date().addingTimeInterval(20)
    while (model.balanceState == nil || model.isRefreshing) && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    let before = model.lastSuccess
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

    var refreshed = false
    let wakeDeadline = Date().addingTimeInterval(15)
    while Date() < wakeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      if let after = model.lastSuccess, after != before {
        refreshed = true
        break
      }
    }

    printJSON([
      "command": "simulate-wake",
      "refreshedOnWake": refreshed,
      "before": before.map { ISO8601DateFormatter().string(from: $0) } ?? "none",
      "after": model.lastSuccess.map { ISO8601DateFormatter().string(from: $0) } ?? "none",
      "balance": model.balanceState?.amountText ?? "none",
    ])
    exit(0)
  }

  @MainActor
  private static func writePNG(_ view: AnyView, size: NSSize, to url: URL) {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      FileHandle.standardError.write(Data("could not allocate a bitmap for \(url.path)\n".utf8))
      return
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      FileHandle.standardError.write(Data("could not encode \(url.path)\n".utf8))
      return
    }
    do {
      try data.write(to: url)
    } catch {
      FileHandle.standardError.write(Data("could not write \(url.path): \(error)\n".utf8))
    }
  }

  // MARK: - Identity / environment

  /// Facts that decide the install and packaging story. Never includes a secret, only whether one
  /// is visible in the environment.
  static func identitySnapshot() -> [String: Any] {
    let bundlePath = Bundle.main.bundlePath
    return [
      "command": "identity",
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "bundlePath": bundlePath,
      "bundleID": Bundle.main.bundleIdentifier ?? "",
      "executable": Bundle.main.executablePath ?? "",
      "translocated": bundlePath.contains("/AppTranslocation/"),
      "quarantined": bundlePath.withCString {
        getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) > 0
      },
      "hasEnvAPIKey": ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] != nil,
      "pid": ProcessInfo.processInfo.processIdentifier,
    ]
  }

  // MARK: - Keychain

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
  }

  private static func storeKeychain() -> [String: Any] {
    let query = baseQuery()
    SecItemDelete(query as CFDictionary)
    var add = query
    add[kSecValueData as String] = Data("spike-value".utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let status = SecItemAdd(add as CFDictionary, nil)
    return ["command": "keychain-store", "status": Int(status), "message": message(status)]
  }

  private static func readKeychain() -> [String: Any] {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    let value = (item as? Data).map { String(decoding: $0, as: UTF8.self) } ?? ""
    return [
      "command": "keychain-read", "status": Int(status), "value": value, "message": message(status),
    ]
  }

  private static func deleteKeychain() -> [String: Any] {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    return ["command": "keychain-delete", "status": Int(status), "message": message(status)]
  }

  private static func message(_ status: OSStatus) -> String {
    (SecCopyErrorMessageString(status, nil) as String?) ?? ""
  }

  // MARK: - Login item

  private static func registerLoginItem() -> [String: Any] {
    var failure = ""
    do {
      try SMAppService.mainApp.register()
    } catch {
      failure = String(describing: error)
    }
    return [
      "command": "login-item-register",
      "status": statusName(SMAppService.mainApp.status),
      "error": failure,
    ]
  }

  private static func loginItemStatus() -> [String: Any] {
    ["command": "login-item-status", "status": statusName(SMAppService.mainApp.status)]
  }

  private static func unregisterLoginItem() -> [String: Any] {
    var failure = ""
    do {
      try SMAppService.mainApp.unregister()
    } catch {
      failure = String(describing: error)
    }
    return [
      "command": "login-item-unregister",
      "status": statusName(SMAppService.mainApp.status),
      "error": failure,
    ]
  }

  private static func statusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown(\(status.rawValue))"
    }
  }

  // MARK: - Notifications

  /// Prints the authorization result after the user answers the prompt (or after a timeout).
  private static func requestNotifications() -> Never {
    let timeout = DispatchWorkItem {
      printJSON(["command": "notifications", "result": "timeout-waiting-for-prompt"])
      exit(2)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)

    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      granted, error in
      timeout.cancel()
      printJSON([
        "command": "notifications",
        "granted": granted,
        "error": error.map { String(describing: $0) } ?? "",
      ])
      exit(0)
    }

    RunLoop.main.run()
    exit(0)
  }

  // MARK: - Output

  /// The alert authorization as one JSON word, so a render records whether macOS would deliver the
  /// low-balance alert and, when it would not, why.
  private static func authorizationName(_ authorization: AlertAuthorization?) -> String {
    switch authorization {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .notAsked: return "notAsked"
    case .unknown: return "unknown"
    case nil: return "notRead"
    }
  }

  private static func printJSON(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let line = String(data: data, encoding: .utf8)
    else {
      print("{\"error\": \"unserializable\"}")
      return
    }
    print(line)
    // Flushed, not merely printed: `--spike proxy` keeps running after its one line, and a caller
    // reading the port out of a pipe would otherwise wait for a buffer that never fills.
    fflush(stdout)
  }
}
