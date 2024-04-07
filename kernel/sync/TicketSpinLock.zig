// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const TicketSpinLock = @This();

current: u32 = 0,
ticket: u32 = 0,
current_holder: kernel.Cpu.Id = .none,

pub const Held = struct {
    preemption_interrupt_halt: kernel.sync.PreemptionInterruptHalt,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    pub fn release(self: Held) void {
        core.debugAssert(self.spinlock.isLockedBy(self.preemption_interrupt_halt.cpu.id));

        self.spinlock.unsafeRelease();
        self.preemption_interrupt_halt.release();
    }
};

pub fn isLocked(self: *const TicketSpinLock) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) != .none;
}

/// Returns true if the spinlock is locked by the current cpu.
pub fn isLockedByCurrent(self: *const TicketSpinLock) bool {
    const preemption_halt = kernel.sync.getCpuPreemptionHalt();
    defer preemption_halt.release();

    return self.isLockedBy(preemption_halt.cpu.id);
}

pub fn isLockedBy(self: *const TicketSpinLock, cpu_id: kernel.Cpu.Id) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) == cpu_id;
}

/// Releases the spinlock.
///
/// Intended to be used only when the caller needs to unlock the spinlock on behalf of another thread.
pub fn unsafeRelease(self: *TicketSpinLock) void {
    @atomicStore(kernel.Cpu.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(u32, &self.current, .Add, 1, .acq_rel);
}

pub fn acquire(self: *TicketSpinLock) Held {
    const preemption_interrupt_halt = kernel.sync.getCpuPreemptionInterruptHalt();

    core.debugAssert(!self.isLockedBy(preemption_interrupt_halt.cpu.id));

    const ticket = @atomicRmw(u32, &self.ticket, .Add, 1, .acq_rel);

    while (@atomicLoad(u32, &self.current, .acquire) != ticket) {
        kernel.arch.spinLoopHint();
    }
    @atomicStore(kernel.Cpu.Id, &self.current_holder, preemption_interrupt_halt.cpu.id, .release);

    return .{
        .preemption_interrupt_halt = preemption_interrupt_halt,
        .spinlock = self,
    };
}
