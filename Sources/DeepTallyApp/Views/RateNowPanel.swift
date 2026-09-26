// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import SwiftUI

/// "What am I paying right now?" — the period in force, when it ends, and the effective price of
/// every model while it lasts.
///
/// Every string arrives ready to place from `RateNowPresenter`; the only work left here is choosing
/// how the amount columns line up.
struct RateNowPanel: View {
  private let display: RateNowDisplay?

  init(display: RateNowDisplay?) {
    self.display = display
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Current rate")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let display {
        periodLine(display)
        transitionLine(display)
        if let note = display.holidayNote {
          Text(note)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        priceTable(display.models, currency: display.currency)
      } else {
        Text("Rate information is not available yet.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func periodLine(_ display: RateNowDisplay) -> some View {
    HStack(spacing: 6) {
      Text(display.periodLabel)
        .font(.subheadline.weight(.semibold))
      Text(display.multiplierLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// The window end is the local wall-clock time the engine reported; the weekday form of the same
  /// instant stays in the tooltip, where it does not repeat the line above.
  private func transitionLine(_ display: RateNowDisplay) -> some View {
    Text("Ends \(display.windowEndsLocal) · \(display.countdown) left")
      .font(.caption)
      .foregroundStyle(.secondary)
      .help("Next transition: \(display.nextTransitionLocal)")
  }

  private func priceTable(_ models: [ModelRate], currency: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("\(currency) per 1M tokens")
        .font(.caption2)
        .foregroundStyle(.secondary)

      Grid(horizontalSpacing: 8, verticalSpacing: 2) {
        GridRow {
          Text("Model").gridColumnAlignment(.leading)
          Text("Cache-hit").gridColumnAlignment(.trailing)
          Text("Cache-miss").gridColumnAlignment(.trailing)
          Text("Output").gridColumnAlignment(.trailing)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)

        ForEach(models, id: \.model) { rate in
          GridRow {
            Text(rate.model)
            Text(priceText(rate.cacheHit))
            Text(priceText(rate.cacheMiss))
            Text(priceText(rate.output))
          }
          .font(.caption2.monospacedDigit())
        }
      }
    }
    .padding(.top, 2)
  }

  /// Two decimals, plus up to two more when the value needs them: cache-hit rates are three-decimal
  /// figures (`0.003`) while cache-miss and output rates are money-shaped (`0.30`, `1.98`), so a
  /// single fixed precision would either round the small ones to zero or leave `0.3` looking unlike
  /// its neighbours.
  private func priceText(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 4
    formatter.roundingMode = .halfUp
    return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
  }
}

// Previews use `PreviewProvider` rather than `#Preview`: the `#Preview` macro is implemented by the
// `PreviewsMacros` plugin, which ships with Xcode, and this repo builds with Command Line Tools only
// — expanding it there fails with "plugin for module 'PreviewsMacros' not found". Do not rewrite
// these as `#Preview` unless that plugin becomes available.
struct RateNowPanelPreviews: PreviewProvider {
  static var previews: some View {
    VStack(alignment: .leading, spacing: 14) {
      RateNowPanel(display: peak)
      Divider()
      RateNowPanel(display: offPeakHoliday)
      Divider()
      RateNowPanel(display: nil)
    }
    .padding(14)
    .frame(width: 320)
  }

  private static var peak: RateNowDisplay {
    RateNowDisplay(
      periodLabel: "Peak",
      multiplierLabel: "full price",
      isHoliday: false,
      holidayNote: nil,
      windowEndsLocal: "11:00",
      countdown: "2h 14m",
      nextTransitionLocal: "Thu 11:00",
      currency: "USD",
      models: [
        rate("deepseek-flash", hit: "0.006", miss: "0.30", output: "1.20"),
        rate("deepseek-v4-pro", hit: "0.044", miss: "1.32", output: "3.96"),
      ]
    )
  }

  private static var offPeakHoliday: RateNowDisplay {
    RateNowDisplay(
      periodLabel: "Off-peak",
      multiplierLabel: "50% off",
      isHoliday: true,
      holidayNote: "CN public holiday",
      windowEndsLocal: "06:00",
      countdown: "3h 2m",
      nextTransitionLocal: "Fri 06:00",
      currency: "USD",
      models: [
        rate("deepseek-flash", hit: "0.003", miss: "0.15", output: "0.60"),
        rate("deepseek-v4-pro", hit: "0.022", miss: "0.66", output: "1.98"),
      ]
    )
  }

  private static func rate(
    _ model: String,
    hit: String,
    miss: String,
    output: String
  ) -> ModelRate {
    ModelRate(
      model: model,
      cacheHit: decimal(hit),
      cacheMiss: decimal(miss),
      output: decimal(output)
    )
  }

  private static func decimal(_ raw: String) -> Decimal {
    Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) ?? .zero
  }
}
