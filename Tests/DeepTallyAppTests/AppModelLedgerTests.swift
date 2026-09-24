// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// The ledger-backed menu bar metrics: what each mode renders, that a settings change re-renders
/// without a relaunch, that an import updates the number, and that a failed import never blanks it.
@Suite("App model ledger metrics", .serialized)
@MainActor
struct AppModelLedgerTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.ledger"

  /// One record on the fixture's clock, so it is inside the fixture's local (UTC) day.
  private func todayRecord(
    in fixture: AppModelFixture,
    cacheHitTokens: Int = 750,
    cacheMissTokens: Int = 250,
    cost: String
  ) -> OpenCodeImporter.ImportedRecord {
    importedRecord(
      at: fixture.clock.now, cacheHitTokens: cacheHitTokens, cacheMissTokens: cacheMissTokens,
      costUSD: decimal(cost))
  }

  @Test("today's spend is imported at launch and rendered the way the balance is")
  func todaySpendIsImportedAndRendered() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([todayRecord(in: fixture, cost: "0.42")])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await settleRefresh(model)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }

      model.settings.menuBarMetric = .todaySpend
      #expect(model.todaySpendText == "$0.42")
      #expect(model.menuBarLabel == "$0.42")
      #expect(model.menuBarPresentation.title == "$0.42")
      // The balance is fetched and rendered from its own path, untouched by the ledger.
      #expect(model.balanceState?.amountText == "$12.34")
    }
  }

  @Test("zero spend is $0.00, not an em dash")
  func zeroSpendIsAZero() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      // No records offered: the ledger is read and is empty, which is a fact, not a missing number.
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }

      model.settings.menuBarMetric = .todaySpend
      #expect(model.menuBarLabel == "$0.00")
    }
  }

  @Test("the cache-hit rate is the trailing 30 days, and an em dash when nothing can be divided")
  func cacheHitRateRendering() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([
        todayRecord(in: fixture, cacheHitTokens: 620, cacheMissTokens: 380, cost: "0.18"),
        // Well outside the 30-day window: counting it would drag the rate to 12%.
        importedRecord(
          at: fixture.clock.now.addingTimeInterval(-40 * 86_400), cacheHitTokens: 0,
          cacheMissTokens: 4_000, costUSD: decimal("0.05")),
      ])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }
      model.settings.menuBarMetric = .cacheHitRate

      // 620 hits over the 1000 prompt tokens of the last 30 days.
      #expect(model.cacheHitRateText == "62%")
      #expect(model.menuBarLabel == "62%")
    }

    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([
        todayRecord(in: fixture, cacheHitTokens: 0, cacheMissTokens: 0, cost: "0.11")
      ])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }
      model.settings.menuBarMetric = .cacheHitRate

      // No prompt tokens in the window: the rate is unknown, and 0% would claim the cache missed
      // everything. The spend behind it is still real.
      #expect(model.cacheHitRateText == "—")
      #expect(model.menuBarLabel == "—")
      #expect(model.todaySpendText == "$0.11")
    }
  }

  @Test("switching the metric re-renders without a relaunch, and the balance comes back")
  func switchingMetricReRenders() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([todayRecord(in: fixture, cost: "0.42")])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await settleRefresh(model)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }
      #expect(model.menuBarLabel == "$12.34")

      model.settings.menuBarMetric = .todaySpend
      #expect(model.menuBarLabel == "$0.42")

      model.settings.menuBarMetric = .cacheHitRate
      #expect(model.menuBarLabel == "75%")

      model.settings.menuBarMetric = .balance
      #expect(model.menuBarLabel == "$12.34")
    }
  }

  @Test("a metric that needs the ledger gets a pass as soon as it is selected")
  func selectingALedgerMetricStartsAPass() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      // No `start()`: nothing has imported yet, so the label would stay an em dash until the fifteen
      // minute tick. Selecting the metric is what has to fetch it.
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model
      #expect(model.localUsage == nil)

      model.settings.menuBarMetric = .todaySpend

      await waitUntil("the pass the metric change started") { model.localUsage != nil }
      #expect(model.menuBarLabel == "$0.00")
      #expect(fixture.usageSource.scanCount == 1)
    }
  }

  @Test("a later import updates the label on the fifteen-minute tick")
  func laterImportUpdatesTheLabel() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([todayRecord(in: fixture, cost: "0.42")])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }
      model.settings.menuBarMetric = .todaySpend
      #expect(model.menuBarLabel == "$0.42")

      // The cadence is fixed, documented and not the balance poll's.
      #expect(fixture.scheduling.ledgerInterval == 900)

      fixture.usageSource.offer([
        importedRecord(at: fixture.clock.now.addingTimeInterval(60), costUSD: decimal("0.58"))
      ])
      fixture.scheduling.fireLedgerTick()

      await waitUntil("the tick's import to land") { model.menuBarLabel == "$1.00" }
      #expect(model.localUsageNote == nil)
    }
  }

  @Test("a failed import keeps the last good number and states it quietly, without a banner")
  func failedImportKeepsTheLastGoodLabel() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([todayRecord(in: fixture, cost: "0.42")])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await settleRefresh(model)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }
      model.settings.menuBarMetric = .todaySpend
      #expect(model.menuBarLabel == "$0.42")
      #expect(model.localUsageNote == nil)

      fixture.usageSource.failFromNowOn()
      fixture.scheduling.fireLedgerTick()
      await waitUntil("the failed pass") { model.localUsageProblem != nil }

      // The number that was true a moment ago stays; blanking it would claim nothing was spent.
      #expect(model.menuBarLabel == "$0.42")
      #expect(model.localUsageNote == "Local usage is not being imported yet.")
      // Fail-soft means quiet: a missing opencode database is not an error the user has to clear.
      #expect(model.banners.isEmpty)
      // The balance path is untouched by any of it.
      #expect(model.balanceState?.amountText == "$12.34")
    }
  }

  @Test("with no readable ledger the metrics stay em dashes and nothing is claimed")
  func unreadableLedgerShowsNoNumbers() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      // `/dev/null` is not a directory: the ledger's folder cannot be created under it.
      let fixture = makeFixture(
        defaults: defaults,
        ledgerURL: URL(fileURLWithPath: "/dev/null/deeptally/ledger.sqlite"))
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the failed ledger pass") { model.localUsageProblem != nil }

      model.settings.menuBarMetric = .todaySpend
      #expect(model.todaySpendText == nil)
      #expect(model.menuBarLabel == "—")

      model.settings.menuBarMetric = .cacheHitRate
      #expect(model.menuBarLabel == "—")
      #expect(model.localUsageNote == "Local usage is not being imported yet.")
      #expect(model.banners.isEmpty)
    }
  }

  @Test("two triggers in a row run one import, not two")
  func overlappingTriggersRunOnePass() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      let model = fixture.model

      // The launch pass and the fifteen-minute tick are the same call; both may arrive while a scan
      // is still reading a large database, and the second one must not join it.
      model.refreshLocalUsage()
      model.refreshLocalUsage()

      await waitUntil("the single pass") { model.localUsage != nil }
      #expect(fixture.usageSource.scanCount == 1)
    }
  }
}
