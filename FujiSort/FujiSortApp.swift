//
//  FujiSortApp.swift
//  FujiSort
//

import SwiftUI
import SwiftData

@main
struct FujiSortApp: App {
    let sharedModelContainer: ModelContainer

    // App-wide preferences and the finish/sync coordinator, injected once so the deck,
    // review, settings and finish surfaces all share one instance (milestone 07).
    @State private var preferences: AppPreferences
    @State private var coordinator: FinishCoordinator
    // First-run gate and coach-mark bookkeeping, injected once so RootView, the deck and
    // the review all read the same state (milestone 08).
    @State private var firstRun: FirstRunState

    init() {
        let schema = Schema([
            Judgment.self,
            CompareRecord.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        self.sharedModelContainer = container

        let prefs = AppPreferences()
        _preferences = State(initialValue: prefs)
        _coordinator = State(initialValue: FinishCoordinator(preferences: prefs, context: container.mainContext))
        _firstRun = State(initialValue: FirstRunState())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(preferences)
                .environment(coordinator)
                .environment(firstRun)
        }
        .modelContainer(sharedModelContainer)
    }
}
