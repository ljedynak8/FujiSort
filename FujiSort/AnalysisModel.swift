//
//  AnalysisModel.swift
//  FujiSort — Milestone 05 (analysis / comparison)
//
//  The controller for the per-photo detour and its filmstrip variant. It holds the
//  hand-assembled item set, the current index, and — crucially — the zoom state that
//  is CARRIED ACROSS SWITCHES (never reset on an index change): sit at 100% on an eye
//  and toggle through the set. All queue/verdict effects go out through injected
//  closures, so the model never reaches into the deck and stays unit-testable.
//
//  Two kinds:
//    • .single  — entered by tapping a deck card. A verdict commits + advances the
//                 DECK and returns to sort; a pin annotates and stays; cancel records
//                 nothing.
//    • .compare — entered from the pinned set. A verdict commits the current frame and
//                 advances along the STRIP; the set is bounded and never walks the deck.
//

import Foundation
import Observation

@MainActor
@Observable
final class AnalysisModel: Identifiable {
    enum Kind: Equatable { case single, compare }

    /// Distinct per presentation, so `fullScreenCover(item:)` can drive it.
    nonisolated let id = UUID()
    let kind: Kind
    private(set) var items: [DeckItem]
    private(set) var index: Int

    /// Carried across switches. The single most useful thing the design does.
    var zoom: ZoomState = .fit
    var hudOn = false
    var clippingOn = false

    let pipeline: ImagePipeline?

    /// Effects. `onVerdict` records (and, for .single, advances the deck); `onPin`
    /// annotates Candidate without advancing; `onExit` dismisses the cover.
    private let onVerdict: (Verdict, DeckItem) -> Void
    private let onPin: (DeckItem) -> Void
    private let onExit: () -> Void

    init(kind: Kind, items: [DeckItem], index: Int = 0, pipeline: ImagePipeline?,
         onVerdict: @escaping (Verdict, DeckItem) -> Void,
         onPin: @escaping (DeckItem) -> Void,
         onExit: @escaping () -> Void) {
        self.kind = kind
        self.items = items
        self.index = FilmstripNavigation.select(index, count: items.count)
        self.pipeline = pipeline
        self.onVerdict = onVerdict
        self.onPin = onPin
        self.onExit = onExit
    }

    var isCompare: Bool { kind == .compare }
    var current: DeckItem? { items.indices.contains(index) ? items[index] : nil }
    var count: Int { items.count }

    // MARK: - Filmstrip movement (zoom is preserved through all of these)

    func select(_ target: Int) {
        let ni = FilmstripNavigation.select(target, count: items.count)
        guard ni != index else { return }
        index = ni
    }

    func stripNext() { select(FilmstripNavigation.next(index: index, count: items.count)) }
    func stripPrevious() { select(FilmstripNavigation.previous(index: index, count: items.count)) }

    // MARK: - Exits

    /// A verdict. Single: commit + advance the deck, then leave. Compare: commit this
    /// frame and step along the strip (the last frame stays put).
    func commit(_ verdict: Verdict) {
        guard let item = current else { return }
        onVerdict(verdict, item)
        switch kind {
        case .single:
            onExit()
        case .compare:
            index = FilmstripNavigation.next(index: index, count: items.count)
        }
    }

    /// An annotation: marks Candidate and pins for compare, and STAYS in analysis —
    /// true for both kinds (interaction skill: an annotation applies, a verdict exits).
    func pin() {
        guard let item = current else { return }
        onPin(item)
    }

    /// Cancel — nothing this call records. Returns to sort on the same photo.
    func cancel() { onExit() }
}
