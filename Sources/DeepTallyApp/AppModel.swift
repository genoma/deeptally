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
/// - nothing blocking runs on the main actor: importing a key is the one blocking call in the app and
///   it runs in a detached task;
/// - the API key leaves the Keychain only as the `Bearer` argument of one request. It is never
///   logged, never written to `UserDefaults`, and never displayed (AGENTS.md §5);
/// - a low-balance alert is remembered as delivered only after macOS accepted it, so a denial or a
///   failed post is retried instead of consuming the cooldown; while macOS will not deliver alerts,
///   the menu bar carries the warning glyph and the popover says so once.
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
  private let scheduler: UserNotificationScheduler

  /// The last successful reading and when it arrived. Seeded from `UserDefaults` at launch so the
  /// popover has something true to show before the first fetch returns.
  private var latestBalance: Balance?
  private var lastSuccess: Date?
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
  private var pollTask: Task<Void, Never>?
  private var tickerTask: Task<Void, Never>?
  private var wakeTask: Task<Void, Never>?
  private let pathMonitor = NWPathMonitor()
  /// `nil` until the first path update arrives, so the initial "we have a path" report is not mistaken
  /// for a network coming back.
  private var networkWasAvailable: Bool?

  init(environment: AppEnvironment = AppEnvironment()) {
    self.environment = environment
    self.scheduler = UserNotificationScheduler()
    let settings = environment.settingsStore.load()
    self.settings = settings
    self.monitor = environment.balanceMonitor(lowBalanceThreshold: settings.lowBalanceThreshold)
    self.notificationPolicy = environment.notificationPolicy(
      cooldownMinutes: settings.notificationCooldownMinutes)
  }

  // MARK: - Lifecycle

  /// Launch sequence: adopt the persisted reading, render the rate, wire the observers, then fetch.
  func start() {
    refreshLoginItemStatus()
    _ = resolveKey()
    lastNotified = environment.launchState.loadLastNotified()
    seedFromStoredReading()
    updateRateNow()
    installWakeObserver()
    installNetworkObserver()
    startTicker()
    if settings.notificationsEnabled {
      Task { await requestNotificationPermission() }
    }
    refresh()
  }

  /// Releases the observers and the timers while AppKit tears the process down.
  func stop() {
    pollTask?.cancel()
    tickerTask?.cancel()
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
        let balance = try await environment.makeClient(key).balance()
        record(balance: balance, at: Date())
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
  private func evaluate(now: Date = Date()) {
    let next = monitor.evaluate(balance: latestBalance, lastSuccess: lastSuccess, now: now)
    // The ticker re-evaluates every 30 seconds; writing an unchanged value would invalidate every
    // observer for nothing.
    if next != balanceState { balanceState = next }
  }

  /// One successful reading: in memory, on disk and in the derived state. `UserDefaults`, not the
  /// ledger: this is display state, and losing it only costs an "as of" line on the next launch.
  private func record(balance: Balance, at now: Date) {
    latestBalance = balance
    lastSuccess = now
    consecutiveFailures = 0
    refreshError = nil
    environment.launchState.saveReading(
      LaunchStateStore.Reading(balance: balance, fetchedAt: now))
    evaluate(now: now)
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
    rateNow = environment.rateNow.display(at: Date())
  }

  // MARK: - Scheduling

  /// Arms the next refresh from `PollingPlan`: the configured interval, doubled per consecutive
  /// failure and capped, plus additive jitter so many installs do not poll in lockstep.
  private func scheduleNextRefresh() {
    pollTask?.cancel()
    let plan = PollingPlan(interval: TimeInterval(settings.refreshIntervalMinutes) * 60)
    let now = Date()
    let next = plan.nextRefresh(
      after: now, attempt: consecutiveFailures, jitterFraction: Double.random(in: 0...1))
    let delay = max(1, next.timeIntervalSince(now))
    pollTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
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
    tickerTask?.cancel()
    tickerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.tickerSeconds))
        guard !Task.isCancelled else { return }
        self?.tick()
      }
    }
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
        isLow: state.isLow, isStale: state.isStale, lastNotified: lastNotified, now: Date())
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
    let stamped = Date()
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
        try LoginItem.register()
      } else {
        try LoginItem.unregister()
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
    let status = LoginItem.status
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
    if validated.notificationsEnabled, !previous.notificationsEnabled {
      Task { await requestNotificationPermission() }
    }
  }

  // MARK: - Menu bar

  /// The menu bar title. Step 3 has no ledger, so the balance is the only metric with a value; the
  /// other two are an em dash until Step 4 gives them one. A number the app does not have is never
  /// shown.
  var menuBarLabel: String {
    switch settings.menuBarMetric {
    case .balance: return balanceState?.amountText ?? "—"
    case .todaySpend, .cacheHitRate: return "—"
    }
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
  /// `PollingPlan` doubles the wait per attempt and caps it; this keeps the counter small enough that
  /// the exponent cannot run away.
  private static let maximumBackoffAttempt = 8
}
