// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DeepTallyCore
import Foundation
import Network
import Observation

/// The integrator: one object that owns the key, the polling schedule, the derived balance state, the
/// rate-now display, the settings and the notices the popover shows.
///
/// Four rules this type exists to keep:
/// - a refresh never runs twice at once, and the next one always comes from `PollingPlan`
///   (interval, then backoff, then jitter) rather than from a hand-rolled timer chain;
/// - nothing blocking runs on the main actor: importing a key and every ledger pass are the two
///   blocking kinds of work in the app and both run off it (the ledger lives in ``LocalUsageLedger``);
/// - the API key leaves the Keychain only as the `Bearer` argument of one request. It is never
///   logged, never written to `UserDefaults`, and never displayed (AGENTS.md §5);
/// - a low-balance alert is remembered as delivered only after macOS accepted it, so a denial or a
///   failed post is retried instead of consuming the cooldown; while macOS will not deliver alerts,
///   the menu bar carries the warning glyph and the popover says so once.
///
/// Local usage is imported for the same reason the balance is polled: the numbers have to be live
/// without the user doing anything. It is a separate, fixed cadence, it never touches the balance
/// path, and every failure of it is quiet — at most the settings panel says local usage is not being
/// imported yet.
@MainActor
@Observable
final class AppModel {
  /// One notice for the popover's banner slot. Derived from state rather than accumulated, so a
  /// notice that stopped being true cannot linger.
  struct Banner: Identifiable {
    let id: String
    let kind: StatusBanner.Kind
    let message: String
  }

  // MARK: - Observable state

  private(set) var balanceState: BalanceState?
  private(set) var rateNow: RateNowDisplay?
  /// Where the key in use came from, straight from the shared resolver.
  private(set) var keyOrigin: KeyResolution.Origin = .none
  /// Why the Keychain read failed, even when a usable `DEEPSEEK_API_KEY` still resolved. A sentence
  /// from the core resolver: it carries a status code and never any part of a key.
  private(set) var keychainProblem: String?
  /// The last authorization macOS reported for alerts, or `nil` before it was ever read.
  private(set) var alertAuthorization: AlertAuthorization?
  private(set) var isRefreshing = false
  private(set) var isImportingKey = false
  private(set) var importMessage: String?
  private(set) var loginItemStatus: LoginItem.Status = .notRegistered
  /// The last good reading of the ledger, or `nil` until a pass has successfully read it.
  private(set) var localUsage: LocalUsageMetrics?
  /// Why the last ledger pass could not import, or `nil` when it did. Rendered only as the quiet
  /// note in ``localUsageNote``; a missing opencode database is never a banner.
  private(set) var localUsageProblem: String?
  /// One calm sentence from the last pass about rows the price table cannot price, or `nil` when
  /// every offered row had a price. Not a failure: the metrics still carry the priced rows' values.
  private(set) var localUsagePricingNote: String?
  /// `true` while a CSV export or import is in flight. One flag for both, because both write through
  /// the same ledger connection and the buttons must not queue a second transfer behind the first.
  private(set) var isTransferringLedger = false
  /// The last transfer's report or failure, one sentence, or `nil` before any transfer ran.
  private(set) var ledgerTransferMessage: String?

  /// Written by `SettingsPanel` through `@Bindable`; every write is validated, persisted and acted
  /// on in ``settingsDidChange(from:)``.
  var settings: AppSettings {
    didSet { settingsDidChange(from: oldValue) }
  }

  /// macOS runs a quarantined app from a read-only temporary directory when it is launched from
  /// outside `/Applications` — S2 measured two real launches doing exactly that. The bundle path
  /// cannot change while the process lives, so this is read once.
  let isTranslocated = Bundle.main.bundlePath.contains("/AppTranslocation/")

  // MARK: - Private state

  private let environment: AppEnvironment
  /// Injection seam: the notification centre. See ``LowBalanceAlerting``.
  private let scheduler: any LowBalanceAlerting
  /// Injection seam: the poll timer and the ticker. See ``AppScheduling``.
  private let scheduling: any AppScheduling
  /// Injection seam: the login item. See ``LoginItemControl``.
  private let loginItem: LoginItemControl
  /// The one owner of the ledger. Injected so the app-layer tests can hand in a source they drive
  /// instead of the developer's opencode database; see ``LocalUsageLedger``.
  private let localUsageLedger: LocalUsageLedger
  /// The calendar every local day boundary is computed with; see ``AppEnvironment/calendar``.
  private let calendar: Calendar
  /// The currency the ledger prices in, for the spend metric. The table's, never the account's.
  private let ledgerCurrency: String
  /// `true` while a ledger pass is running, so a trigger that arrives mid-pass is skipped rather than
  /// queued: the fifteen-minute tick must not join a launch scan of a large database.
  private(set) var isLocalUsageRefreshing = false
  /// Injection seam: the wall clock. The app reads `Date()`; a test moves it, so "stale after an
  /// hour" and "the cooldown has elapsed" are assertions rather than waits.
  private let now: @MainActor () -> Date
  /// Injection seam: the fraction `PollingPlan` scales its additive jitter by. The app draws it from
  /// system randomness; a test pins it to 0, which makes the recorded delay exactly the backoff.
  private let jitterFraction: @MainActor () -> Double

  /// The last successful reading and when it arrived. Seeded from `UserDefaults` at launch so the
  /// popover has something true to show before the first fetch returns.
  private var latestBalance: Balance?
  private(set) var lastSuccess: Date?
  private var consecutiveFailures = 0
  private var lastNotified: Date?
  private var refreshError: String?
  private var importError: String?
  private var loginItemError: String?
  private var monitor: BalanceMonitor
  private var notificationPolicy: NotificationPolicy

  /// Set when `refresh()` arrives while a request is in flight; the next run starts when the
  /// current one finishes, so no caller's refresh is silently dropped.
  private var needsRefreshAgain = false
  private var wakeTask: Task<Void, Never>?
  private let pathMonitor = NWPathMonitor()
  /// `nil` until the first path update arrives, so the initial "we have a path" report is not mistaken
  /// for a network coming back.
  private var networkWasAvailable: Bool?

  /// Every collaborator that leaves the process — the HTTP request, the notification centre, the two
  /// timers, the login item, the clock — is injectable and defaults to the shipping implementation, so
  /// the app still builds this with `AppModel()` and a test replaces only the seams its assertion is
  /// about. Each seam is documented where it is declared.
  init(
    environment: AppEnvironment = AppEnvironment(),
    scheduler: any LowBalanceAlerting = UserNotificationScheduler(),
    scheduling: any AppScheduling = TaskAppScheduler(),
    loginItem: LoginItemControl = .system,
    now: @escaping @MainActor () -> Date = { Date() },
    jitterFraction: @escaping @MainActor () -> Double = { Double.random(in: 0...1) },
    localUsageLedger: LocalUsageLedger? = nil
  ) {
    self.environment = environment
    self.scheduler = scheduler
    self.scheduling = scheduling
    self.loginItem = loginItem
    self.now = now
    self.jitterFraction = jitterFraction
    self.localUsageLedger = localUsageLedger ?? environment.makeLocalUsageLedger()
    self.calendar = environment.calendar
    self.ledgerCurrency = environment.priceTable.currency
    let settings = environment.settingsStore.load()
    self.settings = settings
    self.monitor = environment.balanceMonitor(lowBalanceThreshold: settings.lowBalanceThreshold)
    self.notificationPolicy = environment.notificationPolicy(
      cooldownMinutes: settings.notificationCooldownMinutes)
  }

  // MARK: - Lifecycle

  /// Launch sequence: adopt the persisted reading, render the rate, wire the observers, then fetch.
  ///
  /// `observingSystemEvents` is `false` in tests: the wake notification stream and `NWPathMonitor`
  /// are real macOS sources a unit test cannot drive deterministically — and a path monitor firing on
  /// a network flap would start a refresh in the middle of an unrelated assertion. Everything else,
  /// the key resolution, the persisted reading, the ticker and the fetch included, is the code the app
  /// runs.
  func start(observingSystemEvents: Bool = true) {
    refreshLoginItemStatus()
    _ = resolveKey()
    lastNotified = environment.launchState.loadLastNotified()
    seedFromStoredReading()
    updateRateNow()
    if observingSystemEvents {
      installWakeObserver()
      installNetworkObserver()
    }
    startTicker()
    startLocalUsage()
    if settings.notificationsEnabled {
      Task { await requestNotificationPermission() }
    }
    refresh()
  }

  /// Releases the observers and the timers while AppKit tears the process down.
  func stop() {
    scheduling.cancel()
    wakeTask?.cancel()
    pathMonitor.cancel()
  }

  // MARK: - Balance

  /// Fetches the balance once. Never concurrent: a request that arrives while one is in flight is
  /// remembered rather than dropped — an import made during a poll must not wait out the whole
  /// interval — and starts as soon as the current one finishes.
  func refresh() {
    guard !isRefreshing else {
      needsRefreshAgain = true
      return
    }
    isRefreshing = true
    Task { await performRefresh() }
  }

  private func performRefresh() async {
    let resolution = resolveKey()

    if let key = resolution.key {
      do {
        let balance = try await environment.makeFetcher(key).balance()
        record(balance: balance)
      } catch {
        // The plan backs off on failures, so an outage or a sleeping laptop does not become a
        // request storm. `describe` never includes the key.
        consecutiveFailures = min(consecutiveFailures + 1, Self.maximumBackoffAttempt)
        refreshError = DeepSeekClient.describe(error)
        evaluate()
      }
    } else {
      // No key is not a network failure: the banner names the fix, the last reading stays visible and
      // there is nothing to back off from. An error a previous key produced must not outlive it —
      // with the request skipped there is nothing left that message could be about.
      refreshError = nil
    }
    isRefreshing = false
    notifyIfLow()
    if needsRefreshAgain {
      needsRefreshAgain = false
      refresh()
    } else {
      scheduleNextRefresh()
    }
  }

  /// Everything derived from the last reading and the current settings, recomputed in one place so a
  /// settings change, a fresh reading and a launch seed cannot disagree.
  private func evaluate() {
    let next = monitor.evaluate(balance: latestBalance, lastSuccess: lastSuccess, now: now())
    // The ticker re-evaluates every 30 seconds; writing an unchanged value would invalidate every
    // observer for nothing.
    if next != balanceState { balanceState = next }
  }

  /// One successful reading: in memory, on disk and in the derived state. `UserDefaults`, not the
  /// ledger: this is display state, and losing it only costs an "as of" line on the next launch.
  private func record(balance: Balance) {
    let fetchedAt = now()
    latestBalance = balance
    lastSuccess = fetchedAt
    consecutiveFailures = 0
    refreshError = nil
    environment.launchState.saveReading(
      LaunchStateStore.Reading(balance: balance, fetchedAt: fetchedAt))
    evaluate()
  }

  /// The persisted reading from an earlier run, so a relaunch shows the amount immediately and the
  /// panel says how old it is instead of pretending there is none.
  private func seedFromStoredReading() {
    guard latestBalance == nil, let reading = environment.launchState.loadReading() else { return }
    latestBalance = reading.balance
    lastSuccess = reading.fetchedAt
    evaluate()
  }

  // MARK: - Rate now

  /// Re-renders the window label and the countdown. The countdown is time, not data: this needs no
  /// network and no key.
  private func updateRateNow() {
    guard environment.priceTableProblem == nil else {
      // Without a readable table there are no prices and no windows; the panel says so and a banner
      // names the file.
      rateNow = nil
      return
    }
    rateNow = environment.rateNow.display(at: now())
  }

  // MARK: - Scheduling

  /// Arms the next refresh from `PollingPlan`: the configured interval, doubled per consecutive
  /// failure and capped, plus additive jitter so many installs do not poll in lockstep. The delay is
  /// handed to ``AppScheduling``, which is where a test reads it back.
  private func scheduleNextRefresh() {
    let plan = PollingPlan(interval: TimeInterval(settings.refreshIntervalMinutes) * 60)
    let instant = now()
    let next = plan.nextRefresh(
      after: instant, attempt: consecutiveFailures, jitterFraction: jitterFraction())
    let delay = max(1, next.timeIntervalSince(instant))
    scheduling.scheduleRefresh(after: delay) { [weak self] in self?.refresh() }
  }

  /// A wake is the moment the schedule is definitely wrong: the machine was asleep through it, so
  /// refresh now instead of waiting out an interval that was measured against a stopped clock.
  private func installWakeObserver() {
    wakeTask?.cancel()
    wakeTask = Task { [weak self] in
      let notifications = NSWorkspace.shared.notificationCenter.notifications(
        named: NSWorkspace.didWakeNotification)
      for await _ in notifications {
        guard let self, !Task.isCancelled else { return }
        self.refresh()
      }
    }
  }

  /// `NWPathMonitor` reports the path the machine has, not whether DeepSeek is reachable, so a
  /// refresh happens on the unsatisfied → satisfied edge only: a monitor that polls on every callback
  /// is a second poll loop nobody asked for.
  private func installNetworkObserver() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let available = path.status == .satisfied
      Task { @MainActor [weak self] in
        guard let self else { return }
        let wasAvailable = self.networkWasAvailable
        self.networkWasAvailable = available
        guard available, wasAvailable == false else { return }
        self.refresh()
      }
    }
    pathMonitor.start(
      queue: DispatchQueue(label: "io.github.genoma.deeptally.network", qos: .utility))
  }

  /// The 30-second ticker. The balance state is `BalanceMonitor.evaluate`'s business and that is
  /// pure, so the tick can keep the age text, the stale flag and the login-item status truthful
  /// between refreshes — the maximum cadence is four hours, far past the one-hour stale window. It
  /// never fetches and never notifies.
  private func tick() {
    updateRateNow()
    evaluate()
    refreshLoginItemStatus()
  }

  private func startTicker() {
    scheduling.startTicker(every: TimeInterval(Self.tickerSeconds)) { [weak self] in self?.tick() }
  }

  // MARK: - Notifications

  /// Posts the low-balance alert when the policy says the user is due one. The alert carries the
  /// amount and the threshold — never a key — and the cooldown is stamped only once macOS has
  /// accepted the notification, so a denial or a failed post is retried instead of silenced.
  private func notifyIfLow() {
    guard settings.notificationsEnabled,
      let state = balanceState,
      state.isLow,
      let amountText = state.amountText
    else { return }

    guard
      notificationPolicy.shouldNotify(
        isLow: state.isLow, isStale: state.isStale, lastNotified: lastNotified, now: now())
    else { return }

    let threshold = Self.amountText(
      for: settings.lowBalanceThreshold, likeAmount: amountText)
    Task { await postLowBalance(amountText: amountText, threshold: threshold) }
  }

  /// The post itself, off the caller. `accepted` decides everything: only a delivered alert consumes
  /// the cooldown, and the authorization macOS reports is recorded either way so the popover can tell
  /// "not allowed" from "delivery failed" without guessing.
  private func postLowBalance(amountText: String, threshold: String) async {
    let accepted = await scheduler.postLowBalance(amountText: amountText, threshold: threshold)
    alertAuthorization = await scheduler.authorization()
    guard accepted else { return }
    let stamped = now()
    lastNotified = stamped
    environment.launchState.saveLastNotified(stamped)
  }

  /// Asks macOS for permission and records what it says. The answer can arrive long after the fetch
  /// that made the balance low, so a grant re-runs the policy: the first alert is delivered then
  /// instead of waiting for the next poll. The policy still bounds it, so a grant cannot itself
  /// cause a second alert.
  private func requestNotificationPermission() async {
    let granted = await scheduler.requestAuthorization()
    alertAuthorization = await scheduler.authorization()
    if granted { notifyIfLow() }
  }

  /// The threshold rendered the way the balance is (`$2.00`, `¥2.00`, `CHF 2.00`): the alert is read
  /// next to the panel, so both amounts have to be the same shape. The currency prefix comes from the
  /// amount text itself, which keeps `BalanceMonitor` the single place that maps a currency to a
  /// symbol, and nothing is ever converted.
  private static func amountText(for value: Decimal, likeAmount amountText: String) -> String {
    let prefix = amountText.prefix { !$0.isNumber && $0 != "." }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.roundingMode = .halfUp
    return prefix + (formatter.string(from: value as NSDecimalNumber) ?? "\(value)")
  }

  // MARK: - Key

  /// Runs the one-time import from the login shell.
  ///
  /// `importFromShell` waits on a shell for up to its timeout, so it runs in a detached task
  /// (AGENTS.md §8: no blocking on the main actor). The value it returns is discarded inside that
  /// task: the key continues to the Keychain and nowhere else.
  func importKey(from shell: ShellKind) {
    guard !isImportingKey else { return }
    isImportingKey = true
    importMessage = nil
    importError = nil
    Task { await performImport(shell) }
  }

  private func performImport(_ shell: ShellKind) async {
    defer { isImportingKey = false }
    let source = environment.keySource
    do {
      try await Task.detached(priority: .userInitiated) {
        _ = try source.importFromShell(shell)
      }.value
      importMessage = "Imported the key from your \(shell.rawValue) login shell."
      // A newly imported key is not the key any error on screen came from, and the refresh queued
      // here must not be dropped just because a poll happens to be in flight.
      refreshError = nil
      keyOrigin = .keychain
      refresh()
    } catch let error as KeyImportError {
      showImportFailure(Self.describe(error, shell: shell))
    } catch {
      showImportFailure("Importing the key from the \(shell.rawValue) login shell failed.")
    }
  }

  /// Forgets the stored key. The process environment may still supply one, so the origin is resolved
  /// again rather than assumed to be gone.
  func deleteKey() {
    guard !isImportingKey else { return }
    do {
      try environment.keySource.deleteKey()
      importMessage = "Removed the stored key from the Keychain."
      importError = nil
    } catch let error as KeychainError {
      showImportFailure("Could not remove the stored key (\(Self.describe(error))).")
    } catch {
      showImportFailure("Could not remove the stored key.")
    }
    // Forgetting a key invalidates any error the old one produced: an unresolvable store must not
    // leave a "401" on screen next to the "No API key yet" banner.
    refreshError = nil
    _ = resolveKey()
  }

  private func showImportFailure(_ message: String) {
    importError = message
    importMessage = message
  }

  /// The key for the next request, where it came from and any Keychain problem. `resolve()` never
  /// runs a shell, so this is safe on the main actor, and it is the single place `keyOrigin` and
  /// `keychainProblem` are written, so neither can disagree with what a request will actually use.
  ///
  /// A different origin is a different key: whatever error the previous one produced (a 401, an
  /// outage) is cleared here rather than left next to the new state.
  private func resolveKey() -> KeyResolution {
    let resolution = environment.keySource.resolve()
    if resolution.origin != keyOrigin { refreshError = nil }
    keyOrigin = resolution.origin
    keychainProblem = resolution.keychainProblem
    return resolution
  }

  /// Where the key comes from, for the footer. Never the key itself, not even its prefix.
  var keyOriginLabel: String {
    switch keyOrigin {
    case .none: return "API key: none"
    case .keychain: return "API key: Keychain"
    case .environment: return "API key: DEEPSEEK_API_KEY"
    }
  }

  // MARK: - Login item

  /// Registers or removes the login item. Never attempted from a translocated copy: its path is a
  /// read-only temporary directory that disappears, so macOS would register a login item pointing at
  /// nothing (S2).
  func setLaunchAtLogin(_ enabled: Bool) {
    guard !isTranslocated else { return }
    do {
      if enabled {
        try loginItem.register()
      } else {
        try loginItem.unregister()
      }
      loginItemError = nil
    } catch {
      loginItemError = LoginItem.describe(error)
    }
    refreshLoginItemStatus()
  }

  /// Re-reads macOS's login-item status. Called at launch, after a toggle and by the ticker: an item
  /// the user approves in System Settings while the app runs must clear "Waiting for approval…"
  /// without a relaunch.
  private func refreshLoginItemStatus() {
    let status = loginItem.status()
    if status != loginItemStatus { loginItemStatus = status }
  }

  var launchAtLoginEnabled: Bool {
    loginItemStatus == .enabled || loginItemStatus == .requiresApproval
  }

  /// `nil` while a plain on or off needs no explanation; otherwise the one line that says what macOS
  /// still wants from the user.
  var loginItemStatusNote: String? {
    switch loginItemStatus {
    case .notRegistered, .enabled: return nil
    case .requiresApproval:
      return "Waiting for approval in System Settings → General → Login Items."
    case .notFound:
      return "macOS has no login item for DeepTally; registration works best from /Applications."
    case .unknown(let raw):
      return "macOS reported a login-item status this build does not know (\(raw))."
    }
  }

  // MARK: - Settings

  /// A settings write is validated, persisted and acted on in one place: the interval feeds the
  /// schedule, the threshold feeds the monitor, the cooldown feeds the alert policy.
  private func settingsDidChange(from previous: AppSettings) {
    guard settings != previous else { return }
    let validated = settings.validated()
    if validated != settings {
      // Re-validating in memory is what keeps `validated()` the only state the app acts on. This
      // re-enters the observer once; `validated()` is idempotent, so the second pass has nothing left
      // to clamp and both passes do the same idempotent work.
      settings = validated
    }
    environment.settingsStore.save(validated)
    monitor = environment.balanceMonitor(lowBalanceThreshold: validated.lowBalanceThreshold)
    notificationPolicy = environment.notificationPolicy(
      cooldownMinutes: validated.notificationCooldownMinutes)
    evaluate()
    scheduleNextRefresh()
    // A metric the ledger backs must not wait for the next import tick to get its first number.
    if validated.menuBarMetric != .balance, localUsage == nil {
      refreshLocalUsage()
    }
    if validated.notificationsEnabled, !previous.notificationsEnabled {
      Task { await requestNotificationPermission() }
    }
  }

  /// The ledger pass, once at launch and every fifteen minutes after it. A separate, fixed cadence:
  /// it is a local file read, and "why did my spend not update?" is worse than a number that lags by
  /// a few minutes. It runs even while the balance metric is selected, so switching metric never
  /// waits for the next tick.
  private func startLocalUsage() {
    scheduling.startLedgerTicker(every: Self.localUsageIntervalSeconds) { [weak self] in
      self?.refreshLocalUsage()
    }
    refreshLocalUsage()
  }

  /// Runs one import-and-query pass. The SQLite work belongs to ``LocalUsageLedger``'s actor, so
  /// nothing here can block the UI; the main actor only records what came back.
  ///
  /// A pass is skipped while one is already in flight, so the fifteen-minute tick cannot join a
  /// launch scan that is still reading the opencode database.
  func refreshLocalUsage() {
    guard !isLocalUsageRefreshing else { return }
    isLocalUsageRefreshing = true
    let now = self.now()
    let calendar = self.calendar
    let ledger = localUsageLedger
    Task { [weak self] in
      let outcome = await ledger.refresh(now: now, calendar: calendar)
      guard let self else { return }
      self.isLocalUsageRefreshing = false
      self.localUsageProblem = outcome.importProblem
      self.localUsagePricingNote = outcome.pricingNote
      // A failed pass keeps the last good numbers: blanking them would turn a transient unreadable
      // file into "you spent nothing".
      if let metrics = outcome.metrics { self.localUsage = metrics }
    }
  }

  // MARK: - CSV transfer

  /// Opens a save panel and writes the ledger as CSV. Choosing a destination is the modal step; the
  /// write itself runs on the ledger's actor.
  func exportLedger() {
    guard !isTransferringLedger else { return }
    let name = LedgerPanels.suggestedExportName(now: now())
    guard let url = LedgerPanels.chooseExportURL(suggestedName: name) else { return }
    exportLedger(to: url)
  }

  /// The testable half of the export: a path the caller chose, so the file and the sentence can be
  /// asserted without a modal panel.
  func exportLedger(to url: URL) {
    guard !isTransferringLedger else { return }
    isTransferringLedger = true
    ledgerTransferMessage = nil
    let ledger = localUsageLedger
    Task { [weak self] in
      do {
        let outcome = try await ledger.exportCSV(to: url)
        guard let self else { return }
        self.isTransferringLedger = false
        self.ledgerTransferMessage =
          "Exported \(Self.rowCount(outcome.rows)) to \(url.lastPathComponent)."
      } catch {
        guard let self else { return }
        self.isTransferringLedger = false
        self.ledgerTransferMessage = Self.describeTransferFailure(error)
      }
    }
  }

  /// Opens an open panel and imports the file it returns.
  func importLedger() {
    guard !isTransferringLedger else { return }
    guard let url = LedgerPanels.chooseImportURL() else { return }
    importLedger(from: url)
  }

  /// The testable half of the import. A successful import re-reads the metrics and the unpriced
  /// note, so a file full of rows the price table cannot price shows the same quiet caveat an
  /// opencode import would set — not a second, different notice.
  func importLedger(from url: URL) {
    guard !isTransferringLedger else { return }
    isTransferringLedger = true
    ledgerTransferMessage = nil
    let ledger = localUsageLedger
    Task { [weak self] in
      do {
        let outcome = try await ledger.importCSV(from: url)
        guard let self else { return }
        self.isTransferringLedger = false
        self.ledgerTransferMessage =
          outcome.rows == 0
          ? "Imported nothing new from \(url.lastPathComponent); every row was already stored."
          : "Imported \(Self.rowCount(outcome.rows)) from \(url.lastPathComponent)."
        self.refreshLocalUsage()
      } catch {
        guard let self else { return }
        self.isTransferringLedger = false
        self.ledgerTransferMessage = Self.describeTransferFailure(error)
      }
    }
  }

  /// `2 rows`, `1 row`, `0 rows` — the count and the noun together, so no caller can pluralise one
  /// without the other.
  private static func rowCount(_ rows: Int) -> String {
    "\(MetricFormatting.groupedCount(rows)) \(rows == 1 ? "row" : "rows")"
  }

  /// One user-facing sentence for a failed transfer, from the cases a user can actually reach.
  ///
  /// Deliberately **not** exhaustive over `LedgerError` (AGENTS.md §9.14): an unknown case falls back
  /// to a generic sentence instead of failing this target to compile, and no branch can echo a row's
  /// contents — the messages carry a file name and, for a bad row, the line number and the parser's
  /// own reason.
  private static func describeTransferFailure(_ error: Error) -> String {
    guard let ledgerError = error as? LedgerError else {
      return "The CSV transfer failed."
    }
    switch ledgerError {
    case .fileMissing(let path), .unreadableFile(let path, _):
      return "Could not read \(URL(fileURLWithPath: path).lastPathComponent)."
    case .cannotWrite(let path, _):
      return "Could not write \(URL(fileURLWithPath: path).lastPathComponent)."
    case .malformedCSV(let line, let reason):
      return "That CSV cannot be imported: \(reason) (line \(line))."
    default:
      return "The CSV transfer failed."
    }
  }

  // MARK: - Menu bar

  /// The menu bar title. Every mode has a number behind it: the balance comes from the API, the other
  /// two from the ledger. A number the app does not have is never shown — an em dash is honest, a
  /// fabricated zero is not.
  var menuBarLabel: String {
    switch settings.menuBarMetric {
    case .balance: return balanceState?.amountText ?? "—"
    case .todaySpend: return todaySpendText ?? "—"
    case .cacheHitRate: return cacheHitRateText
    }
  }

  /// Today's spend over the current local day, formatted the way the balance is. `nil` until a read of
  /// the ledger has succeeded, since a failed pass has no business claiming `$0.00`.
  var todaySpendText: String? {
    localUsage.map { MetricFormatting.spend($0.todaySpendUSD, currency: ledgerCurrency) }
  }

  /// Cache hits over prompt tokens for the trailing 30 days; an em dash when the window recorded no
  /// prompt tokens (or none at all yet).
  var cacheHitRateText: String {
    MetricFormatting.cacheHitPercent(localUsage?.cacheHitRatio)
  }

  /// The one line the settings panel shows while local usage needs a caveat: not being imported at
  /// all, or being imported with some rows the price table cannot price. Quiet on purpose: neither a
  /// missing opencode database nor an unpriced model is something the user has to fix for the
  /// balance, the alerts or the rate panel to keep working.
  var localUsageNote: String? {
    if localUsageProblem != nil { return "Local usage is not being imported yet." }
    return localUsagePricingNote
  }

  /// Everything the status item's button shows, derived in one place so the menu bar and
  /// `--spike render-popover` cannot disagree — and so the low-balance fallback is provable without
  /// a human looking at the screen.
  struct MenuBarPresentation: Equatable {
    let title: String
    /// The balance is low: the shipped glyph gives way to a warning triangle, because the alert the
    /// user asked for may never be delivered.
    let showsLowBalanceWarning: Bool
    /// The button's tooltip while the warning is shown, naming the amount; `nil` otherwise.
    let tooltip: String?
  }

  var menuBarPresentation: MenuBarPresentation {
    let isLow = balanceState?.isLow == true
    var tooltip: String?
    if isLow, let amountText = balanceState?.amountText {
      tooltip = "DeepSeek balance \(amountText) is low."
    }
    return MenuBarPresentation(
      title: menuBarLabel, showsLowBalanceWarning: isLow, tooltip: tooltip)
  }

  /// `true` while the user has alerts switched on but macOS reports them denied. The popover states
  /// that once, and the menu-bar warning glyph is the fallback. An authorization that was never read
  /// is not a denial, so nothing is claimed before macOS has said anything.
  var alertsUnavailable: Bool {
    settings.notificationsEnabled && alertAuthorization == .denied
  }

  // MARK: - Banners

  /// The notices to show, most actionable first. Every one of them is derived from live state, so a
  /// fixed problem removes its own banner on the next evaluation.
  var banners: [Banner] {
    var banners: [Banner] = []
    if isTranslocated {
      banners.append(
        Banner(
          id: "translocation",
          kind: .warning,
          message:
            "Running from a temporary read-only copy. Drag DeepTally into /Applications and relaunch "
            + "— the login item cannot be registered from here."
        ))
    }
    if keyOrigin == .none {
      banners.append(
        Banner(
          id: "no-key", kind: .warning,
          message: "No API key yet. Import it from your login shell in Settings below."))
    }
    if let keychainProblem {
      banners.append(
        Banner(
          id: "keychain-problem", kind: .warning,
          message: "Keychain read problem: \(keychainProblem)."
            + (keyOrigin == .environment ? " Using DEEPSEEK_API_KEY instead." : "")))
    }
    if let importError {
      banners.append(Banner(id: "key-import", kind: .error, message: importError))
    }
    if let problem = environment.priceTableProblem {
      banners.append(
        Banner(
          id: "price-table", kind: .warning,
          message: "Pricing data problem: \(problem) No prices are shown until it is fixed."))
    }
    if let problem = environment.priceOverrideProblem {
      // The bundled table is usable, so this is a note, not a failure: the rate panel still shows
      // prices and the sentence already says which table they came from.
      banners.append(Banner(id: "price-override", kind: .warning, message: problem))
    }
    if let problem = environment.holidayCalendarProblem {
      banners.append(
        Banner(
          id: "holiday-calendar", kind: .warning,
          message: "Holiday data problem: \(problem) Peak hours on Chinese public holidays may be "
            + "over-reported."))
    }
    if let refreshError {
      banners.append(Banner(id: "refresh", kind: .error, message: refreshError))
    }
    if let loginItemError {
      banners.append(Banner(id: "login-item", kind: .error, message: loginItemError))
    }
    return banners
  }

  // MARK: - Descriptions

  /// A `KeyImportError` as a plain sentence, the same mapping `deeptally key import` prints. No case
  /// carries the secret or any shell output.
  private static func describe(_ error: KeyImportError, shell: ShellKind) -> String {
    switch error {
    case .notFoundInShell:
      return "No DEEPSEEK_API_KEY in your \(shell.rawValue) login shell. Export it in "
        + "\(rcFiles(shell)) and try again."
    case .emptySecret:
      return "The \(shell.rawValue) login shell printed something that is not a usable key."
    case .shellTimedOut:
      return "The \(shell.rawValue) login shell did not finish in time."
    case .shellFailed(let status):
      return "The \(shell.rawValue) login shell exited with status \(status)."
    case .keychain(let status):
      return "Storing the key in the Keychain failed (status \(status))."
    }
  }

  /// A `KeychainError` as a sentence: a status code or a flag, never the secret.
  private static func describe(_ error: KeychainError) -> String {
    switch error {
    case .unexpectedStatus(let status): return "Keychain status \(status)"
    case .invalidSecret: return "the value is not a usable key"
    }
  }

  /// What `-l -i` sources, named so the message can tell the user where to export the variable.
  private static func rcFiles(_ shell: ShellKind) -> String {
    switch shell {
    case .zsh: return "~/.zprofile or ~/.zshrc"
    case .bash: return "~/.bash_profile or ~/.bashrc"
    }
  }

  /// The countdown is rendered in whole minutes, so half a minute is the smallest tick that can
  /// change it.
  private static let tickerSeconds = 30
  /// How often local usage is imported: at launch, then every fifteen minutes. Fixed, not a setting —
  /// it is a local file read, and the point is that the metrics are live without user action.
  static let localUsageIntervalSeconds: TimeInterval = 15 * 60
  /// `PollingPlan` doubles the wait per attempt and caps it; this keeps the counter small enough that
  /// the exponent cannot run away.
  private static let maximumBackoffAttempt = 8
}
