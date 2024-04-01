// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const TicketSpinLock = @This();

current: usize = 0,
ticket: usize = 0,
current_holder: kernel.Cpu.Id = .none,

pub const Held = struct {
    cpu_lock: kernel.sync.CpuLock,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    pub fn release(self: Held) void {
        core.debugAssert(self.spinlock.current_holder == self.cpu_lock.cpu.id);

        self.spinlock.unsafeUnlock();
        self.cpu_lock.release();
    }
};

pub fn isLocked(self: TicketSpinLock) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) != .none;
}

/// Returns true if the spinlock is locked by the current cpu.
///
/// It is the caller's responsibility to ensure that interrupts are disabled.
pub fn isLockedByCurrent(self: TicketSpinLock) bool {
    const held = kernel.getCpuAndExclude(.preemption);
    defer held.release();

    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) == held.cpu.id;
}

/// Unlocks the spinlock.
///
/// Intended to be used only when the caller needs to unlock the spinlock on behalf of another thread.
pub fn unsafeUnlock(self: *TicketSpinLock) void {
    @atomicStore(kernel.Cpu.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(usize, &self.current, .Add, 1, .acq_rel);
}

pub fn lock(self: *TicketSpinLock) Held {
    const cpu_lock = kernel.getLockedCpu(.preemption_and_interrupt);

    const ticket = @atomicRmw(usize, &self.ticket, .Add, 1, .acq_rel);

    while (@atomicLoad(usize, &self.current, .acquire) != ticket) {
        kernel.arch.spinLoopHint();
    }
    @atomicStore(kernel.Cpu.Id, &self.current_holder, cpu_lock.cpu.id, .release);

    return .{
        .cpu_lock = cpu_lock,
        .spinlock = self,
    };
}
