// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation

/// The composition root.
///
/// It builds the long-lived collaborators once, at launch, so neither the model nor a view has to
/// know how a key source, a price table or a holiday calendar is assembled — and so there is exactly
/// one place where those choices are made.
///
/// Composing is fail-soft: a typo in a user override, or a packaging mistake that drops
/// `ChinaHolidays.json`, must never stop the app from launching. Each unreadable file is recorded as
/// a sentence for the popover's banner slot, and the part that depends on it falls back to
/// ``PriceTable/unavailable`` or to an empty calendar.
struct AppEnvironment: Sendable {
  /// Keychain first, then `DEEPSEEK_API_KEY` — the precedence order the CLI shares, so both halves
  /// of the product use the same key.
  let keySource: APIKeySource
  /// Kept beside ``keySource`` so the app can report *where* a key came from without reading the
  /// secret: `hasItem()` answers existence only.
  let keychain: KeychainStore

  let settingsStore: SettingsStore
  let launchState: LaunchStateStore

  let priceTable: PriceTable
  let holidayCalendar: HolidayCalendar
  let peakOffPeak: PeakOffPeakEngine
  let rateNow: RateNowPresenter

  /// Set when the price table could not be read. Until it is fixed the app prices with
  /// ``PriceTable/unavailable``, which lists no models, so the rate panel is suppressed rather than
  /// claim a period that no data supports.
  let priceTableProblem: String?
  /// Set when a user override was rejected but the bundled table is still usable. Prices ARE shown,
  /// from the bundled table, so this must not suppress the rate panel the way ``priceTableProblem``
  /// does. Conflating the two produced a banner claiming no prices were available while the panel was
  /// hidden for a table that was perfectly fine (found by rendering a deliberately broken override).
  let priceOverrideProblem: String?
  /// Set when `ChinaHolidays.json` could not be read. The table still prices, but peak classification
  /// then misses the public holidays and over-reports peak hours on them.
  let holidayCalendarProblem: String?

  /// One client per refresh, bound to the key that refresh resolved: a forgotten or re-imported key
  /// takes effect on the next request instead of being captured at launch.
  let makeClient: @Sendable (String) -> DeepSeekClient

  init(
    defaults: UserDefaults = .standard,
    keychain: KeychainStore = KeychainStore(),
    priceLoader: PriceTableLoader = PriceTableLoader(),
    timeZone: TimeZone = .current
  ) {
    self.keychain = keychain
    self.keySource = APIKeySource(keychain: keychain)
    self.settingsStore = SettingsStore(defaults: defaults)
    self.launchState = LaunchStateStore(defaults: defaults)

    let table: PriceTable
    let tableProblem: String?
    let overrideProblem: String?
    do {
      // Diagnostics, not load(): a user override that is present but invalid must fall back to the
      // bundled table AND say so. `load()` would swallow the reason, leaving the banner slot above
      // unreachable for exactly the case it exists for (review finding 4).
      let loaded = try priceLoader.loadWithDiagnostics()
      table = loaded.table
      tableProblem = nil
      overrideProblem = loaded.overrideProblem
    } catch {
      table = .unavailable
      tableProblem = Self.describe(error)
      overrideProblem = nil
    }

    // The shipped State Council list and any dates embedded in the price table become one calendar:
    // peak classification is a UTC question, but "is this a Chinese public holiday" is not, and the
    // engine can only ask one object (AGENTS.md §9.9).
    var calendar: HolidayCalendar
    let calendarProblem: String?
    do {
      calendar = try HolidayCalendar.loadBundled()
      calendarProblem = nil
    } catch {
      calendar = HolidayCalendar()
      calendarProblem = Self.describe(error)
    }
    calendar = calendar.merging(HolidayCalendar(source: "PriceTable.json", dates: table.holidays))

    self.priceTable = table
    self.priceTableProblem = tableProblem
    self.priceOverrideProblem = overrideProblem
    self.holidayCalendar = calendar
    self.holidayCalendarProblem = calendarProblem
    let engine = PeakOffPeakEngine(table: table, holidayCalendar: calendar)
    self.peakOffPeak = engine
    self.rateNow = RateNowPresenter(table: table, engine: engine, timeZone: timeZone)
    self.makeClient = { key in DeepSeekClient(keyProvider: { key }) }
  }

  /// The balance monitor for one threshold. The stale-after window is app policy, the threshold is a
  /// user setting, so this is rebuilt when the setting changes instead of capturing the old value.
  func balanceMonitor(lowBalanceThreshold: Decimal) -> BalanceMonitor {
    BalanceMonitor(lowBalanceThreshold: lowBalanceThreshold)
  }

  /// The alert policy for one cooldown, for the same reason as ``balanceMonitor(lowBalanceThreshold:)``.
  func notificationPolicy(cooldownMinutes: Int) -> NotificationPolicy {
    NotificationPolicy(cooldown: TimeInterval(cooldownMinutes) * 60)
  }

  // MARK: - Diagnostics

  /// A `PricingDataError` as a plain sentence, the same shape `deeptally rate` prints. `detail` is
  /// kept: it names the offending field.
  private static func describe(_ error: any Error) -> String {
    guard let pricing = error as? PricingDataError else { return String(describing: error) }
    switch pricing {
    case .resourceMissing(let name):
      return "\(name) is missing or unreadable."
    case .decodeFailed(let name, let detail):
      return "\(name) is not valid JSON for its schema: \(detail)"
    case .noModels:
      return "the price table lists no models."
    case .invalidOffPeakMultiplier(let value):
      return "the off-peak multiplier \(value) is not in (0, 1]."
    case .invalidPeakWindow(let start, let end):
      return "the peak window \(start)-\(end) UTC is not a valid hour range."
    }
  }
}

extension PriceTable {
  /// What the app carries when the shipped table cannot be read: no models, no windows and a
  /// multiplier of 1. Prices are data, never code (AGENTS.md §9.11), so there is no fallback price
  /// here — only a table that lists nothing, while `AppEnvironment.priceTableProblem` says why.
  static let unavailable = PriceTable(
    version: "unavailable",
    currency: "USD",
    effectiveFrom: "",
    offPeakMultiplier: 1,
    peakWindowsUTC: [],
    holidays: [],
    models: []
  )
}

/// The two facts that must outlive the process but are not settings: the last successful reading and
/// the last time the user was told the balance is low.
///
/// Both live in the caller's `UserDefaults` domain as JSON. Nothing here can hold a secret: the API
/// key lives in the Keychain only (AGENTS.md §5).
struct LaunchStateStore: Sendable {
  /// One successful `/user/balance` response and the instant it was fetched. Persisted so a relaunch
  /// shows the amount immediately, with the truthful age the monitor computes from `fetchedAt`,
  /// instead of an empty panel that claims nothing was ever fetched.
  struct Reading: Codable, Sendable, Equatable {
    let balance: Balance
    let fetchedAt: Date
  }

  /// `UserDefaults` is documented thread-safe but is not annotated `Sendable` in the SDK, so the
  /// conformance needs this one escape hatch (the same one `SettingsStore` uses).
  private nonisolated(unsafe) let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  private static let readingKey = "io.github.genoma.deeptally.last-reading"
  private static let notifiedKey = "io.github.genoma.deeptally.last-notified"

  /// The last reading, or `nil` when none was ever stored or the blob is unreadable. A corrupt value
  /// is dropped rather than repaired: the next successful fetch overwrites it.
  func loadReading() -> Reading? {
    guard let data = defaults.data(forKey: Self.readingKey) else { return nil }
    return try? JSONDecoder().decode(Reading.self, from: data)
  }

  func saveReading(_ reading: Reading) {
    guard let data = try? JSONEncoder().encode(reading) else { return }
    defaults.set(data, forKey: Self.readingKey)
  }

  /// `nil` means no alert has ever been posted, which is not the same as a distant past instant.
  func loadLastNotified() -> Date? {
    guard let interval = defaults.object(forKey: Self.notifiedKey) as? Double else { return nil }
    return Date(timeIntervalSince1970: interval)
  }

  func saveLastNotified(_ date: Date) {
    defaults.set(date.timeIntervalSince1970, forKey: Self.notifiedKey)
  }
}
