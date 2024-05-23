// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const Mutex = @import("Mutex.zig");
pub const TicketSpinLock = @import("TicketSpinLock.zig");

/// Acquire interrupt exclusion.
pub fn getInterruptExclusion() InterruptExclusion {
    kernel.arch.interrupts.disableInterrupts();

    const cpu = kernel.arch.rawGetCpu();

    cpu.interrupt_disable_count += 1;

    return .{ .cpu = cpu };
}

/// Acquire interrupt exclusion and the previous value of the disable count.
pub fn getInterruptExclusionAndPreviousValue() struct { InterruptExclusion, u32 } {
    kernel.arch.interrupts.disableInterrupts();

    const cpu = kernel.arch.rawGetCpu();

    const old_interrupt_disable_count = cpu.interrupt_disable_count;
    cpu.interrupt_disable_count = old_interrupt_disable_count + 1;

    return .{ .{ .cpu = cpu }, old_interrupt_disable_count };
}

/// Asserts that interrupts are excluded with a disable count of one.
pub fn assertInterruptExclusion() InterruptExclusion {
    core.debugAssert(!kernel.arch.interrupts.interruptsEnabled());

    const cpu = kernel.arch.rawGetCpu();

    core.debugAssert(cpu.interrupt_disable_count == 1);

    return .{ .cpu = cpu };
}

pub const InterruptExclusion = struct {
    cpu: *kernel.Cpu,

    pub fn release(self: InterruptExclusion) void {
        core.debugAssert(!kernel.arch.interrupts.interruptsEnabled());

        const old_interrupt_disable_count = self.cpu.interrupt_disable_count;
        core.debugAssert(old_interrupt_disable_count != 0);

        self.cpu.interrupt_disable_count -= 1;

        if (old_interrupt_disable_count == 1) kernel.arch.interrupts.enableInterrupts();
    }
};
