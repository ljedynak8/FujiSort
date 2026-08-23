//
//  ContentView.swift
//  FujiSort — Milestone 02
//
//  Minimal harness only. No deck, no gestures — those are later milestones. This
//  exists to confirm the store is alive and to show record counts.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Query private var judgments: [Judgment]

    private var judged: Int { judgments.filter { $0.verdict != nil }.count }
    private var dormant: Int { judgments.filter { $0.isDormant }.count }

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Judgment records", value: "\(judgments.count)")
                LabeledContent("With a verdict", value: "\(judged)")
                LabeledContent("Dormant", value: "\(dormant)")
            }
            .navigationTitle("Judgment Store")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Judgment.self, CompareRecord.self], inMemory: true)
}
