// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Failures the Keychain can report. `unexpectedStatus` carries the raw `OSStatus` so a caller can
/// map it (`KeyImportError.keychain`); no case carries any part of the secret.
public enum KeychainError: Error, Sendable, Equatable {
  case unexpectedStatus(OSStatus)
  case invalidSecret
}

/// One generic-password item holding the DeepSeek API key.
///
/// `kSecAttrAccessibleWhenUnlocked` matches the measured spike (docs/SPIKES.md S5): an item created
/// without an explicit ACL reads back silently in a rebuilt, differently-signed bundle, so an ad-hoc
/// update does not re-prompt. The key lives only here — never in `UserDefaults`, a file, or a log.
public struct KeychainStore: Sendable {
  private let service: String
  private let account: String

  public init(service: String = "io.github.genoma.deeptally", account: String = "api-key") {
    self.service = service
    self.account = account
  }

  /// Stores the secret, replacing any existing item.
  ///
  /// Update-or-add rather than delete-then-add: `SecItemDelete` can legitimately fail (an item
  /// created by a differently-signed build, a locked keychain, a policy denial) and its status used
  /// to be ignored, so that failure resurfaced as a confusing `errSecDuplicateItem` from the
  /// following add — observed 2026-09-24 when importing through the CLI over an item the app had
  /// created. Updating first keeps the item's existing ACL and attributes, and any real failure now
  /// reports its own status instead of being masked.
  ///
  /// The secret is validated first and the trimmed form is what is stored, so a stray space or
  /// newline can never become part of a `Bearer` header.
  public func store(_ secret: String) throws {
    let value = try Self.validated(secret)
    let data = Data(value.utf8)

    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var attributes = baseQuery
      attributes[kSecValueData as String] = data
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
      let addStatus = SecItemAdd(attributes as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    default:
      throw KeychainError.unexpectedStatus(updateStatus)
    }
  }

  /// The stored secret, or `nil` when no item exists.
  public func read() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
        throw KeychainError.unexpectedStatus(errSecDecode)
      }
      return secret
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError.unexpectedStatus(status)
    }
  }

  /// Deletes the item. Deleting an item that is not there is a no-op, not an error.
  public func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }

  /// Whether an item exists, without reading the secret itself.
  public func hasItem() -> Bool {
    var query = baseQuery
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  /// Trimmed, non-empty, no newline or CR, fewer than 200 characters. The bound is generous for a
  /// DeepSeek key (`sk-` plus a short suffix) but small enough to keep a pasted file out.
  private static func validated(_ secret: String) throws -> String {
    guard !secret.contains("\n"), !secret.contains("\r") else {
      throw KeychainError.invalidSecret
    }
    let trimmed = secret.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count < 200 else { throw KeychainError.invalidSecret }
    return trimmed
  }
}
