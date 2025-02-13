// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz

/// Attempt to register some form of init output.
pub fn registerInitOutput() void {
    const static = struct {
        var init_output_uart: Uart = undefined;
    };

    // TODO: we can't assume the UART is actually at this address unless we are on qemu virt.
    static.init_output_uart = Uart.init(kernel.vmm.directMapFromPhysical(core.PhysicalAddress.fromInt(0x10000000)));

    kernel.init.Output.registerOutput(.{
        .writeFn = struct {
            fn writeFn(context: *anyopaque, str: []const u8) void {
                const uart: *Uart = @ptrCast(@alignCast(context));
                uart.write(str);
            }
        }.writeFn,
        .remapFn = struct {
            fn remapFn(context: *anyopaque, _: *kernel.Task) anyerror!void {
                const uart: *Uart = @ptrCast(@alignCast(context));
                const physical_address = try kernel.vmm.physicalFromDirectMap(.fromPtr(@volatileCast(uart.ptr)));
                uart.ptr = kernel.vmm.nonCachedDirectMapFromPhysical(physical_address).toPtr(*volatile u8);
            }
        }.remapFn,
        .context = &static.init_output_uart,
    });
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
) void {
    bootstrap_executor.arch = .{};
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    lib_riscv64.registers.SupervisorScratch.write(@intFromPtr(executor));
}

/// A basic write only UART.
const Uart = struct {
    ptr: *volatile u8,

    pub fn init(address: core.VirtualAddress) Uart {
        return .{
            .ptr = address.toPtr(*volatile u8),
        };
    }

    pub fn write(self: Uart, bytes: []const u8) void {
        var previous_byte: u8 = 0;

        for (bytes) |byte| {
            defer previous_byte = byte;

            if (byte == '\n' and previous_byte != '\r') {
                @branchHint(.unlikely);
                self.ptr.* = '\r';
            }

            self.ptr.* = byte;
        }
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const riscv64 = @import("riscv64.zig");
const lib_riscv64 = @import("riscv64");
