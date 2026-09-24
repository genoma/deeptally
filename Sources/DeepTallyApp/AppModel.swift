// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded(Date)
    case failed(String)
  }

  private(set) var balance: Balance?
  private(set) var state: LoadState = .idle
  private(set) var lastError: String?

  /// Set by the status item controller; called after every state change.
  var onUpdate: (() -> Void)?

  let lowBalanceThreshold: Decimal = 2

  private let client: DeepSeekClient

  init(client: DeepSeekClient = DeepSeekClient(keyProvider: DeepSeekClient.keyFromEnvironment)) {
    self.client = client
  }

  var isLowBalance: Bool {
    guard let total = balance?.primary?.totalBalance else { return false }
    return total < lowBalanceThreshold
  }

  /// Compact menu bar label. Currency is shown as-is; never converted.
  var menuBarLabel: String {
    guard let info = balance?.primary else { return "—" }
    let amount = (info.totalBalance as NSDecimalNumber).doubleValue
    let symbol: String
    switch info.currency {
    case "USD": symbol = "$"
    case "CNY": symbol = "¥"
    default: symbol = ""
    }
    return String(format: "%@%.2f", symbol, amount)
  }

  func refresh() {
    if case .loading = state { return }
    state = .loading
    onUpdate?()
    Task { [client] in
      do {
        let balance = try await client.balance()
        self.balance = balance
        self.lastError = nil
        self.state = .loaded(Date())
      } catch {
        self.lastError = DeepSeekClient.describe(error)
        self.state = .failed(self.lastError ?? "Unknown error")
      }
      self.onUpdate?()
    }
  }
}
