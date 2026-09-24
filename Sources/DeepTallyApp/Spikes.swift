// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Foundation
import Security
import ServiceManagement
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
    default: printJSON(["error": "unknown spike command"])
    }
    exit(0)
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
