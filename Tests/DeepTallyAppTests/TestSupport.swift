// SPDX-License-Identifier: GPL-3.0-or-later
import DeepTallyCore
import Foundation
import Synchronization
import Testing

@testable import DeepTallyApp

// MARK: - Fixtures

/// Money in tests is parsed from a string, the way the app parses it, so no assertion depends on
/// binary-float rounding.
func decimal(_ raw: String) -> Decimal {
  Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) ?? .zero
}

/// One `/user/balance` reading, USD unless a test is about the currency.
func usdBalance(_ amount: String, isAvailable: Bool = true) -> Balance {
  let total = decimal(amount)
  return Balance(
    isAvailable: isAvailable,
    infos: [
      BalanceInfo(
        currency: "USD", totalBalance: total, grantedBalance: .zero, toppedUpBalance: total)
    ])
}

/// A fake environment key. Never a real one: nothing in this repo may carry a live secret.
let testEnvironmentKey = "sk-test-environment-key"

/// The service every test-owned Keychain item lives under. The shipped item
/// (`io.github.genoma.deeptally`) is never read or written here.
let testKeychainService = "io.github.genoma.deeptally.tests.appmodel"

// MARK: - Timing

/// A clock the test moves by hand. The app layer makes two time-based decisions — "the reading is
/// stale after an hour" and "the cooldown has elapsed" — and both become assertions on this instead
/// of waits.
@MainActor
final class TestClock {
  /// A fixed instant, so no test reads the real wall clock.
  private(set) var now = Date(timeIntervalSince1970: 1_770_000_000)

  func advance(_ interval: TimeInterval) {
    now = now.addingTimeInterval(interval)
  }
}

/// The timers as a test double: it records the delay the model computed and the ticker interval, and
/// fires the callbacks when the test asks — so nothing here waits out a poll.
@MainActor
final class TestScheduler: AppScheduling {
  /// Every delay the model asked for, oldest first.
  private(set) var refreshDelays: [TimeInterval] = []
  /// Every tolerance that came with a delay, oldest first.
  private(set) var refreshTolerances: [TimeInterval] = []
  private(set) var tickerInterval: TimeInterval?
  private(set) var cancels = 0
  private var refreshRun: (@MainActor () -> Void)?
  private var tickRun: (@MainActor () -> Void)?

  var lastRefreshDelay: TimeInterval? { refreshDelays.last }
  var lastRefreshTolerance: TimeInterval? { refreshTolerances.last }

  func scheduleRefresh(
    after delay: TimeInterval, tolerance: TimeInterval, _ run: @escaping @MainActor () -> Void
  ) {
    refreshDelays.append(delay)
    refreshTolerances.append(tolerance)
    refreshRun = run
  }

  func startTicker(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
    tickerInterval = interval
    tickRun = tick
  }

  func cancel() {
    cancels += 1
    refreshRun = nil
    tickRun = nil
  }

  /// Runs the refresh the model scheduled, without waiting for its delay.
  func fireScheduledRefresh() {
    refreshRun?()
  }

  /// Runs one tick, as the 30-second ticker would.
  func fireTick() {
    tickRun?()
  }
}

/// The power source as a test double: the backstop's battery behaviour must not depend on whether the
/// machine running the suite is plugged in.
@MainActor
final class StubPowerState: PowerStateProviding {
  var isOnBattery = false
  var isLowPowerMode = false
}

// MARK: - Network

/// A `BalanceFetching` the test drives: a fixed reading or one API error, the keys requests were made
/// with, and a gate that can hold a request open.
///
/// `Mutex` rather than an actor because `balance()` runs on the model's refresh task while the test
/// asserts from the main actor: synchronous accessors are what let an assertion read the call log
/// without an `await` that could itself let the model make progress.
final class StubBalanceFetcher: BalanceFetching, Sendable {
  enum Outcome: Sendable {
    case balance(Balance)
    case failure(DeepSeekClient.APIError)
  }

  private struct State: Sendable {
    var outcome: Outcome
    var keys: [String] = []
    var active = 0
    var maximumActive = 0
    var isHolding = false
    var isReleased = false
    var waiting: [CheckedContinuation<Void, Never>] = []
  }

  private let state: Mutex<State>

  init(outcome: Outcome) {
    state = Mutex(State(outcome: outcome))
  }

  /// Binds the key this request will be made with; the key comes from `AppEnvironment.makeFetcher`,
  /// so what this records is exactly what the model resolved.
  func binding(for key: String) -> any BalanceFetching {
    KeyedFetcher(key: key, fetcher: self)
  }

  /// The keys requests were made with, oldest first. Test values only.
  var keysUsed: [String] { state.withLock { $0.keys } }

  var callCount: Int { state.withLock { $0.keys.count } }

  /// The most requests that were ever in flight at once: 1 while refreshes are serialized, 2 if the
  /// model ever ran two at the same time.
  var maximumConcurrentCalls: Int { state.withLock { $0.maximumActive } }

  func setOutcome(_ outcome: Outcome) {
    state.withLock { $0.outcome = outcome }
  }

  /// Makes later requests wait at the gate until ``release()``.
  func holdRequestsOpen() {
    state.withLock { $0.isHolding = true }
  }

  /// Opens the gate: requests already waiting — and any that arrives afterwards — proceed.
  func release() {
    let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.isReleased = true
      defer { state.waiting = [] }
      return state.waiting
    }
    for continuation in waiting { continuation.resume() }
  }

  /// Notes the key a request is about to be made with. ``KeyedFetcher`` is the only caller.
  fileprivate func noteRequest(key: String) {
    state.withLock { $0.keys.append(key) }
  }

  func balance() async throws -> Balance {
    state.withLock {
      $0.active += 1
      $0.maximumActive = max($0.maximumActive, $0.active)
    }
    await waitAtGate()
    let outcome = state.withLock { $0.outcome }
    state.withLock { $0.active -= 1 }
    switch outcome {
    case .balance(let balance): return balance
    case .failure(let error): throw error
    }
  }

  /// Suspends while the gate is closed. Testing `isReleased` inside the continuation's body, under the
  /// same lock that `release()` takes, is what closes the race between "the test saw the request
  /// arrive" and "the request started waiting".
  private func waitAtGate() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let proceed = state.withLock { state -> Bool in
        guard state.isHolding, !state.isReleased else { return true }
        state.waiting.append(continuation)
        return false
      }
      if proceed { continuation.resume() }
    }
  }
}

/// What ``StubBalanceFetcher/binding(for:)`` returns: the key the request will be made with, plus the
/// single stub every request lands on.
private struct KeyedFetcher: BalanceFetching {
  let key: String
  let fetcher: StubBalanceFetcher

  func balance() async throws -> Balance {
    fetcher.noteRequest(key: key)
    return try await fetcher.balance()
  }
}

// MARK: - Notifications

/// The notification centre as a test double: what macOS reports, what it accepts, and the alerts it
/// was asked to post.
@MainActor
final class StubAlertScheduler: LowBalanceAlerting {
  /// What `authorization()` reports, and therefore what the popover may claim.
  var authorizationStatus: AlertAuthorization
  /// Whether `requestAuthorization()` reports a grant, and switches ``authorizationStatus`` on.
  var grantsAuthorization = false
  /// Whether macOS accepts a post. `false` is "the user was not told", which covers both a denial and
  /// a failed post — the two the app deliberately treats alike.
  var acceptsPosts = true
  /// The alerts macOS was asked to deliver, oldest first.
  private(set) var posts: [(amount: String, threshold: String)] = []
  private(set) var authorizationRequests = 0

  init(authorizationStatus: AlertAuthorization = .authorized) {
    self.authorizationStatus = authorizationStatus
  }

  func requestAuthorization() async -> Bool {
    authorizationRequests += 1
    if grantsAuthorization { authorizationStatus = .authorized }
    return grantsAuthorization
  }

  func authorization() async -> AlertAuthorization { authorizationStatus }

  func postLowBalance(amountText: String, threshold: String) async -> Bool {
    posts.append((amountText, threshold))
    return acceptsPosts
  }

  var postedAmounts: [String] { posts.map { $0.amount } }
  var postedThresholds: [String] { posts.map { $0.threshold } }
}

// MARK: - Login item

/// The login item as a test double. `SMAppService` acts on the calling process, so the real thing
/// would register the test runner; this one only remembers what it was asked to do.
@MainActor
final class LoginItemStub {
  var status: LoginItem.Status = .notRegistered
  /// When set, `register()` throws it: the "macOS refused" path the app turns into a banner.
  var registerFailure: (any Error)?
  private(set) var registrations = 0
  private(set) var unregistrations = 0

  var control: LoginItemControl {
    LoginItemControl(
      status: { [self] in status },
      register: { [self] in
        registrations += 1
        if let registerFailure { throw registerFailure }
        status = .enabled
      },
      unregister: { [self] in
        unregistrations += 1
        status = .notRegistered
      })
  }
}

// MARK: - Keys

/// The key situation a test wants, without touching the developer's Keychain.
enum KeySetup {
  /// `DEEPSEEK_API_KEY` is set and the Keychain holds nothing.
  case environment(String)
  /// The Keychain read fails — a locked keychain, a denied ACL — while the environment may still hold
  /// a usable key.
  case keychainProblem(OSStatus, environment: String?)
  /// Neither source has a key.
  case none
  /// Whatever the given store holds. This is the only setup that round-trips through the Keychain, so
  /// it is the one the import and forget paths use, and the store must be test-only — see
  /// ``testKeychainService``.
  case store(KeychainStore)
}

/// An `APIKeySource` for one ``KeySetup``, with the login shell under test control too.
func testKeySource(
  _ setup: KeySetup,
  shellRunner: APIKeySource.ShellRunner? = nil
) -> APIKeySource {
  let store = KeychainStore(service: testKeychainService, account: "api-key")
  switch setup {
  case .environment(let key):
    return APIKeySource(
      keychain: store, environment: ["DEEPSEEK_API_KEY": key], shellRunner: shellRunner,
      keychainReader: { nil })
  case .keychainProblem(let status, let environment):
    return APIKeySource(
      keychain: store,
      environment: environment.map { ["DEEPSEEK_API_KEY": $0] } ?? [:],
      shellRunner: shellRunner,
      keychainReader: { throw KeychainError.unexpectedStatus(status) })
  case .none:
    return APIKeySource(
      keychain: store, environment: [:], shellRunner: shellRunner, keychainReader: { nil })
  case .store(let itemStore):
    return APIKeySource(
      keychain: itemStore, environment: [:], shellRunner: shellRunner,
      keychainReader: { try itemStore.read() })
  }
}

// MARK: - The model under test

/// One `AppModel` with every seam stubbed, plus the stubs themselves.
@MainActor
struct AppModelFixture {
  let model: AppModel
  let fetcher: StubBalanceFetcher
  let scheduling: TestScheduler
  let alerts: StubAlertScheduler
  let clock: TestClock
  let loginItem: LoginItemStub
  let power: StubPowerState
}

/// Builds the model a test drives.
///
/// `settings` is written to the store before the model exists, so the model loads it exactly as it
/// would at launch. `key` is the whole key situation, so no test reads the developer's Keychain or the
/// environment of the process that happens to run the suite — a shell with `DEEPSEEK_API_KEY` exported
/// must not decide what the app layer resolves.
///
/// `uninstaller` overrides the removal path: without it the model would build the shipping one, which
/// acts on this Mac's real home, Trash, Keychain and login item.
@MainActor
func makeFixture(
  defaults: UserDefaults,
  outcome: StubBalanceFetcher.Outcome = .balance(usdBalance("12.34")),
  key: APIKeySource = testKeySource(.environment(testEnvironmentKey)),
  settings: AppSettings = .default,
  power: StubPowerState = StubPowerState(),
  uninstaller: Uninstaller? = nil
) -> AppModelFixture {
  SettingsStore(defaults: defaults).save(settings)
  let fetcher = StubBalanceFetcher(outcome: outcome)
  let environment = AppEnvironment(
    defaults: defaults,
    keychain: KeychainStore(service: testKeychainService, account: "api-key"),
    keySource: key,
    // A home directory that cannot exist, so the price table is always the bundled one: a developer's
    // `~/.config/deeptally/PriceTable.json` must not decide what a test sees.
    priceLoader: PriceTableLoader(
      homeDirectory: URL(fileURLWithPath: "/nonexistent-deeptally-tests")),
    // Every request lands on the stub, so no test can reach the network.
    makeFetcher: { key in fetcher.binding(for: key) },
    timeZone: TimeZone(identifier: "UTC")!
  )
  let scheduling = TestScheduler()
  let alerts = StubAlertScheduler()
  let clock = TestClock()
  let loginItem = LoginItemStub()
  let model = AppModel(
    environment: environment,
    scheduler: alerts,
    scheduling: scheduling,
    loginItem: loginItem.control,
    power: power,
    now: { clock.now },
    // Jitter is real runtime behaviour, not the model's arithmetic: pinned to zero so a recorded
    // delay is exactly `PollingPlan`'s backoff.
    jitterFraction: { 0 },
    uninstaller: uninstaller
  )
  return AppModelFixture(
    model: model, fetcher: fetcher, scheduling: scheduling, alerts: alerts, clock: clock,
    loginItem: loginItem, power: power)
}

// MARK: - Waiting

/// Waits, bounded, for an effect the model reaches through its own `Task`s — a refresh finishing, an
/// alert being posted. The 1 ms sleep exists to hand those tasks the main actor; nothing here ever
/// waits out a delay the model scheduled.
@MainActor
func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async {
  let deadline = Date().addingTimeInterval(5)
  while Date() < deadline {
    if condition() { return }
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(1))
  }
  Issue.record("timed out waiting for \(description)")
}

/// Waits for the refresh the model started to finish.
@MainActor
func settleRefresh(_ model: AppModel) async {
  await waitUntil("the refresh to finish") { !model.isRefreshing }
}

/// Gives the `Task`s the model spawned the main actor, so an assertion about something *not*
/// happening is made after those tasks would have run. No clock advance, no sleep: a `Task.yield()`
/// loop is enough for effects that are already runnable.
@MainActor
func drainPendingEffects() async {
  for _ in 0..<10 { await Task.yield() }
}

// MARK: - Defaults

/// Runs `body` against one stable `UserDefaults` domain, emptied before and after.
///
/// Stable and not a UUID per test: macOS's preferences daemon keeps a 42-byte empty plist for every
/// domain a process has seen and writes it back if the file is deleted (AGENTS.md §9.12), so a fixed
/// set of names keeps that residue bounded. Each suite owns its own name and is `.serialized`, which
/// is what makes one shared domain per suite safe.
@MainActor
func withIsolatedDefaults<T>(
  _ domain: String,
  _ body: (UserDefaults) async throws -> T
) async throws -> T {
  // `UserDefaults(suiteName:)` only returns nil for an empty name. Falling back to `.standard` would
  // touch the developer's real preferences, which is the one thing this helper exists to prevent.
  let defaults = UserDefaults(suiteName: domain)!
  defaults.removePersistentDomain(forName: domain)
  defer { defaults.removePersistentDomain(forName: domain) }
  return try await body(defaults)
}
