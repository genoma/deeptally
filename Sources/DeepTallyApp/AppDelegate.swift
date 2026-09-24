// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DeepTallyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItemController: StatusItemController?
  private var model: AppModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchLog.record()
    let model = AppModel()
    self.model = model
    self.statusItemController = StatusItemController(model: model)
    model.refresh()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
