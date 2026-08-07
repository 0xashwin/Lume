//
//  ParentalControlsStore.swift
//  Lume
//
//  Keychain-backed storage for the parental-control PIN. The PIN gates leaving a
//  child profile and editing Content Management; it isn't a high-value secret,
//  but it lives in the keychain (encrypted at rest, excluded from plaintext
//  backups) rather than UserDefaults — and only a salted SHA-256 hash is stored,
//  never the PIN itself, so a keychain dump can't reveal a PIN the user might
//  reuse elsewhere.
//
//  Mirrors `TraktTokenStore`: SecItem directly with the safe update-then-add
//  pattern, `kSecUseDataProtectionKeychain` for macOS parity. `WhenUnlocked`
//  accessibility fits a PIN that's only ever read while the app is foregrounded.
//
//  The keychain is the local store of record — `verify` reads it and nothing
//  else. It is *not* the transport between devices: iCloud Keychain never syncs
//  to tvOS, which is the one platform where an unenforced parental gate matters
//  most. `CloudSyncEngine+Parental` carries the hash between devices over the
//  CloudKit private database instead, using `storedHash` / `store(hash:)` below.
//
//  `nonisolated` because that reconcile runs on the `CloudSyncEngine` actor, off
//  the main actor (the project defaults to main-actor isolation). Safe: this type
//  holds no state of its own — every call goes straight to the thread-safe
//  `SecItem` API.
//

import CryptoKit
import Foundation
import Security

nonisolated enum ParentalControlsStore {
    private static let service = "bilipp.Lume.parental"
    private static let account = "pin-hash"
    /// Mixed into the hash. Not a secret (it ships in the binary); it only stops
    /// the stored value from being a bare SHA-256 of a four-digit PIN.
    private static let salt = "lume.parental.v1"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// Whether a PIN has been set. A presence check — never returns the hash.
    static var isSet: Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Stores the salted hash of `pin`, replacing any existing one.
    static func save(pin: String) {
        store(hash: hash(pin))
    }

    /// The stored salted hash, or nil when no PIN is set.
    ///
    /// Only the sync reconciler should need this — it is what gets mirrored to
    /// the other devices. UI code wants `isSet` or `verify` instead.
    static func storedHash() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes an already-hashed PIN. The counterpart to `storedHash` — used when
    /// pulling another device's PIN down from iCloud, where the PIN itself was
    /// never transmitted and so cannot be re-hashed.
    static func store(hash: String) {
        let data = Data(hash.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Whether `pin` matches the stored PIN. False when no PIN is set.
    static func verify(pin: String) -> Bool {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = String(data: data, encoding: .utf8)
        else { return false }
        return stored == hash(pin)
    }

    /// Removes the stored PIN. A missing item is treated as success.
    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
