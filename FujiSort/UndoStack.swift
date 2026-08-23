//
//  UndoStack.swift
//  FujiSort — Milestone 02 (undo)
//
//  Our own stack, built ABOVE the store rather than using ModelContext.undoManager.
//  Why: Core Data / SwiftData undo groups changes by run-loop event
//  (`groupsByEvent`), so one `undo()` can revert several mutations at once — that
//  breaks the "undo exactly one action" requirement and is nondeterministic to
//  test. Here each user action pushes exactly one inverse op.
//

import Foundation

@MainActor
final class UndoStack {
    struct Op {
        let revert: () -> Void
        let label: String
    }

    private(set) var ops: [Op] = []

    var canUndo: Bool { !ops.isEmpty }
    var depth: Int { ops.count }

    func push(_ revert: @escaping () -> Void, label: String) {
        ops.append(Op(revert: revert, label: label))
    }

    /// Revert exactly one action. Returns false if the stack is empty. No redo.
    @discardableResult
    func undo() -> Bool {
        guard let op = ops.popLast() else { return false }
        op.revert()
        return true
    }
}
