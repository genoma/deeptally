// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

// MARK: - Fixtures

/// Fixed instants keep the weekday/weekend cases readable: `2026-09-28` is a Monday, `2026-09-25` a
/// Friday and `2026-10-03`/`2026-10-04` the weekend.
private func instant(_ iso8601: String) -> Date {
  guard let date = ISO8601DateFormatter().date(from: iso8601) else {
    fatalError("invalid fixture instant: \(iso8601)")
  }
  return date
}

private let flashPrice = ModelPrice(
  model: "deepseek-flash",
  cacheHitUSDPerMillion: Decimal.parse("0.006"),
  cacheMissUSDPerMillion: Decimal.parse("0.30"),
  outputUSDPerMillion: Decimal.parse("1.20")
)

private let proPrice = ModelPrice(
  model: "deepseek-v4-pro",
  cacheHitUSDPerMillion: Decimal.parse("0.044"),
  cacheMissUSDPerMillion: Decimal.parse("1.32"),
  outputUSDPerMillion: Decimal.parse("3.96")
)

private func fixtureTable(
  version: String = "test",
  offPeakMultiplier: String = "0.5",
  windows: [PeakWindow] = [
    PeakWindow(startHourUTC: 1, endHourUTC: 4),
    PeakWindow(startHourUTC: 6, endHourUTC: 10),
  ],
  holidays: [String] = [],
  models: [ModelPrice] = [flashPrice, proPrice]
) -> PriceTable {
  PriceTable(
    version: version,
    currency: "USD",
    effectiveFrom: "2026-09-24",
    offPeakMultiplier: Decimal.parse(offPeakMultiplier),
    peakWindowsUTC: windows,
    holidays: holidays,
    models: models
  )
}

/// One row as raw JSON, so a price string can be spelled exactly as a user might type it. The point
/// of the strictness tests below is that `"TBD"`, `""` and `"0,30"` are strings, not numbers.
private func fixtureJSON(
  cacheHit: String = "0.006",
  cacheMiss: String = "0.30",
  output: String = "1.20",
  offPeakMultiplier: String = "0.5"
) -> String {
  """
  {
    "version": "fixture",
    "currency": "USD",
    "effective_from": "2026-09-24",
    "off_peak_multiplier": "\(offPeakMultiplier)",
    "peak_windows_utc": [{ "start_hour_utc": 1, "end_hour_utc": 4 }],
    "holidays": [],
    "models": [
      {
        "model": "deepseek-flash",
        "aliases": ["deepseek-v4-flash"],
        "cache_hit_usd_per_million": "\(cacheHit)",
        "cache_miss_usd_per_million": "\(cacheMiss)",
        "output_usd_per_million": "\(output)"
      }
    ]
  }
  """
}

/// A class in this test bundle, which carries no resources: `Bundle(for:)` on it is how the
/// "shipped table is missing" path is exercised without touching the real package.
private final class TestBundleAnchor: NSObject {}

private func makeTemporaryHome() throws -> URL {
  let home = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "deeptally-pricing-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: home.appending(path: ".config/deeptally"), withIntermediateDirectories: true)
  return home
}

private func writeOverride(_ json: String, in home: URL) throws {
  try Data(json.utf8).write(to: home.appending(path: PriceTableLoader.overrideRelativePath))
}

private func writeOverride(_ table: PriceTable, in home: URL) throws {
  try JSONEncoder().encode(table)
    .write(to: home.appending(path: PriceTableLoader.overrideRelativePath))
}

private func isISODay(_ value: String) -> Bool {
  let parts = value.split(separator: "-")
  guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else {
    return false
  }
  return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
}

// MARK: - Loader

@Suite("Price table loader")
struct PriceTableLoaderTests {
  @Test("loads and validates the shipped table")
  func loadsShippedTable() throws {
    let table = try PriceTableLoader().loadBundled()

    #expect(table.version == "2026-09-24")
    #expect(table.currency == "USD")
    #expect(table.effectiveFrom == "2026-09-24")
    #expect(table.offPeakMultiplier == Decimal.parse("0.5"))
    #expect(
      table.peakWindowsUTC == [
        PeakWindow(startHourUTC: 1, endHourUTC: 4),
        PeakWindow(startHourUTC: 6, endHourUTC: 10),
      ])
    #expect(table.models.count == 2)

    let flash = try #require(table.price(forModel: "deepseek-flash"))
    #expect(flash.cacheHitUSDPerMillion == Decimal.parse("0.006"))
    #expect(flash.cacheMissUSDPerMillion == Decimal.parse("0.30"))
    #expect(flash.outputUSDPerMillion == Decimal.parse("1.20"))

    let pro = try #require(table.price(forModel: "deepseek-v4-pro"))
    #expect(pro.cacheHitUSDPerMillion == Decimal.parse("0.044"))
    #expect(pro.cacheMissUSDPerMillion == Decimal.parse("1.32"))
    #expect(pro.outputUSDPerMillion == Decimal.parse("3.96"))
  }

  @Test("rejects a table without models")
  func rejectsTableWithoutModels() {
    let empty = fixtureTable(models: [])
    #expect(throws: PricingDataError.noModels) { try PriceTableLoader.validate(empty) }
  }

  @Test("rejects an off-peak multiplier outside (0, 1]")
  func rejectsBadMultiplier() {
    for raw in ["0", "-0.5", "1.01", "2"] {
      let broken = fixtureTable(offPeakMultiplier: raw)
      #expect(throws: PricingDataError.invalidOffPeakMultiplier(Decimal.parse(raw))) {
        try PriceTableLoader.validate(broken)
      }
    }
  }

  /// The finding this covers: a price decoded through the tolerant balance parser became zero, the
  /// row still resolved, and nothing reported the model as unpriced.
  @Test("junk in a price field fails the decode instead of becoming zero")
  func rejectsUnparsablePrices() throws {
    for raw in ["0.30 USD", "", "TBD", "0,30"] {
      let error = #expect(throws: PricingDataError.self) {
        try PriceTableLoader.decode(Data(fixtureJSON(cacheMiss: raw).utf8), name: "fixture-inline")
      }
      let sentence = try #require(error?.userFacingSentence, "\"\(raw)\" must be rejected")
      #expect(sentence.contains("cache_miss_usd_per_million"), "\"\(raw)\" must name the field")
      #expect(sentence.contains("deepseek-flash"), "\"\(raw)\" must name the model")
    }
  }

  @Test("every price field is read strictly, not just the cache-miss one")
  func rejectsUnparsableAmountInEveryField() throws {
    for (field, json) in [
      (PriceField.cacheHit, fixtureJSON(cacheHit: "TBD")),
      (.cacheMiss, fixtureJSON(cacheMiss: "TBD")),
      (.output, fixtureJSON(output: "TBD")),
    ] {
      let error = #expect(throws: PricingDataError.self) {
        try PriceTableLoader.decode(Data(json.utf8), name: "fixture-inline")
      }
      let sentence = try #require(error?.userFacingSentence)
      #expect(sentence.contains(field.rawValue))
      #expect(sentence.contains("deepseek-flash"))
    }
  }

  @Test("an unparsable off-peak multiplier fails the decode too")
  func rejectsUnparsableMultiplier() {
    for raw in ["", "TBD", "0,5", "0.5 USD"] {
      #expect(throws: PricingDataError.self) {
        try PriceTableLoader.decode(
          Data(fixtureJSON(offPeakMultiplier: raw).utf8), name: "fixture-inline")
      }
    }
  }

  @Test("a zero or negative price is rejected with the model and the field named")
  func rejectsNonPositivePrices() throws {
    let cases: [(field: PriceField, value: Decimal, json: String)] = [
      (.cacheHit, Decimal.parse("0"), fixtureJSON(cacheHit: "0")),
      (.cacheMiss, Decimal.parse("-1"), fixtureJSON(cacheMiss: "-1")),
      (.output, Decimal.parse("0"), fixtureJSON(output: "0")),
    ]

    for entry in cases {
      let error = #expect(
        throws: PricingDataError.invalidPrice(
          model: "deepseek-flash", field: entry.field, value: entry.value)
      ) {
        try PriceTableLoader.decode(Data(entry.json.utf8), name: "fixture-inline")
      }
      let sentence = try #require(error?.userFacingSentence)
      #expect(sentence.contains(entry.field.rawValue))
      #expect(sentence.contains("deepseek-flash"))
    }
  }

  @Test("a valid table still decodes through the strict price reader")
  func validTableStillDecodes() throws {
    let table = try PriceTableLoader.decode(Data(fixtureJSON().utf8), name: "fixture-inline")
    let flash = try #require(table.price(forModel: "deepseek-flash"))

    #expect(flash.cacheHitUSDPerMillion == Decimal.parse("0.006"))
    #expect(flash.cacheMissUSDPerMillion == Decimal.parse("0.30"))
    #expect(flash.outputUSDPerMillion == Decimal.parse("1.20"))
    #expect(table.offPeakMultiplier == Decimal.parse("0.5"))
  }

  @Test("every price in the shipped table is strictly positive")
  func shippedTablePricesArePositive() throws {
    let table = try PriceTableLoader().loadBundled()

    for price in table.models {
      #expect(price.cacheHitUSDPerMillion > 0, "\(price.model) cache hit")
      #expect(price.cacheMissUSDPerMillion > 0, "\(price.model) cache miss")
      #expect(price.outputUSDPerMillion > 0, "\(price.model) output")
    }
  }

  @Test("rejects a window that is not 0 <= start < end <= 24")
  func rejectsBadWindows() {
    for (start, end) in [(4, 4), (5, 4), (-1, 4), (0, 25)] {
      let broken = fixtureTable(windows: [PeakWindow(startHourUTC: start, endHourUTC: end)])
      #expect(
        throws: PricingDataError.invalidPeakWindow(startHourUTC: start, endHourUTC: end)
      ) {
        try PriceTableLoader.validate(broken)
      }
    }
  }

  @Test("accepts a degenerate but legal table (no windows, all off-peak)")
  func acceptsNoWindows() throws {
    let allOffPeak = fixtureTable(windows: [])
    try PriceTableLoader.validate(allOffPeak)
  }

  @Test("prefers a valid user override over the bundled table")
  func prefersValidOverride() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try writeOverride(fixtureTable(version: "override"), in: home)
    let loader = PriceTableLoader(homeDirectory: home)

    #expect(
      loader.overrideURL.path(percentEncoded: false)
        .hasSuffix("/.config/deeptally/PriceTable.json"))
    #expect(try loader.load().version == "override")
    // `loadBundled()` never looks at the override.
    #expect(try loader.loadBundled().version == "2026-09-24")
  }

  @Test("uses the bundled table when no override exists")
  func fallsBackWithoutOverride() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let loader = PriceTableLoader(homeDirectory: home)
    #expect(try loader.loadOverride() == nil)
    #expect(try loader.load().version == "2026-09-24")
  }

  @Test("ignores a present-but-broken override but still reports it")
  func ignoresBrokenOverride() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let loader = PriceTableLoader(homeDirectory: home)

    try writeOverride(#"{"version": "not-a-table"}"#, in: home)
    #expect(throws: PricingDataError.self) { try loader.loadOverride() }
    #expect(try loader.load().version == "2026-09-24")

    try writeOverride(fixtureTable(version: "override-without-models", models: []), in: home)
    #expect(throws: PricingDataError.noModels) { try loader.loadOverride() }
    #expect(try loader.load().version == "2026-09-24")
  }

  @Test("a valid override wins and reports no problem")
  func diagnosticsForValidOverride() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try writeOverride(fixtureTable(version: "override"), in: home)

    let (table, problem) = try PriceTableLoader(homeDirectory: home).loadWithDiagnostics()

    #expect(table.version == "override")
    #expect(problem == nil)
  }

  @Test("no override at all reports no problem")
  func diagnosticsWithoutOverride() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let (table, problem) = try PriceTableLoader(homeDirectory: home).loadWithDiagnostics()

    #expect(table.version == "2026-09-24")
    #expect(problem == nil)
  }

  /// The finding this covers: `load()`'s `try?` swallowed the override failure, so the app could only
  /// ever see the bundled-file error and its banner was unreachable for a user-file problem.
  @Test("an invalid override falls back to the bundled table and names the file and the reason")
  func diagnosticsForInvalidOverride() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let loader = PriceTableLoader(homeDirectory: home)
    let path = loader.overrideURL.path(percentEncoded: false)

    try writeOverride(#"{"version": "not-a-table"}"#, in: home)
    let (undecodable, decodeProblem) = try loader.loadWithDiagnostics()
    #expect(undecodable.version == "2026-09-24")
    #expect(try #require(decodeProblem).contains(path))

    // A file that decodes but breaks a rule is the same story, with the rule named.
    try writeOverride(fixtureTable(version: "override-without-models", models: []), in: home)
    let (unvalidatable, validationProblem) = try loader.loadWithDiagnostics()
    #expect(unvalidatable.version == "2026-09-24")
    let sentence = try #require(validationProblem)
    #expect(sentence.contains(path))
    #expect(sentence.contains("no models"))
  }

  @Test("an unreadable override falls back to the bundled table and names the file")
  func diagnosticsForUnreadableOverride() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let loader = PriceTableLoader(homeDirectory: home)

    // A directory where the override belongs: it exists, so it is not "no override", and it cannot
    // be read as a table.
    try FileManager.default.createDirectory(
      at: loader.overrideURL, withIntermediateDirectories: true)

    let (table, problem) = try loader.loadWithDiagnostics()

    #expect(table.version == "2026-09-24")
    let sentence = try #require(problem)
    #expect(sentence.contains(loader.overrideURL.path(percentEncoded: false)))
    #expect(sentence.contains("unreadable"))
  }

  @Test("a bundle without the shipped table still throws, override or not")
  func bundledFailureStillSurfaces() throws {
    let bundle = Bundle(for: TestBundleAnchor.self)
    // This test is only meaningful while the test bundle really carries no shipped table.
    #expect(bundle.url(forResource: "PriceTable", withExtension: "json") == nil)

    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let loader = PriceTableLoader(bundle: bundle, homeDirectory: home)

    #expect(throws: PricingDataError.resourceMissing(name: "PriceTable.json")) {
      try loader.loadWithDiagnostics()
    }

    // A broken override cannot mask a missing bundled table: there is nothing left to price with.
    try writeOverride(#"{"version": "not-a-table"}"#, in: home)
    #expect(throws: PricingDataError.resourceMissing(name: "PriceTable.json")) {
      try loader.loadWithDiagnostics()
    }
    #expect(throws: PricingDataError.resourceMissing(name: "PriceTable.json")) { try loader.load() }
  }
}

// MARK: - Error text

/// The one definition of every price-data sentence (``PricingDataError/userFacingSentence``), plus
/// the clause the override diagnostic wraps. The three call sites that used to spell these strings
/// out for themselves now read them from here, so this suite is the whole text contract: a case
/// added to `PricingDataError` must land in ``PricingErrorTextTests/wordings`` or the exhaustive
/// switch in ``PricingErrorTextTests/everyCaseIsListed()`` stops this file from compiling
/// (AGENTS.md §9.14).
@Suite("Pricing error text")
struct PricingErrorTextTests {
  /// A non-pricing error, to keep the loader's `String(describing:)` fallback covered.
  private struct PlainError: Error {}

  /// Every case, with both renderings a user can see: the sentence (`deeptally rate`, the app
  /// banner) and the reason clause the override diagnostic wraps in its own sentence. The wording is
  /// spelled out rather than derived, because this is the contract users have already read.
  private static let wordings: [(error: PricingDataError, sentence: String, reason: String)] = [
    (
      .resourceMissing(name: "PriceTable.json"),
      "PriceTable.json is missing or unreadable.",
      "the file is missing or unreadable"
    ),
    (
      .decodeFailed(name: "PriceTable.json", detail: "keyNotFound"),
      "PriceTable.json is not valid JSON for its schema: keyNotFound",
      "the file is not valid JSON for the price-table schema (keyNotFound)"
    ),
    (
      .noModels,
      "the price table lists no models.",
      "the table lists no models"
    ),
    (
      .invalidOffPeakMultiplier(Decimal.parse("1.5")),
      "the off-peak multiplier 1.5 is not in (0, 1].",
      "the off-peak multiplier 1.5 is not in (0, 1]"
    ),
    (
      .invalidPrice(model: "deepseek-flash", field: .cacheMiss, value: Decimal.parse("0")),
      "the cache_miss_usd_per_million 0 for deepseek-flash is not greater than zero.",
      "the cache_miss_usd_per_million 0 for deepseek-flash is not greater than zero"
    ),
    (
      .invalidPeakWindow(startHourUTC: 5, endHourUTC: 4),
      "the peak window 5-4 UTC is not a valid hour range.",
      "the peak window 5-4 UTC is not a valid hour range"
    ),
    (
      .duplicateAlias(alias: "deepseek-v4-flash"),
      "the alias \"deepseek-v4-flash\" is listed on more than one model.",
      "the alias \"deepseek-v4-flash\" is listed on more than one model"
    ),
  ]

  @Test("every case reads exactly as the sentence users have already seen")
  func sentencePerCase() {
    for (error, sentence, _) in Self.wordings {
      #expect(error.userFacingSentence == sentence)
    }
  }

  /// The loader's half of the same definition: `reason(for:)` must not grow a second switch.
  @Test("the override diagnostic's clause comes from the same definition, for every case")
  func reasonPerCase() {
    for (error, _, reason) in Self.wordings {
      #expect(PriceTableLoader.reason(for: error) == reason)
    }

    // An error that is not a pricing failure keeps its own description rather than a pricing one.
    let plain = PlainError()
    #expect(PriceTableLoader.reason(for: plain) == String(describing: plain))
  }

  @Test("no case can ship wordless, and the list above names every case exactly once")
  func everyCaseIsListed() {
    for (error, _, _) in Self.wordings {
      // The switch, not the loop, is the guard: it is exhaustive over `PricingDataError` today, so a
      // new case makes this file fail to build until its sentence is asserted above.
      switch error {
      case .resourceMissing, .decodeFailed, .noModels, .invalidOffPeakMultiplier,
        .invalidPrice, .invalidPeakWindow, .duplicateAlias:
        break
      }
    }
    #expect(Self.wordings.count == 7)
  }
}

// MARK: - Override diagnostics

@Suite("Override diagnostic")
struct OverrideProblemTests {
  /// The rejection the app banner and the CLI show, whole: the file, the clause from the one
  /// definition, and what is in use instead. Asserted literally because users have read it.
  @Test("names the file, the clause and the fallback")
  func namesFileClauseAndFallback() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let loader = PriceTableLoader(homeDirectory: home)
    try writeOverride(fixtureTable(version: "override-without-models", models: []), in: home)

    let (table, problem) = try loader.loadWithDiagnostics()
    let sentence = try #require(problem)

    #expect(table.version == "2026-09-24")
    #expect(
      sentence
        == "The price override at \(loader.overrideURL.path(percentEncoded: false))"
        + " was ignored: the table lists no models. The bundled price table is in use."
    )
    // And the clause inside it is the one definition's, not a second copy of the wording.
    #expect(sentence.contains(PricingDataError.noModels.overrideProblemReason))
  }

  /// The finding's actual scenario: a typo in the documented, user-editable override. It must be
  /// ignored — never billed as zero — and the sentence must name the model, or the user cannot tell
  /// which row to fix.
  @Test("an override with a zero price is ignored, names the model, and keeps the bundled table")
  func zeroPriceOverrideFallsBack() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let loader = PriceTableLoader(homeDirectory: home)
    try writeOverride(fixtureJSON(cacheMiss: "0"), in: home)

    let (table, problem) = try loader.loadWithDiagnostics()

    #expect(table.version == "2026-09-24")
    let sentence = try #require(problem)
    #expect(sentence.contains(loader.overrideURL.path(percentEncoded: false)))
    #expect(sentence.contains("deepseek-flash"))
    #expect(sentence.contains("cache_miss_usd_per_million"))
    #expect(sentence.contains("not greater than zero"))
  }

  @Test("an override with an unparsable amount is ignored and names the model")
  func unparsablePriceOverrideFallsBack() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let loader = PriceTableLoader(homeDirectory: home)
    try writeOverride(fixtureJSON(cacheMiss: "TBD"), in: home)

    let (table, problem) = try loader.loadWithDiagnostics()

    #expect(table.version == "2026-09-24")
    let sentence = try #require(problem)
    #expect(sentence.contains(loader.overrideURL.path(percentEncoded: false)))
    #expect(sentence.contains("deepseek-flash"))
    #expect(sentence.contains("cache_miss_usd_per_million"))
    #expect(sentence.contains("not a decimal amount"))
  }
}

// MARK: - Holidays

@Suite("Holiday calendar")
struct HolidayCalendarTests {
  @Test("an empty calendar has no holidays")
  func emptyCalendar() {
    let calendar = HolidayCalendar()
    #expect(calendar.isEmpty)
    #expect(!calendar.isHoliday(containing: instant("2026-09-28T02:00:00Z")))
    #expect(!calendar.isHoliday(containing: instant("2026-10-01T02:00:00Z")))
  }

  @Test("keys holidays by the Asia/Shanghai calendar day")
  func shanghaiDayBoundaries() {
    let calendar = HolidayCalendar(source: "fixture", dates: ["2026-10-02"])

    #expect(!calendar.isHoliday(containing: instant("2026-10-01T15:59:59Z")))  // Oct 1, 23:59 SH
    #expect(calendar.isHoliday(containing: instant("2026-10-01T16:00:00Z")))  // Oct 2, 00:00 SH
    #expect(calendar.isHoliday(containing: instant("2026-10-02T15:59:59Z")))  // Oct 2, 23:59 SH
    #expect(!calendar.isHoliday(containing: instant("2026-10-02T16:00:00Z")))  // Oct 3, 00:00 SH
  }

  @Test("merging unions the dates and keeps both sources")
  func merging() {
    let merged = HolidayCalendar(source: "shipped", dates: ["2026-10-01", "2026-10-02"])
      .merging(HolidayCalendar(source: "table", dates: ["2026-10-02", "2026-10-03"]))

    #expect(merged.dates == ["2026-10-01", "2026-10-02", "2026-10-03"])
    #expect(merged.source == "shipped, table")
  }

  @Test("loads the bundled China holiday list")
  func bundledList() throws {
    let calendar = try HolidayCalendar.loadBundled()

    for day in calendar.dates {
      #expect(isISODay(day), "holiday is not YYYY-MM-DD: \(day)")
      guard isISODay(day) else { continue }
      #expect(calendar.isHoliday(containing: instant("\(day)T04:00:00Z")))  // noon in Shanghai
    }
    #expect(!calendar.isHoliday(containing: instant("2001-01-02T04:00:00Z")))
  }
}

// MARK: - Peak / off-peak

@Suite("Peak / off-peak engine")
struct PeakOffPeakEngineTests {
  private let engine = PeakOffPeakEngine(table: fixtureTable())

  @Test("window start is inclusive")
  func startInclusive() {
    #expect(engine.classify(instant("2026-09-28T00:59:59Z")).period == .offPeak)
    #expect(engine.classify(instant("2026-09-28T01:00:00Z")).period == .peak)
  }

  @Test("window end is exclusive")
  func endExclusive() {
    #expect(engine.classify(instant("2026-09-28T03:59:59Z")).period == .peak)
    #expect(engine.classify(instant("2026-09-28T04:00:00Z")).period == .offPeak)
  }

  @Test("the gap between windows is off-peak, including its edges")
  func gapBetweenWindows() {
    #expect(engine.classify(instant("2026-09-28T05:59:59Z")).period == .offPeak)
    #expect(engine.classify(instant("2026-09-28T06:00:00Z")).period == .peak)
    #expect(engine.classify(instant("2026-09-28T09:59:59Z")).period == .peak)
    #expect(engine.classify(instant("2026-09-28T10:00:00Z")).period == .offPeak)
  }

  @Test("mid-window on a weekday is peak at full price")
  func midWindow() {
    let snapshot = engine.classify(instant("2026-09-28T02:30:00Z"))
    #expect(snapshot.period == .peak)
    #expect(snapshot.multiplier == 1)
    #expect(!snapshot.isHoliday)
  }

  @Test("Friday is a weekday and still peak")
  func fridayIsPeak() {
    #expect(engine.classify(instant("2026-09-25T02:00:00Z")).period == .peak)
  }

  @Test("the weekend is off-peak even inside a window")
  func weekendIsOffPeak() {
    let saturday = engine.classify(instant("2026-10-03T02:00:00Z"))
    let sunday = engine.classify(instant("2026-10-04T08:00:00Z"))
    #expect(saturday.period == .offPeak)
    #expect(saturday.multiplier == Decimal.parse("0.5"))
    #expect(sunday.period == .offPeak)
  }

  @Test("a holiday overrides an otherwise-peak instant")
  func holidayOverridesPeak() {
    let calendar = HolidayCalendar(source: "fixture", dates: ["2026-09-28"])
    let holidayEngine = PeakOffPeakEngine(table: fixtureTable(), holidayCalendar: calendar)

    let snapshot = holidayEngine.classify(instant("2026-09-28T02:30:00Z"))
    #expect(snapshot.period == .offPeak)
    #expect(snapshot.isHoliday)
    #expect(snapshot.multiplier == Decimal.parse("0.5"))
    // The neighbouring Shanghai day is unaffected.
    #expect(holidayEngine.classify(instant("2026-09-29T02:30:00Z")).period == .peak)
  }

  @Test("the table's own holidays apply when no calendar is supplied")
  func inlineTableHolidays() {
    let inline = PeakOffPeakEngine(table: fixtureTable(holidays: ["2026-09-28"]))
    let snapshot = inline.classify(instant("2026-09-28T02:30:00Z"))
    #expect(snapshot.period == .offPeak)
    #expect(snapshot.isHoliday)
  }

  @Test("next transition lands on the exact following boundary")
  func nextTransitionBoundaries() {
    #expect(
      engine.classify(instant("2026-09-28T00:30:00Z")).nextTransition
        == instant("2026-09-28T01:00:00Z"))
    #expect(
      engine.classify(instant("2026-09-28T03:30:00Z")).nextTransition
        == instant("2026-09-28T04:00:00Z"))
    #expect(
      engine.classify(instant("2026-09-28T05:00:00Z")).nextTransition
        == instant("2026-09-28T06:00:00Z"))
    #expect(
      engine.classify(instant("2026-09-28T10:30:00Z")).nextTransition
        == instant("2026-09-29T01:00:00Z"))
  }

  @Test("next transition skips the weekend")
  func nextTransitionSkipsWeekend() {
    #expect(
      engine.classify(instant("2026-09-25T12:00:00Z")).nextTransition
        == instant("2026-09-28T01:00:00Z"))
  }

  @Test("next transition skips a holiday")
  func nextTransitionSkipsHoliday() {
    let holidayEngine = PeakOffPeakEngine(
      table: fixtureTable(), holidayCalendar: HolidayCalendar(dates: ["2026-09-28"]))
    #expect(
      holidayEngine.classify(instant("2026-09-25T12:00:00Z")).nextTransition
        == instant("2026-09-29T01:00:00Z"))
  }

  @Test("the period flips exactly at the reported transition")
  func transitionIsExact() {
    let samples = [
      "2026-09-28T00:30:00Z",
      "2026-09-28T03:30:00Z",
      "2026-09-28T05:00:00Z",
      "2026-09-28T10:30:00Z",
      "2026-09-25T12:00:00Z",
      "2026-10-03T02:00:00Z",
    ]

    for sample in samples {
      let now = instant(sample)
      let snapshot = engine.classify(now)
      guard let next = snapshot.nextTransition else {
        Issue.record("no transition found after \(sample)")
        continue
      }
      #expect(engine.classify(next).period != snapshot.period)
      #expect(engine.classify(next.addingTimeInterval(-1)).period == snapshot.period)
    }
  }
}

// MARK: - Cost

@Suite("Cost engine")
struct CostEngineTests {
  private let engine = CostEngine(table: fixtureTable())

  private var millionOfEach: TokenUsage {
    TokenUsage(
      promptTokens: 2_000_000,
      completionTokens: 1_000_000,
      cacheHitTokens: 1_000_000,
      cacheMissTokens: 1_000_000
    )
  }

  @Test("flash: 1M hit + 1M miss + 1M output at peak costs 1.506 USD")
  func flashPeakCost() {
    let cost = engine.cost(
      model: "deepseek-flash", usage: millionOfEach, at: instant("2026-09-28T02:30:00Z"))
    #expect(cost == Decimal.parse("1.506"))
  }

  @Test("the same request costs half off-peak")
  func flashOffPeakCost() {
    let cost = engine.cost(
      model: "deepseek-flash", usage: millionOfEach, at: instant("2026-09-28T12:00:00Z"))
    #expect(cost == Decimal.parse("0.753"))
    #expect(cost == Decimal.parse("1.506") * Decimal.parse("0.5"))
  }

  @Test("pro pricing uses the pro row")
  func proPeakCost() {
    let cost = engine.cost(
      model: "deepseek-v4-pro", usage: millionOfEach, at: instant("2026-09-28T02:30:00Z"))
    #expect(cost == Decimal.parse("5.324"))
  }

  @Test("fractional token counts scale linearly")
  func fractionalTokens() {
    let usage = TokenUsage(
      promptTokens: 750_000,
      completionTokens: 125_000,
      cacheHitTokens: 500_000,
      cacheMissTokens: 250_000
    )
    let cost = engine.cost(
      model: "deepseek-flash", usage: usage, at: instant("2026-09-28T02:30:00Z"))
    #expect(cost == Decimal.parse("0.228"))
  }

  @Test("a holiday is priced off-peak")
  func holidayIsOffPeak() {
    let holidayEngine = CostEngine(
      table: fixtureTable(), holidayCalendar: HolidayCalendar(dates: ["2026-09-28"]))
    let cost = holidayEngine.cost(
      model: "deepseek-flash", usage: millionOfEach, at: instant("2026-09-28T02:30:00Z"))
    #expect(cost == Decimal.parse("0.753"))
  }

  @Test("current rates carry the period multiplier")
  func currentRates() {
    let peak = engine.currentRates(model: "deepseek-flash", at: instant("2026-09-28T02:30:00Z"))
    #expect(peak.cacheHit == Decimal.parse("0.006"))
    #expect(peak.cacheMiss == Decimal.parse("0.30"))
    #expect(peak.output == Decimal.parse("1.20"))

    let offPeak = engine.currentRates(model: "deepseek-flash", at: instant("2026-09-28T12:00:00Z"))
    #expect(offPeak.cacheHit == Decimal.parse("0.003"))
    #expect(offPeak.cacheMiss == Decimal.parse("0.15"))
    #expect(offPeak.output == Decimal.parse("0.60"))
  }

  @Test("an unknown model prices at zero")
  func unknownModel() {
    let cost = engine.cost(
      model: "deepseek-v9", usage: millionOfEach, at: instant("2026-09-28T02:30:00Z"))
    #expect(cost == .zero)

    let rates = engine.currentRates(model: "deepseek-v9", at: instant("2026-09-28T02:30:00Z"))
    #expect(rates.cacheHit == 0)
    #expect(rates.cacheMiss == 0)
    #expect(rates.output == 0)
  }

  @Test("zero usage costs nothing")
  func zeroUsage() {
    let usage = TokenUsage(
      promptTokens: 0, completionTokens: 0, cacheHitTokens: 0, cacheMissTokens: 0)
    #expect(
      engine.cost(model: "deepseek-flash", usage: usage, at: instant("2026-09-28T02:30:00Z"))
        == .zero)
  }
}
