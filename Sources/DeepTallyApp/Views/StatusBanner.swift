// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// A one-line, kind-tinted notice with an optional trailing action — the slot that carries the App
/// Translocation warning and key-import failures.
///
/// The whole banner is a semantic colour, so it follows light and dark menu bars; the meaning is
/// never colour alone, because the icon and the message say the same thing the tint does.
struct StatusBanner: View {
  enum Kind: Sendable {
    case info
    case warning
    case error

    var symbolName: String {
      switch self {
      case .info: return "info.circle.fill"
      case .warning: return "exclamationmark.triangle.fill"
      case .error: return "xmark.octagon.fill"
      }
    }

    var tint: Color {
      switch self {
      case .info: return .secondary
      case .warning: return .orange
      case .error: return .red
      }
    }
  }

  private let kind: Kind
  private let message: String
  private let actionTitle: String?
  private let action: (() -> Void)?

  init(kind: Kind, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
    self.kind = kind
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      // Decorative: the message text is what a screen reader should read.
      Image(systemName: kind.symbolName)
        .accessibilityHidden(true)

      Text(message)
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      if let actionTitle, let action {
        Button(actionTitle) { action() }
          .controlSize(.small)
      }
    }
    .foregroundStyle(kind.tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// Previews use `PreviewProvider` rather than `#Preview`: the `#Preview` macro is implemented by the
// `PreviewsMacros` plugin, which ships with Xcode, and this repo builds with Command Line Tools only
// — expanding it there fails with "plugin for module 'PreviewsMacros' not found". Do not rewrite
// these as `#Preview` unless that plugin becomes available.
struct StatusBannerPreviews: PreviewProvider {
  static var previews: some View {
    VStack(alignment: .leading, spacing: 10) {
      StatusBanner(kind: .info, message: "Balance refreshed just now.")
      StatusBanner(
        kind: .warning,
        message: "DeepTally is running from a read-only App Translocation copy.",
        actionTitle: "How to fix",
        action: {}
      )
      StatusBanner(kind: .error, message: "The API key could not be read from the Keychain.")
    }
    .padding(14)
    .frame(width: 320)
  }
}
