// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

// The commands live in Commands.swift; this file is only the process entry point, so the CLI has
// exactly one `exit`.
exit(await CLI.run(Array(CommandLine.arguments.dropFirst())))
