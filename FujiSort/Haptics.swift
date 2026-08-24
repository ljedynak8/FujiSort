//
//  Haptics.swift
//  FujiSort — Milestone 04 (pass-1 deck)
//
//  Haptics are the PRIMARY confirmation channel in sort mode, not decoration: the
//  user's attention is on the photograph, not on a control, so the hand is how a
//  verdict is confirmed. Each verdict has a distinct signature (design skill), and
//  the mid-drag threshold tick is load-bearing — it lets someone commit or cancel
//  a swipe without watching the card.
//

import UIKit

@MainActor
final class Haptics {
    static let shared = Haptics()

    private let rigid  = UIImpactFeedbackGenerator(style: .rigid)
    private let light  = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let soft   = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    private init() {}

    /// Called on drag-start so the engine is warm when the verdict lands.
    func prepareForDrag() {
        rigid.prepare(); light.prepare(); medium.prepare(); soft.prepare()
        selection.prepare()
    }

    /// The four verdict signatures. Reject is sharpest and most final; Keep — the
    /// common case — is deliberately unobtrusive; Candidate is richer, marking the
    /// promotion; Skip is the least assertive.
    func verdict(_ verdict: Verdict) {
        switch verdict {
        case .reject:    rigid.impactOccurred()
        case .keep:      light.impactOccurred()
        case .candidate: medium.impactOccurred()
        case .skip:      soft.impactOccurred()
        }
    }

    /// Crossing the commit threshold mid-drag — tells the hand the swipe will take
    /// before release.
    func thresholdCrossed() { selection.selectionChanged() }

    /// Sticky zoom reaching the 1:1 detent (design skill: `.selection`). Same tick as
    /// the threshold cross — a light "you've landed on something" signal.
    func reachedOneToOne() { selection.selectionChanged() }

    func undo() { notification.notificationOccurred(.warning) }
}
