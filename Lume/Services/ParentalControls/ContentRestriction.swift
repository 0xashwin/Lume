//
//  ContentRestriction.swift
//  Lume
//
//  Describes which content is hidden from the current viewer. Two independent
//  sources feed it: categories the user hid in Settings › Content Management
//  (always applied), and categories marked restricted by parental controls
//  (applied only while a child profile is active, so `isActive` is false for a
//  parent). `MainTabView` builds it from both and injects it into the
//  environment; every content surface (browse grids, the cross-category rows,
//  Home, Search and the "For You" engine) reads it so a hidden or restricted
//  category — and any title in it — disappears everywhere alike.
//

import CryptoKit
import SwiftUI

nonisolated struct ContentRestriction: Equatable {
    /// True when the active profile is a child: `restrictedCategoryIDs` applies
    /// only to kids.
    var isActive = false
    /// Ids of the categories marked restricted.
    var restrictedCategoryIDs: Set<String> = []
    /// Ids of the categories the user hid in Content Management. Unlike
    /// restricted ones these apply to every profile.
    var hiddenCategoryIDs: Set<String> = []

    /// Every category id excluded for the current viewer.
    var excludedCategoryIDs: Set<String> {
        isActive ? hiddenCategoryIDs.union(restrictedCategoryIDs) : hiddenCategoryIDs
    }

    /// A stable digest of `excludedCategoryIDs`, for cache keys that must not
    /// outlive a visibility change (Home's trending memo, the "For You" list).
    /// Hashed rather than joined verbatim: a user who hides most of a large
    /// catalog would otherwise put tens of kilobytes in a key. `hashValue` is
    /// seeded per process and would differ every launch, so it can't be used.
    var visibilityToken: String {
        Self.visibilityToken(for: excludedCategoryIDs)
    }

    static func visibilityToken(for excludedCategoryIDs: Set<String>) -> String {
        let joined = excludedCategoryIDs.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether content in `categoryID` should be hidden from the current viewer.
    func hides(categoryID: String?) -> Bool {
        guard let categoryID else { return false }
        if hiddenCategoryIDs.contains(categoryID) { return true }
        return isActive && restrictedCategoryIDs.contains(categoryID)
    }
}

extension EnvironmentValues {
    @Entry var contentRestriction = ContentRestriction()
}

/// Content that belongs to a `Category`, so it can be filtered when that category
/// is hidden or restricted. Movies, series and live channels all carry a
/// `categoryId`.
protocol CategorizedContent {
    var categoryId: String? { get }
}

extension Movie: CategorizedContent {}
extension Series: CategorizedContent {}
extension LiveStream: CategorizedContent {}

extension Sequence where Element: CategorizedContent {
    /// Drops items whose category is hidden or restricted for the current
    /// viewer. A no-op when nothing is excluded.
    func excludingRestricted(_ restriction: ContentRestriction) -> [Element] {
        let excluded = restriction.excludedCategoryIDs
        guard !excluded.isEmpty else { return Array(self) }
        return filter { !excluded.contains($0.categoryId ?? "") }
    }
}
