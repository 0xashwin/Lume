//
//  DeepLinkRouter.swift
//  Lume
//

import SwiftUI

/// Shared navigation state a deep link drives: the selected tab and the Movies/
/// Series navigation stacks. `MainTabView` owns it and injects it into the
/// environment; `MoviesView` and `SeriesView` bind their `NavigationStack` to the
/// matching path so an `onOpenURL` push lands in the right tab.
@MainActor
@Observable
final class DeepLinkRouter {
    var selectedTab: AppTab = .home
    var moviesPath = NavigationPath()
    var seriesPath = NavigationPath()
    #if os(tvOS)
        /// Whether Multi-View is covering the app. It is presented from
        /// `MainTabView` — above the tab bar — as a plain overlay rather than a
        /// `fullScreenCover`, because a tvOS cover always dismisses itself on
        /// Menu. That would make it impossible for Menu to dismiss only
        /// Multi-View's own controls overlay, which is what a viewer expects
        /// while the controls are up.
        var isMultiViewPresented = false
    #endif
}
