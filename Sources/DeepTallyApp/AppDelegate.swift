// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DeepTallyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItemController: StatusItemController?
  private var model: AppModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchLog.record()
    installMainMenu()

    let model = AppModel(environment: AppEnvironment())
    self.model = model
    self.statusItemController = StatusItemController(model: model)
    model.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    model?.stop()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// An accessory app (`LSUIElement`) draws no menu bar of its own, but a main menu still supplies the
  /// standard key equivalents: without one, ⌘Q does nothing and the popover's Quit button is the only
  /// way out (`make kill` covers the development case). Kept to that single item — everything else in
  /// a default AppKit menu would be either dead or wrong for an app with no documents and no windows.
  private func installMainMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit DeepTally",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    NSApp.mainMenu = mainMenu
  }
}
