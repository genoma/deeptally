// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// When to ask DeepSeek for the balance again. Pure arithmetic: the caller owns the timer, the task
/// and the system randomness.
///
/// The baseline is the steady `interval`. Every failed attempt doubles the wait from there, so an
/// outage or a sleeping laptop does not turn into a request storm, and the wait never exceeds
/// `maxBackoff`. Jitter is only ever additive, so the effective interval never falls below
/// `interval`; `jitterFraction` in `0...1` scales it, which keeps callers and tests deterministic.
public struct PollingPlan: Sendable {
  /// Seconds between refreshes while everything succeeds.
  public let interval: TimeInterval
  /// The largest offset jitter may add to a refresh, in seconds.
  public let jitter: TimeInterval
  /// The ceiling for the backoff, in seconds. Jitter rides on top of it.
  public let maxBackoff: TimeInterval

  public init(
    interval: TimeInterval = 1200,
    jitter: TimeInterval = 60,
    maxBackoff: TimeInterval = 3600
  ) {
    self.interval = interval
    self.jitter = jitter
    self.maxBackoff = maxBackoff
  }

  /// `interval * 2^attempt`, capped at `maxBackoff`: attempt 0 is the steady interval, 1 is twice
  /// it, 2 four times, and so on. Negative attempts count as attempt 0.
  public func backoff(attempt: Int) -> TimeInterval {
    let exponent = min(max(attempt, 0), Self.maximumExponent)
    return min(interval * pow(2, Double(exponent)), maxBackoff)
  }

  /// The instant of the next refresh: `now` plus the backoff plus up to `jitter` seconds, scaled by
  /// `jitterFraction`. The fraction is clamped to `0...1`, so a caller that passes something else
  /// cannot poll earlier than `interval`; identical inputs always produce an identical instant.
  public func nextRefresh(after now: Date, attempt: Int, jitterFraction: Double) -> Date {
    let fraction = jitterFraction.isFinite ? min(max(jitterFraction, 0), 1) : 0
    return now.addingTimeInterval(backoff(attempt: attempt) + jitter * fraction)
  }

  /// 2^32 already dwarfs any sane `maxBackoff`; the clamp keeps `pow` from overflowing to infinity
  /// on an absurd attempt count.
  private static let maximumExponent = 32
}
