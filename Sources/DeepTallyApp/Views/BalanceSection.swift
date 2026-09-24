// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import SwiftUI

/// The popover's balance block: the amount, how old the reading is, the monitor's status line, a
/// low-balance notice and the manual refresh control.
///
/// Width comes from the popover (`PopoverView` fixes it at 320pt), so the section fills whatever
/// width it is given instead of imposing its own.
struct BalanceSection: View {
  /// The same sentence `BalanceMonitor` reports as the status text while the balance is low; named
  /// once here so the notice and the status line cannot drift apart.
  private static let lowBalanceNotice = "Low balance — top up to keep requests running."

  private let state: BalanceState?
  private let isLoading: Bool
  private let onRefresh: () -> Void

  init(state: BalanceState?, isLoading: Bool, onRefresh: @escaping () -> Void) {
    self.state = state
    self.isLoading = isLoading
    self.onRefresh = onRefresh
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("DeepSeek balance")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(state?.amountText ?? "—")
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .foregroundStyle(state?.isLow == true ? Color.orange : Color.primary)

      if let ageText = state?.ageText {
        Text(ageText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      statusLine
      refreshRow
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// While the balance is low the monitor's status text *is* the notice — the same sentence
  /// `BalanceMonitor` reports — so only one of the two is drawn: the warning keeps its icon, and the
  /// panel keeps one line per fact.
  @ViewBuilder private var statusLine: some View {
    if let state {
      if state.isLow {
        Label(Self.lowBalanceNotice, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Text(state.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      Text("Not loaded yet")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var refreshRow: some View {
    HStack(spacing: 6) {
      Button("Refresh") { onRefresh() }
        .disabled(isLoading)
        .accessibilityLabel("Refresh balance")
      if isLoading {
        // Same loading idiom as the popover's own balance row: a small spinner plus the word.
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Refreshing…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Refreshing balance")
      }
    }
    .padding(.top, 2)
  }
}

// Previews use `PreviewProvider` rather than `#Preview`: the `#Preview` macro is implemented by the
// `PreviewsMacros` plugin, which ships with Xcode, and this repo builds with Command Line Tools only
// — expanding it there fails with "plugin for module 'PreviewsMacros' not found". Do not rewrite
// these as `#Preview` unless that plugin becomes available.
struct BalanceSectionPreviews: PreviewProvider {
  static var previews: some View {
    VStack(alignment: .leading, spacing: 14) {
      BalanceSection(state: state(amount: "1.42", fetchedSecondsAgo: 7200), isLoading: false) {}
      Divider()
      BalanceSection(state: state(amount: "13.49", fetchedSecondsAgo: 45), isLoading: false) {}
      Divider()
      BalanceSection(state: state(amount: "13.49", fetchedSecondsAgo: 45), isLoading: true) {}
      Divider()
      BalanceSection(state: nil, isLoading: false) {}
    }
    .padding(14)
    .frame(width: 320)
  }

  /// Built through the public `BalanceMonitor`: `BalanceState` has no public memberwise initialiser,
  /// and this file has no testability access.
  private static func state(amount: String, fetchedSecondsAgo: TimeInterval) -> BalanceState {
    let total = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) ?? .zero
    let fetched = Date().addingTimeInterval(-fetchedSecondsAgo)
    return BalanceMonitor().evaluate(
      balance: Balance(
        isAvailable: true,
        infos: [
          BalanceInfo(
            currency: "USD",
            totalBalance: total,
            grantedBalance: .zero,
            toppedUpBalance: total
          )
        ]
      ),
      lastSuccess: fetched,
      now: Date()
    )
  }
}
