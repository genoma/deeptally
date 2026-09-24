// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

// MARK: - Fixtures

/// The ids the real opencode ledger used that had no row of their own, and the row each one must
/// price as. Three are plain ids and three sit behind the `deepseek/` route prefix, which the
/// resolver strips — the prefixes are therefore deliberately absent from `PriceTable.json`.
private let observedLedgerIDs:
  [(id: String, model: String, hit: String, miss: String, output: String)] =
    [
      ("deepseek/deepseek-v4-flash-vision-exp", "deepseek-flash", "0.006", "0.30", "1.20"),
      ("deepseek-v4-pro", "deepseek-v4-pro", "0.044", "1.32", "3.96"),
      ("deepseek-v4-flash", "deepseek-flash", "0.006", "0.30", "1.20"),
      ("deepseek/deepseek-v4-pro-0813", "deepseek-v4-pro", "0.044", "1.32", "3.96"),
      ("deepseek-v4-flash-vision-exp", "deepseek-flash", "0.006", "0.30", "1.20"),
      ("deepseek/deepseek-v4-flash-0731", "deepseek-flash", "0.006", "0.30", "1.20"),
    ]

private let flashRow = ModelPrice(
  model: "deepseek-flash",
  aliases: ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek-v4-flash-0731"],
  cacheHitUSDPerMillion: Decimal.parse("0.006"),
  cacheMissUSDPerMillion: Decimal.parse("0.30"),
  outputUSDPerMillion: Decimal.parse("1.20")
)

private let proRow = ModelPrice(
  model: "deepseek-v4-pro",
  aliases: ["deepseek-v4-pro-0813"],
  cacheHitUSDPerMillion: Decimal.parse("0.044"),
  cacheMissUSDPerMillion: Decimal.parse("1.32"),
  outputUSDPerMillion: Decimal.parse("3.96")
)

private func aliasTable(models: [ModelPrice] = [flashRow, proRow]) -> PriceTable {
  PriceTable(
    version: "alias-tests",
    currency: "USD",
    effectiveFrom: "2026-09-24",
    offPeakMultiplier: Decimal.parse("0.5"),
    peakWindowsUTC: [PeakWindow(startHourUTC: 1, endHourUTC: 4)],
    holidays: [],
    models: models
  )
}

/// 2026-09-28 is a Monday, so 02:00 UTC is inside the fixture's peak window.
private func peakInstant() -> Date {
  guard let date = ISO8601DateFormatter().date(from: "2026-09-28T02:30:00Z") else {
    fatalError("invalid fixture instant")
  }
  return date
}

private func makeTemporaryHome() throws -> URL {
  let home = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "deeptally-alias-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: home.appending(path: ".config/deeptally"), withIntermediateDirectories: true)
  return home
}

private func writeOverride(_ json: String, in home: URL) throws {
  try Data(json.utf8).write(to: home.appending(path: PriceTableLoader.overrideRelativePath))
}

// MARK: - Resolution

@Suite("Model alias resolution")
struct ModelAliasResolutionTests {
  private let table = aliasTable()

  @Test("each observed id resolves to its row with the shipped prices")
  func observedIDsResolve() throws {
    for expected in observedLedgerIDs {
      let price = try #require(table.price(forModel: expected.id), "no price for \(expected.id)")
      #expect(price.model == expected.model, "\(expected.id) resolved to \(price.model)")
      #expect(
        price.cacheHitUSDPerMillion == Decimal.parse(expected.hit), "\(expected.id) cache hit")
      #expect(
        price.cacheMissUSDPerMillion == Decimal.parse(expected.miss), "\(expected.id) cache miss")
      #expect(price.outputUSDPerMillion == Decimal.parse(expected.output), "\(expected.id) output")
    }
  }

  @Test("an exact id wins over another row listing it as an alias")
  func exactIDWinsOverAlias() {
    // The flash row claims the pro row's id as an alias; the pro row's own id must still win.
    let shadowed = aliasTable(models: [
      ModelPrice(
        model: "deepseek-flash",
        aliases: ["deepseek-v4-pro"],
        cacheHitUSDPerMillion: Decimal.parse("0.006"),
        cacheMissUSDPerMillion: Decimal.parse("0.30"),
        outputUSDPerMillion: Decimal.parse("1.20")
      ),
      proRow,
    ])

    #expect(
      shadowed.price(forModel: "deepseek-v4-pro")?.cacheHitUSDPerMillion == Decimal.parse("0.044"))
  }

  @Test("a route prefix resolves through the last path component")
  func routePrefixResolves() {
    #expect(table.price(forModel: "deepseek/deepseek-v4-flash")?.model == "deepseek-flash")
    #expect(table.price(forModel: "deepseek/deepseek-v4-pro")?.model == "deepseek-v4-pro")
    #expect(table.price(forModel: "deepseek/deepseek-v4-pro-0813")?.model == "deepseek-v4-pro")
    // More than one leading component is still just a route.
    #expect(
      table.price(forModel: "openrouter/deepseek/deepseek-v4-flash-0731")?.model
        == "deepseek-flash")
  }

  @Test("an unrecognised id stays unrecognised")
  func unknownIDsStayUnpriced() {
    for id in [
      "deepseek-v9",
      "deepseek/deepseek-v9",
      "deepseek/",
      "",
      // Case matters: an id is only ever matched as the ledger spells it.
      "DEEPSEEK-V4-FLASH",
      "DeepSeek-V4-Flash",
      "deepseek-v4-flash-vision-exp-2027",
      "deepseek-",
    ] {
      #expect(table.price(forModel: id) == nil, "\(id) must not be priced")
    }
  }
}

// MARK: - Decoding and validation

@Suite("Alias decoding and validation")
struct AliasDecodingValidationTests {
  @Test("a row without aliases decodes to an empty list")
  func aliasesAreOptional() throws {
    let json = #"""
      {
        "version": "fixture",
        "currency": "USD",
        "effective_from": "2026-09-24",
        "off_peak_multiplier": "0.5",
        "peak_windows_utc": [{ "start_hour_utc": 1, "end_hour_utc": 4 }],
        "models": [
          {
            "model": "deepseek-flash",
            "cache_hit_usd_per_million": "0.006",
            "cache_miss_usd_per_million": "0.30",
            "output_usd_per_million": "1.20"
          }
        ]
      }
      """#

    let table = try PriceTableLoader.decode(Data(json.utf8), name: "fixture-inline")

    #expect(table.models[0].aliases.isEmpty)
    #expect(table.price(forModel: "deepseek-flash")?.model == "deepseek-flash")
    #expect(table.price(forModel: "deepseek-v4-flash") == nil)
  }

  @Test("aliases survive the encode/decode round-trip an override uses")
  func aliasesRoundTrip() throws {
    let original = aliasTable()
    let data = try JSONEncoder().encode(original)

    #expect(try JSONDecoder().decode(PriceTable.self, from: data) == original)
  }

  @Test("the same alias on two rows is rejected")
  func duplicateAliasRejected() {
    let shared = [
      ModelPrice(
        model: "deepseek-flash",
        aliases: ["deepseek-v4-flash", "shared"],
        cacheHitUSDPerMillion: Decimal.parse("0.006"),
        cacheMissUSDPerMillion: Decimal.parse("0.30"),
        outputUSDPerMillion: Decimal.parse("1.20")
      ),
      ModelPrice(
        model: "deepseek-v4-pro",
        aliases: ["shared"],
        cacheHitUSDPerMillion: Decimal.parse("0.044"),
        cacheMissUSDPerMillion: Decimal.parse("1.32"),
        outputUSDPerMillion: Decimal.parse("3.96")
      ),
    ]

    #expect(throws: PricingDataError.duplicateAlias(alias: "shared")) {
      try PriceTableLoader.validate(aliasTable(models: shared))
    }
  }

  @Test("the same alias twice on one row is rejected too")
  func duplicateAliasWithinOneRow() {
    let twice = [
      ModelPrice(
        model: "deepseek-flash",
        aliases: ["twice", "twice"],
        cacheHitUSDPerMillion: Decimal.parse("0.006"),
        cacheMissUSDPerMillion: Decimal.parse("0.30"),
        outputUSDPerMillion: Decimal.parse("1.20")
      )
    ]

    #expect(throws: PricingDataError.duplicateAlias(alias: "twice")) {
      try PriceTableLoader.validate(aliasTable(models: twice))
    }
  }

  @Test("an override with a colliding alias is ignored and named")
  func collidingOverrideFallsBack() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let loader = PriceTableLoader(homeDirectory: home)

    let colliding = aliasTable(models: [
      flashRow,
      ModelPrice(
        model: "deepseek-v4-pro",
        aliases: ["deepseek-v4-flash"],
        cacheHitUSDPerMillion: Decimal.parse("0.044"),
        cacheMissUSDPerMillion: Decimal.parse("1.32"),
        outputUSDPerMillion: Decimal.parse("3.96")
      ),
    ])
    try writeOverride(String(decoding: JSONEncoder().encode(colliding), as: UTF8.self), in: home)

    let (table, problem) = try loader.loadWithDiagnostics()

    #expect(table.version == "2026-09-24")
    let sentence = try #require(problem)
    #expect(sentence.contains("deepseek-v4-flash"))
    #expect(sentence.contains("more than one model"))
  }

  @Test("a user override can add an alias that prices a ledger id")
  func overrideAliasPrices() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let loader = PriceTableLoader(homeDirectory: home)

    let extended = aliasTable(models: [
      ModelPrice(
        model: "deepseek-flash",
        aliases: ["deepseek-v4-flash-1001"],
        cacheHitUSDPerMillion: Decimal.parse("0.006"),
        cacheMissUSDPerMillion: Decimal.parse("0.30"),
        outputUSDPerMillion: Decimal.parse("1.20")
      ),
      proRow,
    ])
    try writeOverride(String(decoding: JSONEncoder().encode(extended), as: UTF8.self), in: home)

    let table = try loader.load()

    #expect(table.price(forModel: "deepseek/deepseek-v4-flash-1001")?.model == "deepseek-flash")
  }
}

// MARK: - Cost

@Suite("Aliased ids are billed")
struct AliasedCostTests {
  /// 1M cache hit + 1M cache miss + 1M output at peak, the fixture prices from `PricingTests`.
  private var millionOfEach: TokenUsage {
    TokenUsage(
      promptTokens: 2_000_000,
      completionTokens: 1_000_000,
      cacheHitTokens: 1_000_000,
      cacheMissTokens: 1_000_000
    )
  }

  @Test("a route-prefixed aliased id bills the flash rate, not zero")
  func prefixedAliasIsBilled() {
    let engine = CostEngine(table: aliasTable())

    let cost = engine.cost(
      model: "deepseek/deepseek-v4-flash", usage: millionOfEach, at: peakInstant())

    #expect(cost == Decimal.parse("1.506"))
    #expect(cost != .zero)
  }

  @Test("an alias bills exactly what its row bills")
  func aliasMatchesRowPrice() {
    let engine = CostEngine(table: aliasTable())

    for id in ["deepseek-v4-flash", "deepseek/deepseek-v4-flash-0731"] {
      #expect(
        engine.cost(model: id, usage: millionOfEach, at: peakInstant())
          == engine.cost(model: "deepseek-flash", usage: millionOfEach, at: peakInstant()),
        "\(id) must bill like deepseek-flash")
    }
  }
}

// MARK: - Shipped data

@Suite("Shipped price table aliases")
struct ShippedAliasDataTests {
  @Test("the shipped table resolves every id observed in the real ledger")
  func shippedTableResolvesObservedIDs() throws {
    let table = try PriceTableLoader().loadBundled()

    for expected in observedLedgerIDs {
      let price = try #require(table.price(forModel: expected.id), "no price for \(expected.id)")
      #expect(price.model == expected.model, "\(expected.id) resolved to \(price.model)")
      #expect(
        price.cacheHitUSDPerMillion == Decimal.parse(expected.hit), "\(expected.id) cache hit")
      #expect(
        price.cacheMissUSDPerMillion == Decimal.parse(expected.miss), "\(expected.id) cache miss")
      #expect(price.outputUSDPerMillion == Decimal.parse(expected.output), "\(expected.id) output")
    }
  }

  /// A data test, so dropping an alias in a future edit fails here instead of silently turning real
  /// ledger rows back into $0.00.
  @Test("the shipped alias lists are exactly the ones the ledger needed")
  func shippedAliasLists() throws {
    let table = try PriceTableLoader().loadBundled()

    let flash = try #require(table.price(forModel: "deepseek-flash"))
    #expect(
      Set(flash.aliases)
        == Set([
          "deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek-v4-flash-0731",
        ]))

    let pro = try #require(table.price(forModel: "deepseek-v4-pro"))
    #expect(Set(pro.aliases) == Set(["deepseek-v4-pro-0813"]))
  }
}
