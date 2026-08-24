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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(preferences)
                .environment(coordinator)
        }
        .modelContainer(sharedModelContainer)
    }
}
