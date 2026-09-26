// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The app's two timers — the next poll and the staleness tick — behind one seam.
///
/// The model computes every delay, tolerance and interval; this only waits for them. That split is what
/// makes the polling behaviour assertable: a stub records the delay and the leeway the model asked for,
/// so "the backstop widens on battery, carries a 10% tolerance, and doubles per failure up to the cap"
/// is an assertion instead of a test that sleeps out half an hour, and a tick can be fired the moment
/// the test wants one.
@MainActor
protocol AppScheduling: AnyObject {
  /// Runs `run` after `delay` seconds, replacing a refresh that has not fired yet. `tolerance` is the
  /// leeway the system may add so this wake-up can be coalesced with other work.
  func scheduleRefresh(
    after delay: TimeInterval, tolerance: TimeInterval, _ run: @escaping @MainActor () -> Void)
  /// Runs `tick` every `interval` seconds until ``cancel()``.
  func startTicker(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void)
  /// Cancels the pending refresh and the ticker.
  func cancel()
}

/// The shipping scheduler: one wall-clock dispatch timer re-armed per cycle, plus the ticker task.
///
/// A one-shot `DispatchSourceTimer` armed with `wallDeadline:` is the timer whose semantics Apple
/// actually documents for this use: the wall clock keeps advancing across system sleep (so an overdue
/// backstop is overdue at wake instead of restarting its count), and `leeway` is the documented knob
/// for letting the system coalesce the wake-up (clamped to half the interval for repeating timers; this
/// one is re-armed per cycle, never repeating). A run-loop `Timer` was rejected because it can stall
/// while the run loop is in a mode that is not monitoring it.
@MainActor
final class TaskAppScheduler: AppScheduling {
  private var refreshTimer: DispatchSourceTimer?
  private var tickerTask: Task<Void, Never>?

  func scheduleRefresh(
    after delay: TimeInterval, tolerance: TimeInterval, _ run: @escaping @MainActor () -> Void
  ) {
    // Cancelling is the whole of "replacing": the old source may already have fired, and a cancelled
    // source never fires again.
    refreshTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    let nanoseconds = Int(max(1, delay) * 1_000_000_000)
    let leeway = Int(max(1, tolerance) * 1_000_000_000)
    timer.schedule(
      wallDeadline: .now() + .nanoseconds(nanoseconds), leeway: .nanoseconds(leeway))
    // The source is created with the main queue as its target, so this handler is already on the main
    // thread and the main actor's isolated callback can run without a hop.
    timer.setEventHandler {
      MainActor.assumeIsolated { run() }
    }
    refreshTimer = timer
    timer.resume()
  }

  func startTicker(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
    tickerTask?.cancel()
    tickerTask = repeating(every: interval, tick)
  }

  func cancel() {
    refreshTimer?.cancel()
    refreshTimer = nil
    tickerTask?.cancel()
    tickerTask = nil
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
