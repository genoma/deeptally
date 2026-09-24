// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

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
      button.title = model.menuBarLabel
      button.target = self
      button.action = #selector(togglePopover)
    }

    model.onUpdate = { [weak self] in
      self?.syncLabel()
    }
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
}
