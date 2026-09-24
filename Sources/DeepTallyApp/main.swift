// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// Top-level code in a main.swift entry point is main-actor isolated; assumeIsolated keeps
// Swift 6 strict concurrency happy without spawning a task.
MainActor.assumeIsolated {
  let application = NSApplication.shared
  let delegate = AppDelegate()
  application.delegate = delegate
  application.setActivationPolicy(.accessory)
  application.run()
}
