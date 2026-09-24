// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DeepTallyCore
import Foundation
import Network
import Observation

/// The integrator: one object that owns the key, the polling schedule, the derived balance state, the
/// rate-now display, the settings and the notices the popover shows.
///
/// Three rules this type exists to keep:
/// - a refresh never runs twice at once, and the next one always comes from `PollingPlan`
///   (interval, then backoff, then jitter) rather than from a hand-rolled timer chain;
/// - nothing blocking runs on the main actor: importing a key is the one blocking call in the app and
///   it runs in a detached task;
/// - the API key leaves the Keychain only as the `Bearer` argument of one request. It is never
///   logged, never written to `UserDefaults`, and never displayed (AGENTS.md §5).
@MainActor
@Observable
final class AppModel {
  /// Where the key in use came from. `unreadable` carries a Keychain status, never a secret.
  enum KeyOrigin: Equatable {
    case none
    case keychain
    case environment
    case unreadable(String)
  }

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
  private(set) var keyOrigin: KeyOrigin = .none
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
    loginItemStatus = LoginItem.status
    keyOrigin = resolveKey().origin
    lastNotified = environment.launchState.loadLastNotified()
    seedFromStoredReading()
    updateRateNow()
    installWakeObserver()
    installNetworkObserver()
    startTicker()
    if settings.notificationsEnabled {
      Task { await scheduler.requestAuthorization() }
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

  /// Fetches the balance once. Never concurrent: while a request is in flight this is a no-op, so a
  /// wake, a click and a timer cannot stack up three requests.
  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    Task { await performRefresh() }
  }

  private func performRefresh() async {
    let resolution = resolveKey()
    keyOrigin = resolution.origin

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
    }
    // No key is not a network failure: the banner names the fix, the last reading stays visible and
    // there is nothing to back off from.
    isRefreshing = false
    notifyIfLow()
    scheduleNextRefresh()
  }

  /// Everything derived from the last reading and the current settings, recomputed in one place so a
  /// settings change, a fresh reading and a launch seed cannot disagree.
  private func evaluate(now: Date = Date()) {
    balanceState = monitor.evaluate(balance: latestBalance, lastSuccess: lastSuccess, now: now)
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
  /// network and no key, and it is the only thing the 30-second ticker does.
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

  private func startTicker() {
    tickerTask?.cancel()
    tickerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.tickerSeconds))
        guard !Task.isCancelled else { return }
        self?.updateRateNow()
      }
    }
  }

  // MARK: - Notifications

  /// Posts the low-balance alert when the policy says the user is due one, and remembers when, so the
  /// cooldown survives a relaunch. The alert carries the amount and the threshold — never a key.
  private func notifyIfLow() {
    guard settings.notificationsEnabled,
      let state = balanceState,
      state.isLow,
      let amountText = state.amountText
    else { return }

    let now = Date()
    guard
      notificationPolicy.shouldNotify(
        isLow: state.isLow, isStale: state.isStale, lastNotified: lastNotified, now: now)
    else { return }

    lastNotified = now
    environment.launchState.saveLastNotified(now)
    let threshold = Self.amountText(
      for: settings.lowBalanceThreshold, likeAmount: amountText)
    Task { await scheduler.postLowBalance(amountText: amountText, threshold: threshold) }
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
    keyOrigin = resolveKey().origin
  }

  private func showImportFailure(_ message: String) {
    importError = message
    importMessage = message
  }

  /// The key for the next request, and where it came from. `currentKey()` never runs a shell, so this
  /// is safe on the main actor.
  private func resolveKey() -> (key: String?, origin: KeyOrigin) {
    do {
      guard let key = try environment.keySource.currentKey() else { return (nil, .none) }
      // `currentKey()` prefers the Keychain, so an existing item is where the key came from.
      return (key, environment.keychain.hasItem() ? .keychain : .environment)
    } catch let error as KeychainError {
      return (nil, .unreadable(Self.describe(error)))
    } catch {
      return (nil, .unreadable("unknown error"))
    }
  }

  /// Where the key comes from, for the footer. Never the key itself, not even its prefix.
  var keyOriginLabel: String {
    switch keyOrigin {
    case .none: return "API key: none"
    case .keychain: return "API key: Keychain"
    case .environment: return "API key: DEEPSEEK_API_KEY"
    case .unreadable: return "API key: Keychain unreadable"
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
    loginItemStatus = LoginItem.status
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
      Task { await scheduler.requestAuthorization() }
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
    switch keyOrigin {
    case .none:
      banners.append(
        Banner(
          id: "no-key", kind: .warning,
          message: "No API key yet. Import it from your login shell in Settings below."))
    case .unreadable(let detail):
      banners.append(
        Banner(
          id: "key-unreadable", kind: .error,
          message: "Could not read the API key from the Keychain (\(detail))."))
    case .keychain, .environment:
      break
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
