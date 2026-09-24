// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Testing

@testable import DeepTallyApp

/// What the app says when a pass imports a row the price table cannot price: one calm note (never a
/// banner), and the priced rows keep their numbers. Without it the menu bar can show $0.00 for real
/// spend with nothing on screen saying why.
@Suite("App model unpriced import note", .serialized)
@MainActor
struct AppModelPricingNoteTests {
  /// This suite's own stable `UserDefaults` domain; see ``withIsolatedDefaults``.
  private static let domain = "io.github.genoma.deeptally.tests.appmodel.pricingnote"

  /// An id the shipped table does not list, not even as an alias.
  private static let unpricedModel = "deepseek-v5-unreleased"

  @Test("an offered row whose model has no price produces the note, and no banner")
  func unpricedRowProducesNote() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([
        importedRecord(
          at: fixture.clock.now, model: Self.unpricedModel, costUSD: .zero)
      ])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }

      let note = try #require(model.localUsageNote)
      #expect(note.contains("1 local row"))
      #expect(note.contains(Self.unpricedModel))
      #expect(note.contains("the price table"))
      #expect(note.contains("zero cost"))
      // The import itself succeeded, and the note is not banner noise.
      #expect(model.localUsageProblem == nil)
      #expect(model.banners.isEmpty)
    }
  }

  @Test("a fully priced import produces no note")
  func fullyPricedImportHasNoNote() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([
        importedRecord(at: fixture.clock.now, model: "deepseek-flash", costUSD: decimal("0.42"))
      ])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }

      #expect(model.localUsageNote == nil)
      #expect(model.localUsageProblem == nil)
      #expect(model.banners.isEmpty)
    }
  }

  @Test("the metrics still show the priced rows' values while the note is up")
  func metricsKeepPricedValues() async throws {
    try await withIsolatedDefaults(Self.domain) { defaults in
      let fixture = makeFixture(defaults: defaults)
      fixture.usageSource.offer([
        importedRecord(at: fixture.clock.now, model: "deepseek-flash", costUSD: decimal("0.42")),
        importedRecord(at: fixture.clock.now, model: Self.unpricedModel, costUSD: .zero),
      ])
      let model = fixture.model

      model.start(observingSystemEvents: false)
      await waitUntil("the launch ledger pass") { model.localUsage != nil }
      model.settings.menuBarMetric = .todaySpend

      // The note does not suppress or zero anything: the priced row's $0.42 is what the menu bar
      // shows, and the note explains what the unpriced row is missing from it.
      #expect(model.todaySpendText == "$0.42")
      #expect(model.menuBarLabel == "$0.42")
      #expect(model.localUsageNote != nil)
    }
  }
}
