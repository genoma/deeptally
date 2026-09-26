// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import DeepTallyCore

/// `SettingsStore`'s default key, spelled out so that moving the stored location fails a test
/// instead of silently resetting every user's settings.
private let settingsKey = "io.github.genoma.deeptally.settings"

@Suite("App settings", .serialized)
struct SettingsTests {
  /// Runs `body` against one stable `UserDefaults` suite that only these tests use, so the developer's
  /// real preferences are never touched. The suite is `.serialized`, which is what makes a single
  /// shared domain safe.
  ///
  /// `removePersistentDomain` empties the domain, but macOS's preferences daemon keeps a 42-byte empty
  /// `~/Library/Preferences/<suite>.plist` for any domain it has seen, and deleting that file by hand
  /// does not help — the daemon writes it back within seconds. A stable name keeps that residue at
  /// exactly one file instead of one file per test run, which is why this is not randomised.
  private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "io.github.genoma.deeptally.tests.settings"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("could not create the UserDefaults suite \(suiteName)")
      return
    }
    defaults.removePersistentDomain(forName: suiteName)  // start clean even after a crashed run
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
  }

  @Test("the documented defaults")
  func documentedDefaults() {
    let settings = AppSettings.default
    #expect(settings.refreshIntervalMinutes == 30)
    #expect(settings.lowBalanceThreshold == 2)
    #expect(settings.notificationsEnabled)
    #expect(settings.notificationCooldownMinutes == 720)
  }

  @Test("a fresh store loads AppSettings.default")
  func freshStoreLoadsDefault() {
    withIsolatedDefaults { defaults in
      #expect(SettingsStore(defaults: defaults).load() == AppSettings.default)
    }
  }

  @Test("validated() clamps the refresh interval to 5...240")
  func clampsRefreshInterval() {
    #expect(AppSettings(refreshIntervalMinutes: 4).validated().refreshIntervalMinutes == 5)
    #expect(AppSettings(refreshIntervalMinutes: 241).validated().refreshIntervalMinutes == 240)
    #expect(AppSettings(refreshIntervalMinutes: 5).validated().refreshIntervalMinutes == 5)
    #expect(AppSettings(refreshIntervalMinutes: 240).validated().refreshIntervalMinutes == 240)
  }

  @Test("validated() clamps the low-balance threshold to 0...1000")
  func clampsLowBalanceThreshold() {
    #expect(AppSettings(lowBalanceThreshold: -1).validated().lowBalanceThreshold == 0)
    #expect(AppSettings(lowBalanceThreshold: 1001).validated().lowBalanceThreshold == 1000)
    // A value already inside the range is kept exactly, not rounded.
    let small = AppSettings(lowBalanceThreshold: Decimal.parse("0.25")).validated()
    #expect(small.lowBalanceThreshold == Decimal.parse("0.25"))
  }

  @Test("validated() clamps the notification cooldown to 15...10080")
  func clampsNotificationCooldown() {
    let short = AppSettings(notificationCooldownMinutes: 5).validated()
    #expect(short.notificationCooldownMinutes == 15)
    let long = AppSettings(notificationCooldownMinutes: 999_999).validated()
    #expect(long.notificationCooldownMinutes == 10_080)
  }

  @Test("save then load round-trips the validated settings")
  func saveThenLoadRoundTrips() {
    withIsolatedDefaults { defaults in
      let store = SettingsStore(defaults: defaults)
      let settings = AppSettings(
        refreshIntervalMinutes: 90,
        lowBalanceThreshold: Decimal.parse("12.75"),
        notificationsEnabled: false,
        notificationCooldownMinutes: 1_440
      )

      store.save(settings)

      #expect(store.load() == settings.validated())
      #expect(store.load() == settings)
    }
  }

  @Test("save() writes validated settings, so an out-of-range value never reaches the domain")
  func saveWritesValidatedSettings() {
    withIsolatedDefaults { defaults in
      let store = SettingsStore(defaults: defaults)
      store.save(
        AppSettings(
          refreshIntervalMinutes: 4, lowBalanceThreshold: -1, notificationCooldownMinutes: 5))

      let loaded = store.load()

      #expect(loaded.refreshIntervalMinutes == 5)
      #expect(loaded.lowBalanceThreshold == 0)
      #expect(loaded.notificationCooldownMinutes == 15)
    }
  }

  @Test("a partial blob keeps the default for every key it omits")
  func partialBlobKeepsDefaults() {
    withIsolatedDefaults { defaults in
      defaults.set(Data(#"{"refreshIntervalMinutes": 60}"#.utf8), forKey: settingsKey)

      let loaded = SettingsStore(defaults: defaults).load()

      #expect(loaded.refreshIntervalMinutes == 60)
      #expect(loaded == AppSettings(refreshIntervalMinutes: 60))
    }
  }

  @Test("a stored blob that still carries the removed usage keys decodes")
  func removedUsageKeysAreIgnored() {
    withIsolatedDefaults { defaults in
      // Written by a build that still had the menu bar metric and the usage proxy: the keys are
      // unknown now, so they are ignored and every remaining field still loads.
      defaults.set(
        Data(
          #"{"menuBarMetric": "tokyoDrift", "showSecondaryMetric": true, "proxyEnabled": true, "proxyPort": 9090, "refreshIntervalMinutes": 60, "notificationsEnabled": false}"#
            .utf8),
        forKey: settingsKey)

      let loaded = SettingsStore(defaults: defaults).load()

      #expect(
        loaded
          == AppSettings(
            refreshIntervalMinutes: 60, notificationsEnabled: false))
    }
  }

  @Test("a field of the wrong type resets only that field")
  func wrongTypeResetsOnlyThatField() {
    withIsolatedDefaults { defaults in
      defaults.set(
        Data(#"{"refreshIntervalMinutes": "soon", "notificationsEnabled": false}"#.utf8),
        forKey: settingsKey)

      let loaded = SettingsStore(defaults: defaults).load()

      #expect(loaded.refreshIntervalMinutes == 30)
      #expect(!loaded.notificationsEnabled)
    }
  }

  /// The Currency setting was removed: the account currency is shown as-is (PLAN.md decision 13) and
  /// nothing read the chosen code. A blob written before the removal still carries the key, and an
  /// unknown key must decode rather than throw the whole blob away.
  @Test("a stored blob that still carries the removed currency key decodes")
  func removedCurrencyKeyIsIgnored() {
    withIsolatedDefaults { defaults in
      defaults.set(Data(#"{"currencyCode": "EUR"}"#.utf8), forKey: settingsKey)
      #expect(SettingsStore(defaults: defaults).load() == AppSettings.default)
    }
    withIsolatedDefaults { defaults in
      defaults.set(
        Data(#"{"currencyCode": "EUR", "refreshIntervalMinutes": 60}"#.utf8), forKey: settingsKey)
      #expect(SettingsStore(defaults: defaults).load() == AppSettings(refreshIntervalMinutes: 60))
    }
  }

  @Test("keys this build does not know are ignored")
  func unknownKeysAreIgnored() {
    withIsolatedDefaults { defaults in
      defaults.set(
        Data(#"{"futureFlag": true, "notificationsEnabled": false}"#.utf8), forKey: settingsKey)

      let loaded = SettingsStore(defaults: defaults).load()

      #expect(!loaded.notificationsEnabled)
      #expect(loaded == AppSettings(notificationsEnabled: false))
    }
  }

  @Test("garbage or non-object blobs load AppSettings.default")
  func corruptBlobsFallBackToDefault() {
    withIsolatedDefaults { defaults in
      defaults.set(Data([0x00, 0x01, 0xFF, 0xFE]), forKey: settingsKey)
      #expect(SettingsStore(defaults: defaults).load() == AppSettings.default)
    }
    withIsolatedDefaults { defaults in
      defaults.set(Data(#"[1, 2, 3]"#.utf8), forKey: settingsKey)
      #expect(SettingsStore(defaults: defaults).load() == AppSettings.default)
    }
  }

  @Test("a hand-edited threshold decodes as a number or as a string")
  func thresholdDecodesFromEitherJSONForm() {
    withIsolatedDefaults { defaults in
      defaults.set(Data(#"{"lowBalanceThreshold": 2.5}"#.utf8), forKey: settingsKey)
      let loaded = SettingsStore(defaults: defaults).load()
      #expect(loaded.lowBalanceThreshold == Decimal.parse("2.5"))
    }
    withIsolatedDefaults { defaults in
      defaults.set(Data(#"{"lowBalanceThreshold": "7.25"}"#.utf8), forKey: settingsKey)
      let loaded = SettingsStore(defaults: defaults).load()
      #expect(loaded.lowBalanceThreshold == Decimal.parse("7.25"))
    }
  }

  @Test("the stored blob is an inspectable JSON object with money as a string")
  func storedBlobIsInspectableJSON() {
    withIsolatedDefaults { defaults in
      let store = SettingsStore(defaults: defaults)
      store.save(AppSettings(lowBalanceThreshold: Decimal.parse("12.75")))

      guard let blob = defaults.data(forKey: settingsKey),
        let object = try? JSONSerialization.jsonObject(with: blob) as? [String: Any]
      else {
        Issue.record("no JSON object stored under \(settingsKey)")
        return
      }

      #expect(object["lowBalanceThreshold"] as? String == "12.75")
      // The removed menu-bar metric and proxy keys are gone, so nothing writes them any more.
      #expect(object["menuBarMetric"] == nil)
      #expect(object["showSecondaryMetric"] == nil)
      #expect(object["proxyEnabled"] == nil)
      #expect(object["proxyPort"] == nil)
      // The Currency setting is gone, so nothing writes a currency key any more.
      #expect(object["currencyCode"] == nil)
    }
  }
}
