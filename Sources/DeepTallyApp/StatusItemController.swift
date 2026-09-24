// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import SwiftUI

/// The menu bar presence: one status item, one popover, and a title that mirrors the model.
///
/// `NSStatusItem` and not `MenuBarExtra`: on macOS 26+ an accessory app that only has a
/// `MenuBarExtra` can be killed silently when the user disables the item in Control Center.
@MainActor
final class StatusItemController {
  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private let model: AppModel

  init(model: AppModel) {
    self.model = model

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    popover = NSPopover()
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 320, height: 420)
    popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

    if let button = statusItem.button {
      // Shipped template glyph, copied into Contents/Resources by Scripts/bundle.sh.
      // The name ends in "Template", so AppKit tints it for light/dark menu bars.
      if let glyph = NSImage(named: "MenuBarIconTemplate") {
        glyph.isTemplate = true
        button.image = glyph
        button.imagePosition = .imageLeading
      }
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

  private func syncLabel() {
    statusItem.button?.title = model.menuBarLabel
  }

  /// Observation rather than a callback from the model: the title follows `menuBarLabel`, which
  /// includes the user's `menuBarMetric` setting, and it has to react to a refresh the model started
  /// on its own timer. Re-armed after every change, so one subscription covers the process lifetime.
  private func observeLabel() {
    withObservationTracking {
      _ = model.menuBarLabel
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.syncLabel()
        self?.observeLabel()
      }
    }
  }
}
