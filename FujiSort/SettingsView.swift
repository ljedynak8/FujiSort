//
//  SettingsView.swift
//  FujiSort — Milestone 07 (finish)
//
//  The minimal settings surface — three toggles, nothing more. It exists only because
//  album sync must be revocable (CLAUDE.md). This is not a preferences pane; do not grow
//  it into one.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    let coordinator: FinishCoordinator

    var body: some View {
        @Bindable var prefs = preferences
        NavigationStack {
            List {
                Section {
                    Toggle("Sync picks to Photos albums", isOn: Binding(
                        get: { prefs.albumSyncEnabled },
                        set: { on in
                            // Flipping the toggle is itself a decision, so the first-finish
                            // prompt never fires afterward.
                            prefs.albumSyncEnabled = on
                            prefs.albumSyncDecided = true
                            if on { coordinator.syncNow() }
                        }))
                } footer: {
                    Text("Keeps a FujiSort · Portfolio and FujiSort · Strong album in Photos. One-way — your judgments are the source, and the albums are rewritten to match.")
                }

                Section {
                    Toggle("Also mark Portfolio as Favorite", isOn: $prefs.writeFavorites)
                } footer: {
                    Text("Sets the Favorite heart on Portfolio photos during sync. It never removes a heart you set.")
                }

                Section {
                    Toggle("Include screenshots in the deck", isOn: $prefs.includeScreenshots)
                } footer: {
                    Text("Screenshots are left out by default. This takes effect the next time the deck is built.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)      // achromatic, matching the rest of the app
    }
}
