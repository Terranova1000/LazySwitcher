import Foundation

/// A 64-bit counter written by exactly one thread and read by others.
///
/// Why not a lock: the event-tap callback must never touch a lock that the main
/// thread can hold (CLAUDE.md rule 7). Why this is sound: the storage is a single
/// naturally-aligned 64-bit word, and on arm64/x86_64 aligned 64-bit loads and
/// stores are atomic at the hardware level, so a reader never observes a torn
/// value. We deliberately make no ordering claims beyond that — these are
/// diagnostic counters and flags, never synchronisation primitives.
///
/// `Synchronization.Atomic` would be the proper tool, but it is macOS 15+ and we
/// ship for 14.0.
final class AtomicCounter: @unchecked Sendable {
    private let cell: UnsafeMutablePointer<UInt64>

    init(_ initial: UInt64 = 0) {
        cell = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        cell.initialize(to: initial)
    }

    deinit {
        cell.deinitialize(count: 1)
        cell.deallocate()
    }

    /// Single-writer increment. Safe only because one thread owns the write side.
    func bump() { cell.pointee &+= 1 }

    var value: UInt64 {
        get { cell.pointee }
        set { cell.pointee = newValue }
    }
}
