// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PopoverView: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      balanceSection
      Divider()
      rateSection
      Divider()
      footer
    }
    .padding(14)
    .frame(width: 320)
  }

  private var balanceSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("DeepSeek balance")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(model.menuBarLabel)
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .foregroundStyle(model.isLowBalance ? Color.orange : Color.primary)

      switch model.state {
      case .idle:
        Text("Not loaded yet")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .loading:
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
        }
      case .loaded(let date):
        Text("as of \(date.formatted(date: .omitted, time: .standard))")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .failed(let message):
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if model.isLowBalance {
        Text("Low balance — top up to keep requests running.")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      Button("Refresh") { model.refresh() }
        .disabled(model.state == .loading)
        .padding(.top, 2)
    }
  }

  private var rateSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Current rate")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("Peak / off-peak indicator lands in Step 3 — local time, countdown, effective prices.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var footer: some View {
    HStack {
      Text("DeepTally \(DeepTallyVersion.current)")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Spacer()
      Text("local-only").font(.caption2).foregroundStyle(.secondary)
    }
  }
}

enum DeepTallyVersion {
  static let current =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
