// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The app's two timers — the next poll and the staleness tick — behind one seam.
///
/// The model computes every delay; this only waits for it. That split is what makes the polling
/// behaviour assertable: a stub records the delay the model asked for, so "the wait doubles per
/// failure up to the cap and one success resets it" is an assertion instead of a test that sleeps out
/// twenty minutes, and a tick can be fired the moment the test wants one.
@MainActor
protocol AppScheduling: AnyObject {
  /// Runs `run` after `delay` seconds, replacing a refresh that has not fired yet.
  func scheduleRefresh(after delay: TimeInterval, _ run: @escaping @MainActor () -> Void)
  /// Runs `tick` every `interval` seconds until ``cancel()``.
  func startTicker(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void)
  /// Cancels the pending refresh and the ticker.
  func cancel()
}

/// The shipping scheduler: the same two `Task`s `AppModel` ran before they were behind a seam.
@MainActor
final class TaskAppScheduler: AppScheduling {
  private var refreshTask: Task<Void, Never>?
  private var tickerTask: Task<Void, Never>?

  func scheduleRefresh(after delay: TimeInterval, _ run: @escaping @MainActor () -> Void) {
    refreshTask?.cancel()
    refreshTask = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      run()
    }
  }

  func startTicker(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
    tickerTask?.cancel()
    tickerTask = repeating(every: interval, tick)
  }

  func cancel() {
    refreshTask?.cancel()
    tickerTask?.cancel()
  }

  /// The ticker loop. It does not capture the scheduler: the scheduler owns the task, and a finished
  /// task would otherwise pin a cancelled one in place.
  private func repeating(
    every interval: TimeInterval,
    _ body: @escaping @MainActor () -> Void
  ) -> Task<Void, Never> {
    Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        body()
      }
    }
  }
}
