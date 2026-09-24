// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import SwiftUI

/// The menu bar presence: one status item, one popover, and a title that mirrors the model.
///
/// `NSStatusItem` and not `MenuBarExtra`: on macOS 26+ an accessory app that only has a
/// `MenuBarExtra` can be killed silently when the user disables the item in Control Center.
///
/// The shipped glyph gives way to a warning triangle while the balance is low: that is the plan's
/// required fallback, because macOS may never deliver the notification the user asked for.
@MainActor
final class StatusItemController {
  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private let model: AppModel

  /// The shipped gauge, applied while the balance is fine. Template, so AppKit tints it for light
  /// and dark menu bars.
  private let normalGlyph: NSImage?
  /// The low-balance fallback. Template too, so it tints like the glyph it replaces.
  private let lowBalanceGlyph: NSImage?

  init(model: AppModel) {
    self.model = model

    // The shipped template glyph is copied into Contents/Resources by Scripts/bundle.sh; the name
    // ends in "Template", so AppKit tints it for light/dark menu bars.
    normalGlyph = NSImage(named: "MenuBarIconTemplate")
    normalGlyph?.isTemplate = true
    lowBalanceGlyph = NSImage(
      systemSymbolName: "exclamationmark.triangle.fill",
      accessibilityDescription: "Low DeepSeek balance")
    lowBalanceGlyph?.isTemplate = true

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    popover = NSPopover()
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 320, height: 420)
    popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

    if let button = statusItem.button {
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(togglePopover)
    }

    syncLabel()
    observeLabel()
  }

  @objc private func togglePopover() {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      showPopover()
    }
  }

  private func showPopover() {
    guard let button = statusItem.button else { return }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    NSApp.activate(ignoringOtherApps: true)
  }

  /// The button's whole presentation comes from the model, so the warning glyph, the title and the
  /// tooltip all say the same thing `--spike render-popover` reports.
  private func syncLabel() {
    guard let button = statusItem.button else { return }
    let presentation = model.menuBarPresentation
    button.title = presentation.title
    button.image =
      presentation.showsLowBalanceWarning ? (lowBalanceGlyph ?? normalGlyph) : normalGlyph
    button.toolTip = presentation.tooltip
  }

  /// Observation rather than a callback from the model: the title follows `menuBarLabel`, which
  /// includes the user's `menuBarMetric` setting, and it has to react to a refresh the model started
  /// on its own timer. Re-armed after every change, so one subscription covers the process lifetime.
  private func observeLabel() {
    withObservationTracking {
      _ = model.menuBarPresentation
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.syncLabel()
        self?.observeLabel()
      }
    }
  }
}
