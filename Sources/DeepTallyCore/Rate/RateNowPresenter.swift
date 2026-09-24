// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One model's effective price for the period that is in force right now, in USD per 1M tokens.
public struct ModelRate: Sendable, Equatable {
  public let model: String
  public let cacheHit: Decimal
  public let cacheMiss: Decimal
  public let output: Decimal

  /// Public so the app target can build previews and fixtures without testability access.
  public init(model: String, cacheHit: Decimal, cacheMiss: Decimal, output: Decimal) {
    self.model = model
    self.cacheHit = cacheHit
    self.cacheMiss = cacheMiss
    self.output = output
  }
}

/// What the account is paying right now: the window in the user's local time, when it ends, and
/// the effective price of every model while it lasts.
///
/// Every field is already a display string, formatted with the presenter's injected time zone and
/// locale, so a view only has to place them.
public struct RateNowDisplay: Sendable, Equatable {
  /// "Peak" or "Off-peak".
  public let periodLabel: String
  /// "full price" at 1×, otherwise the table's discount, e.g. "50% off".
  public let multiplierLabel: String
  public let isHoliday: Bool
  /// "CN public holiday" when `isHoliday`, otherwise `nil`.
  public let holidayNote: String?
  /// The local wall-clock time this period ends, e.g. "18:00"; "—" when unknown.
  public let windowEndsLocal: String
  /// The time left in the period, floored to whole minutes: "2h 14m", "46m", "0m"; "—" when unknown.
  public let countdown: String
  /// The same end instant including the local weekday, e.g. "Thu 18:00"; "—" when unknown.
  public let nextTransitionLocal: String
  /// The effective prices of the current period, one row per model in table order.
  public let models: [ModelRate]

  /// Public so the app target can build previews and fixtures without testability access.
  public init(
    periodLabel: String,
    multiplierLabel: String,
    isHoliday: Bool,
    holidayNote: String?,
    windowEndsLocal: String,
    countdown: String,
    nextTransitionLocal: String,
    models: [ModelRate]
  ) {
    self.periodLabel = periodLabel
    self.multiplierLabel = multiplierLabel
    self.isHoliday = isHoliday
    self.holidayNote = holidayNote
    self.windowEndsLocal = windowEndsLocal
    self.countdown = countdown
    self.nextTransitionLocal = nextTransitionLocal
    self.models = models
  }
}

/// Renders "what am I paying right now?" for one price table.
///
/// The peak/off-peak *decision* is a UTC question and belongs to ``PeakOffPeakEngine``; the
/// *presentation* is a local-time question and belongs here (AGENTS.md §9.9). A window label is
/// never derived from local-time arithmetic — only the transition instant the engine computed is
/// formatted, always with the injected `timeZone` and `locale`, so the UI never follows the
/// process defaults.
public struct RateNowPresenter: Sendable {
  /// Shown wherever a time cannot be known, e.g. off-peak with no further boundary.
  private static let unknownTime = "—"
  private static let holidayNote = "CN public holiday"
  /// e.g. "18:00".
  private static let clockFormat = "HH:mm"
  /// e.g. "Thu 18:00".
  private static let weekdayClockFormat = "EEE HH:mm"

  private let table: PriceTable
  private let engine: PeakOffPeakEngine
  private let timeZone: TimeZone
  private let locale: Locale

  public init(
    table: PriceTable,
    engine: PeakOffPeakEngine,
    timeZone: TimeZone,
    locale: Locale = Locale(identifier: "en_US_POSIX")
  ) {
    self.table = table
    self.engine = engine
    self.timeZone = timeZone
    self.locale = locale
  }

  public func display(at date: Date) -> RateNowDisplay {
    let snapshot = engine.classify(date)
    return RateNowDisplay(
      periodLabel: Self.periodLabel(snapshot.period),
      multiplierLabel: Self.multiplierLabel(snapshot.multiplier),
      isHoliday: snapshot.isHoliday,
      holidayNote: snapshot.isHoliday ? Self.holidayNote : nil,
      windowEndsLocal: wallClock(snapshot.nextTransition, format: Self.clockFormat),
      countdown: Self.countdown(until: snapshot.nextTransition, from: date),
      nextTransitionLocal: wallClock(snapshot.nextTransition, format: Self.weekdayClockFormat),
      models: effectiveRates(multiplier: snapshot.multiplier)
    )
  }

  // MARK: - Labels

  private static func periodLabel(_ period: RatePeriod) -> String {
    period == .peak ? "Peak" : "Off-peak"
  }

  /// The discount the table's multiplier buys. The multiplier is data (AGENTS.md §9.11), so this
  /// reads the table's factor rather than assuming the shipped 50%.
  private static func multiplierLabel(_ multiplier: Decimal) -> String {
    guard multiplier < 1 else { return "full price" }
    return "\((1 - multiplier) * 100)% off"
  }

  // MARK: - Times

  /// A fresh formatter per call: `DateFormatter` is not `Sendable`, and this type must be.
  private func wallClock(_ instant: Date?, format: String) -> String {
    guard let instant else { return Self.unknownTime }
    let formatter = DateFormatter()
    // Locale first: it decides how the fixed format and the weekday abbreviation are interpreted.
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter.string(from: instant)
  }

  /// Whole minutes remaining, rounded down, so a boundary 60 s away reads "1m" and 59 s away "0m".
  private static func countdown(until transition: Date?, from now: Date) -> String {
    guard let transition else { return unknownTime }
    let wholeMinutes = (transition.timeIntervalSince(now) / 60).rounded(.down)
    // `wholeMinutes` is at most two weeks: the engine never reports a transition beyond its search
    // horizon, so the conversion below cannot overflow.
    guard wholeMinutes.isFinite, wholeMinutes > 0 else { return "0m" }
    let minutes = Int(wholeMinutes)
    let hours = minutes / 60
    return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
  }

  // MARK: - Prices

  /// The current period's price for every model in the table, in table order.
  private func effectiveRates(multiplier: Decimal) -> [ModelRate] {
    table.models.map { price in
      ModelRate(
        model: price.model,
        cacheHit: price.cacheHitUSDPerMillion * multiplier,
        cacheMiss: price.cacheMissUSDPerMillion * multiplier,
        output: price.outputUSDPerMillion * multiplier
      )
    }
  }
}
