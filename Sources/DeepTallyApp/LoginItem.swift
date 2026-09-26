// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ServiceManagement

/// "Launch at login" through `SMAppService.mainApp`, which is the whole implementation: no
/// LaunchAgent, no helper bundle, no plist to write.
///
/// Measured on this machine (docs/SPIKES.md S3): registration succeeds for an ad-hoc-signed bundle,
/// from `/Applications` and from a build directory alike, with no approval prompt. The wrapper exists
/// so the rest of the app never has to know that `SMAppService.Status` has its own vocabulary.
enum LoginItem {
  /// macOS's view of the login item, with the raw values folded into one enum. `unknown` carries the
  /// raw value so a future macOS status is reported rather than swallowed.
  enum Status: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown(Int)
  }

  static var status: Status {
    // Read once: the switch and the raw value have to be about the same observation.
    let current = SMAppService.mainApp.status
    switch current {
    case .notRegistered: return .notRegistered
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    case .notFound: return .notFound
    @unknown default: return .unknown(current.rawValue)
    }
  }

  /// Registers the app itself as a login item. Throws when macOS refuses, which is reported to the
  /// user as ``describe(_:)`` rather than as an `NSError` dump.
  static func register() throws {
    try SMAppService.mainApp.register()
  }

  /// Removes the login item. Unregistering what is not registered is not an error.
  static func unregister() throws {
    try SMAppService.mainApp.unregister()
  }

  /// A registration failure as a sentence. The underlying error's domain and code are kept — they
  /// are what makes a bug report actionable — and they can never carry a secret.
  static func describe(_ error: any Error) -> String {
    "Could not update the login item (\(String(describing: error))). It can also be changed in "
      + "System Settings → General → Login Items."
  }
}

/// The login-item operations the app performs, as one injectable value.
///
/// `SMAppService` acts on the *calling* process, so a test that reached these directly would really
/// register the test runner as a login item. Behind this seam the app's toggle — including what it
/// does when the register call fails — is testable without that side effect.
struct LoginItemControl: Sendable {
  var status: @MainActor @Sendable () -> LoginItem.Status
  var register: @MainActor @Sendable () throws -> Void
  var unregister: @MainActor @Sendable () throws -> Void

  /// The shipping value: `SMAppService.mainApp`, read and changed.
  static let system = LoginItemControl(
    status: { LoginItem.status },
    register: { try LoginItem.register() },
    unregister: { try LoginItem.unregister() })
}
