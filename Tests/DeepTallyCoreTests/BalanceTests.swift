// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

/// A fixed instant. The tests never read the wall clock, so they are deterministic.
private let now = Date(timeIntervalSince1970: 1_770_000_000)

/// One currency entry, as the balance endpoint returns it.
private func balance(
  _ amount: String,
  currency: String = "USD",
  isAvailable: Bool = true
) -> Balance {
  let total = Decimal.parse(amount)
  return Balance(
    isAvailable: isAvailable,
    infos: [
      BalanceInfo(
        currency: currency, totalBalance: total, grantedBalance: .zero, toppedUpBalance: total)
    ]
  )
}

/// An instant on the local wall clock, whatever time zone the test machine sits in.
private func localInstant(hour: Int, minute: Int) -> Date {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let components = DateComponents(
    calendar: calendar, year: 2026, month: 1, day: 15, hour: hour, minute: minute)
  return calendar.date(from: components)!
}

@Suite("Balance state")
struct BalanceStateTests {
  private let monitor = BalanceMonitor()

  @Test("formats USD and CNY with their symbol and an unknown currency with its code")
  func currencySymbols() {
    let usd = monitor.evaluate(balance: balance("13.49"), lastSuccess: now, now: now)
    #expect(usd.amountText == "$13.49")
    #expect(usd.currency == "USD")

    let cny = monitor.evaluate(balance: balance("98", currency: "CNY"), lastSuccess: now, now: now)
    #expect(cny.amountText == "¥98.00")
    #expect(cny.currency == "CNY")

    let chf = monitor.evaluate(balance: balance("12", currency: "CHF"), lastSuccess: now, now: now)
    #expect(chf.amountText == "CHF 12.00")
    #expect(chf.currency == "CHF")
  }

  @Test("keeps two decimals and no grouping separator")
  func amountFormatting() {
    let rounded = monitor.evaluate(balance: balance("12345.678"), lastSuccess: now, now: now)
    #expect(rounded.amountText == "$12345.68")

    let zero = monitor.evaluate(balance: balance("0"), lastSuccess: now, now: now)
    #expect(zero.amountText == "$0.00")
  }

  @Test(
    "low is strict: below the threshold is low, the threshold itself is not",
    arguments: [("1.99", true), ("2.00", false), ("2.01", false)])
  func thresholdBoundaries(rawAmount: String, expected: Bool) {
    let state = monitor.evaluate(balance: balance(rawAmount), lastSuccess: now, now: now)
    #expect(state.isLow == expected)
  }

  @Test("honours a custom threshold")
  func customThreshold() {
    let monitor = BalanceMonitor(lowBalanceThreshold: 5)
    #expect(!monitor.evaluate(balance: balance("5.00"), lastSuccess: now, now: now).isLow)
    #expect(monitor.evaluate(balance: balance("4.99"), lastSuccess: now, now: now).isLow)
  }

  @Test("fresh at exactly staleAfter, stale one second later")
  func stalenessBoundaries() {
    let boundary = monitor.evaluate(
      balance: balance("13.49"), lastSuccess: now.addingTimeInterval(-3600), now: now)
    #expect(!boundary.isStale)
    #expect(boundary.ageText == "1h 0m old")

    let past = monitor.evaluate(
      balance: balance("13.49"), lastSuccess: now.addingTimeInterval(-3601), now: now)
    #expect(past.isStale)
    #expect(past.ageText == "1h 0m old")
  }

  @Test("honours a custom staleAfter")
  func customStaleAfter() {
    let monitor = BalanceMonitor(staleAfter: 120)
    let fresh = monitor.evaluate(
      balance: balance("13.49"), lastSuccess: now.addingTimeInterval(-120), now: now)
    #expect(!fresh.isStale)

    let stale = monitor.evaluate(
      balance: balance("13.49"), lastSuccess: now.addingTimeInterval(-121), now: now)
    #expect(stale.isStale)
  }

  @Test("under an hour shows the fetch clock time in local time")
  func ageTextUnderAnHour() {
    let fetched = localInstant(hour: 22, minute: 41)
    let state = monitor.evaluate(
      balance: balance("13.49"), lastSuccess: fetched, now: fetched.addingTimeInterval(45 * 60))
    #expect(state.ageText == "as of 22:41")
  }

  @Test("an hour or more is shown as whole hours and minutes, floored and never in days")
  func ageTextFromAnHour() {
    let cases: [(TimeInterval, String)] = [
      (3 * 3600 + 12 * 60, "3h 12m old"),
      (3 * 3600 + 12 * 60 + 59, "3h 12m old"),
      (27 * 3600 + 4 * 60, "27h 4m old"),
      (48 * 3600, "48h 0m old"),
    ]
    for (elapsed, expected) in cases {
      let state = monitor.evaluate(
        balance: balance("13.49"), lastSuccess: now.addingTimeInterval(-elapsed), now: now)
      #expect(state.ageText == expected)
    }
  }

  @Test("no data at all: nothing to show, and nothing fetched yet")
  func noData() {
    let state = monitor.evaluate(balance: nil, lastSuccess: nil, now: now)
    #expect(state.amountText == nil)
    #expect(state.currency == nil)
    #expect(!state.isAvailable)
    #expect(!state.isLow)
    #expect(!state.isStale)
    #expect(state.ageText == nil)
    #expect(state.statusText == "Nothing fetched yet.")
  }

  @Test("a balance without a timestamp renders, and has no age")
  func balanceWithoutTimestamp() {
    let state = monitor.evaluate(balance: balance("13.49"), lastSuccess: nil, now: now)
    #expect(state.amountText == "$13.49")
    #expect(!state.isStale)
    #expect(state.ageText == nil)
  }

  @Test("no balance after a successful fetch is not phrased as if nothing was fetched")
  func noBalanceWithTimestamp() {
    let state = monitor.evaluate(
      balance: nil, lastSuccess: now.addingTimeInterval(-7200), now: now)
    #expect(state.isStale)
    #expect(state.ageText == "2h 0m old")
    #expect(state.statusText == "No balance data.")
  }

  @Test("a balance response with no currency entries has nothing to format")
  func balanceWithoutEntries() {
    let state = monitor.evaluate(
      balance: Balance(isAvailable: true, infos: []), lastSuccess: now, now: now)
    #expect(state.amountText == nil)
    #expect(state.currency == nil)
    #expect(!state.isLow)
    #expect(state.statusText == "No balance details returned.")
  }

  @Test("surfaces DeepSeek's is_available flag")
  func unavailable() {
    let state = monitor.evaluate(
      balance: balance("13.49", isAvailable: false), lastSuccess: now, now: now)
    #expect(!state.isAvailable)
    #expect(state.statusText == "Balance unavailable — top up to keep requests running.")
  }

  @Test("a low balance is called out in the status line")
  func lowStatus() {
    let state = monitor.evaluate(balance: balance("0.50"), lastSuccess: now, now: now)
    #expect(state.isLow)
    #expect(state.statusText == "Low balance — top up to keep requests running.")
  }

  @Test("a stale balance is called out in the status line")
  func staleStatus() {
    let state = monitor.evaluate(
      balance: balance("13.49"), lastSuccess: now.addingTimeInterval(-7200), now: now)
    #expect(state.isStale)
    #expect(!state.isLow)
    #expect(state.statusText == "Balance is not up to date.")
  }

  @Test("uses the first currency entry when the API returns several")
  func firstEntryWins() {
    let state = monitor.evaluate(
      balance: Balance(
        isAvailable: true,
        infos: [
          BalanceInfo(
            currency: "CNY", totalBalance: Decimal.parse("98"), grantedBalance: .zero,
            toppedUpBalance: .zero),
          BalanceInfo(
            currency: "USD", totalBalance: Decimal.parse("13.49"), grantedBalance: .zero,
            toppedUpBalance: .zero),
        ]
      ),
      lastSuccess: now, now: now)
    #expect(state.amountText == "¥98.00")
    #expect(state.currency == "CNY")
  }
}

@Suite("Polling plan")
struct PollingPlanTests {
  @Test("defaults to a 20-minute refresh with a minute of jitter under an hour cap")
  func defaults() {
    let plan = PollingPlan()
    #expect(plan.interval == 1200)
    #expect(plan.jitter == 60)
    #expect(plan.maxBackoff == 3600)
  }

  @Test("backoff doubles from the interval and stops at maxBackoff")
  func backoffProgression() {
    let plan = PollingPlan()
    #expect(plan.backoff(attempt: 0) == 1200)
    #expect(plan.backoff(attempt: 1) == 2400)
    #expect(plan.backoff(attempt: 2) == 3600)
    #expect(plan.backoff(attempt: 9) == 3600)
  }

  @Test("keeps doubling below the cap and survives an absurd attempt count")
  func backoffBelowTheCap() {
    let plan = PollingPlan(interval: 100, jitter: 10, maxBackoff: 10_000)
    #expect(plan.backoff(attempt: 0) == 100)
    #expect(plan.backoff(attempt: 1) == 200)
    #expect(plan.backoff(attempt: 2) == 400)
    #expect(plan.backoff(attempt: 3) == 800)
    #expect(plan.backoff(attempt: 4) == 1600)
    #expect(plan.backoff(attempt: 1_000) == 10_000)
  }

  @Test("a negative attempt counts as the first one")
  func negativeAttempt() {
    let plan = PollingPlan()
    #expect(plan.backoff(attempt: -1) == 1200)
    #expect(
      plan.nextRefresh(after: now, attempt: -1, jitterFraction: 0)
        == now.addingTimeInterval(1200))
  }

  @Test("jitter is additive and scales linearly with the fraction")
  func jitterScales() {
    let plan = PollingPlan()
    #expect(
      plan.nextRefresh(after: now, attempt: 0, jitterFraction: 0) == now.addingTimeInterval(1200))
    #expect(
      plan.nextRefresh(after: now, attempt: 0, jitterFraction: 0.5) == now.addingTimeInterval(1230))
    #expect(
      plan.nextRefresh(after: now, attempt: 0, jitterFraction: 1) == now.addingTimeInterval(1260))
  }

  @Test("jitter never pulls a refresh earlier than the backoff, for any fraction")
  func jitterIsNeverNegative() {
    let plan = PollingPlan()
    for fraction in [0.0, 0.25, 0.5, 1.0] {
      for attempt in 0...3 {
        let delay = plan.nextRefresh(after: now, attempt: attempt, jitterFraction: fraction)
          .timeIntervalSince(now)
        #expect(delay >= plan.backoff(attempt: attempt))
        #expect(delay <= plan.backoff(attempt: attempt) + plan.jitter)
      }
    }
  }

  @Test(
    "the same inputs always produce the same instant",
    arguments: [0.0, 0.5, 1.0])
  func jitterIsDeterministic(fraction: Double) {
    let plan = PollingPlan()
    let first = plan.nextRefresh(after: now, attempt: 1, jitterFraction: fraction)
    let second = plan.nextRefresh(after: now, attempt: 1, jitterFraction: fraction)
    #expect(first == second)

    let added = first.timeIntervalSince(now) - plan.backoff(attempt: 1)
    #expect(added == plan.jitter * fraction)
  }

  @Test("clamps a fraction outside 0...1 instead of trusting the caller")
  func jitterIsClamped() {
    let plan = PollingPlan()
    #expect(
      plan.nextRefresh(after: now, attempt: 0, jitterFraction: 5) == now.addingTimeInterval(1260))
    #expect(
      plan.nextRefresh(after: now, attempt: 0, jitterFraction: -3) == now.addingTimeInterval(1200))
  }
}

@Suite("Notification policy")
struct NotificationPolicyTests {
  private let policy = NotificationPolicy()

  @Test("the first low reading notifies")
  func firstLowReading() {
    #expect(policy.shouldNotify(isLow: true, isStale: false, lastNotified: nil, now: now))
  }

  @Test("a balance that is not low never notifies, fresh or stale")
  func notLowNeverNotifies() {
    #expect(!policy.shouldNotify(isLow: false, isStale: false, lastNotified: nil, now: now))
    #expect(
      !policy.shouldNotify(
        isLow: false, isStale: true, lastNotified: now.addingTimeInterval(-999_999), now: now))
  }

  @Test("a stale balance alone does not notify")
  func staleAloneDoesNotNotify() {
    #expect(!policy.shouldNotify(isLow: false, isStale: true, lastNotified: nil, now: now))
  }

  @Test("silent inside the cooldown, alerting again exactly at it")
  func cooldownBoundaries() {
    let inside = now.addingTimeInterval(-43_199)
    #expect(!policy.shouldNotify(isLow: true, isStale: false, lastNotified: inside, now: now))

    let atTheEdge = now.addingTimeInterval(-43_200)
    #expect(policy.shouldNotify(isLow: true, isStale: false, lastNotified: atTheEdge, now: now))
  }

  @Test("honours a custom cooldown")
  func customCooldown() {
    let policy = NotificationPolicy(cooldown: 600)
    #expect(
      !policy.shouldNotify(
        isLow: true, isStale: false, lastNotified: now.addingTimeInterval(-599), now: now))
    #expect(
      policy.shouldNotify(
        isLow: true, isStale: false, lastNotified: now.addingTimeInterval(-600), now: now))
  }

  @Test("a stale, not-low balance state does not notify")
  func staleStateDoesNotNotify() {
    let state = BalanceMonitor().evaluate(
      balance: balance("13.49"), lastSuccess: now.addingTimeInterval(-7200), now: now)
    #expect(state.isStale)
    #expect(
      !policy.shouldNotify(
        isLow: state.isLow, isStale: state.isStale, lastNotified: nil, now: now))
  }
}
