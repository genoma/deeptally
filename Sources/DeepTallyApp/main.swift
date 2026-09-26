// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin

// Step 2 spike commands run headless and exit before any UI is created (see Spikes.swift).
if CommandLine.arguments.dropFirst().first == "--spike" {
  Spikes.run(CommandLine.arguments.dropFirst(2))
}

// Step 6: `--uninstall` is the same code the popover's button runs, headless and before any UI
// exists, so Scripts/uninstall.sh can drive it (see UninstallCommand.swift).
if CommandLine.arguments.dropFirst().first == "--uninstall" {
  exit(UninstallCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}

// Top-level code in a main.swift entry point is main-actor isolated; assumeIsolated keeps
// Swift 6 strict concurrency happy without spawning a task.
MainActor.assumeIsolated {
  let application = NSApplication.shared
  let delegate = AppDelegate()
  application.delegate = delegate
  application.setActivationPolicy(.accessory)
  application.run()
}
