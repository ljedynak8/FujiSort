//
//  FujiSortApp.swift
//  FujiSort
//

import SwiftUI
import SwiftData

@main
struct FujiSortApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Judgment.self,
            CompareRecord.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
