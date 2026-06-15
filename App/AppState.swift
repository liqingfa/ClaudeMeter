import Foundation
import SwiftUI

/// Drives the menu-bar UI: polls `DataStore` on a timer, publishes the latest
/// snapshot, and nudges the widget to reload after each refresh.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private init() {}

    @Published private(set) var snapshot: UsageSnapshot = SnapshotCache.load() ?? .empty
    @Published private(set) var isRefreshing = false

    /// How often the menu-bar number refreshes.
    private let pollInterval: TimeInterval = 60
    private var timer: Timer?

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        snapshot = await DataStore.shared.refresh()
    }

    /// Short string for the menu-bar label, e.g. "4% · 3%" (5h · 7d).
    /// Empty when there is no subscription quota to show (icon only).
    var menuBarTitle: String {
        switch snapshot.quotaState {
        case .unavailable:
            return ""                       // API key / not logged in — icon only
        case .available, .needsLogin, .rateLimited, .unknown:
            guard snapshot.fiveHour != nil || snapshot.sevenDay != nil else { return "" }
            let five = snapshot.fiveHour.flatMap { $0.utilization == 0 ? nil : Fmt.percent($0.utilization) } ?? "··"
            let seven = snapshot.sevenDay.map { Fmt.percent($0.utilization) } ?? "··"
            return "\(five) · \(seven)"
        }
    }

    /// Drives the menu-bar icon tint by the worst of the two windows.
    var worstFraction: Double {
        max(snapshot.fiveHour?.fraction ?? 0, snapshot.sevenDay?.fraction ?? 0)
    }
}
