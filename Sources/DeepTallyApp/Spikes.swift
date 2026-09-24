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
    default: printJSON(["error": "unknown spike command"])
    }
    exit(0)
  }

  // MARK: - UI verification

  /// Renders the real popover with live data to PNG files, so the Step 3 gate can be checked without
  /// a human at the screen — and so README and docs screenshots come from the shipping views instead
  /// of a mockup.
  ///
  ///   --spike render-popover dist/popover   -> dist/popover.png and dist/popover-dark.png
  ///
  /// It runs the real composition root and the real key precedence, so a successful render with
  /// DEEPSEEK_API_KEY unset is also proof that the Keychain import worked.
  @MainActor
  private static func renderPopover(_ arguments: ArraySlice<String>) -> Never {
    let basePath =
      arguments.first
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "dist/popover").path
    // A real popover is 420pt tall and scrolls; pass a taller height to capture the whole body for docs.
    let height = arguments.dropFirst().first.flatMap(Double.init) ?? 420

    let model = AppModel()
    model.start()
    let deadline = Date().addingTimeInterval(20)
    // Wait for a settled state: a persisted reading can make balanceState non-nil before the live fetch
    // finishes, which would bake a permanent "Refreshing…" into the screenshot.
    while (model.balanceState == nil || model.isRefreshing) && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    printJSON([
      "command": "render-popover",
      "balance": model.balanceState?.amountText ?? "none",
      "status": model.balanceState?.statusText ?? "",
      "keyOrigin": String(describing: model.keyOrigin),
      "period": model.rateNow?.periodLabel ?? "none",
      "countdown": model.rateNow?.countdown ?? "none",
      "lowBalanceThreshold": "\(model.settings.lowBalanceThreshold)",
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

  /// Offscreen hosting has no window, so it has no appearance and no material behind it: without an
  /// explicit colorScheme *and* background the content resolves dark-on-nothing and renders
  /// white-on-white (learned the hard way, 2026-09-24). Every caller sets both.
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

  private static func printJSON(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let line = String(data: data, encoding: .utf8)
    else {
      print("{\"error\": \"unserializable\"}")
      return
    }
    print(line)
  }
}
