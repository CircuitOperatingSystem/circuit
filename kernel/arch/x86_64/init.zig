// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

const log = kernel.log.scoped(.init);

pub const EarlyOutputWriter = x86_64.serial.SerialPort.Writer;
var early_output_serial_port: ?x86_64.serial.SerialPort = null;

pub fn setupEarlyOutput() void {
    early_output_serial_port = x86_64.serial.SerialPort.init(.COM1, .Baud115200);
}

pub fn getEarlyOutputWriter() ?x86_64.serial.SerialPort.Writer {
    return if (early_output_serial_port) |output| output.writer() else null;
}

const page_size = core.Size.from(4, .kib);
const kernel_stack_size = page_size.multiply(16);

var bootstrap_interrupt_stack align(16) = [_]u8{0} ** kernel_stack_size.bytes;
var bootstrap_double_fault_stack align(16) = [_]u8{0} ** kernel_stack_size.bytes; // TODO: This could be smaller
var bootstrap_non_maskable_interrupt_stack align(16) = [_]u8{0} ** kernel_stack_size.bytes; // TODO: This could be smaller

pub fn prepareBootstrapProcessor(bootstrap_processor: *kernel.Processor) void {
    bootstrap_processor._arch = .{
        .interrupt_stack = &bootstrap_interrupt_stack,
        .double_fault_stack = &bootstrap_double_fault_stack,
        .non_maskable_interrupt_stack = &bootstrap_non_maskable_interrupt_stack,
    };

    bootstrap_processor._arch.tss.setPrivilegeStack(.ring0, bootstrap_processor._arch.interrupt_stack);
}

pub fn prepareProcessor(processor: *kernel.Processor) void {
    _ = processor;

    core.panic("NOT IMPLEMENTED"); // TODO
}

pub fn loadProcessor(processor: *kernel.Processor) void {
    const arch: *x86_64.ArchProcessor = processor.arch();

    arch.gdt.load();

    arch.tss.setInterruptStack(.double_fault, arch.double_fault_stack);
    arch.tss.setInterruptStack(.non_maskable_interrupt, arch.non_maskable_interrupt_stack);

    arch.gdt.setTss(&arch.tss);

    x86_64.interrupts.loadIdt();

    x86_64.registers.KERNEL_GS_BASE.write(@intFromPtr(processor));
}

pub fn earlyArchInitialization() void {
    log.debug("initializing idt", .{});
    x86_64.interrupts.initIdt();
}

/// Captures x86_64 system information.
pub fn captureSystemInformation() void {
    log.debug("capturing cpuid information", .{});
    x86_64.cpuid.capture();
}

/// Configures x86_64 system features.
pub fn configureSystemFeatures() void {
    // CR0
    {
        var cr0 = x86_64.registers.Cr0.read();

        if (!cr0.paging) core.panic("paging not enabled");

        cr0.write_protect = true;

        cr0.write();
        log.debug("CR0 set", .{});
    }

    // EFER
    {
        var efer = x86_64.registers.EFER.read();

        if (!efer.long_mode_active or !efer.long_mode_enable) core.panic("not in long mode");

        if (x86_64.info.has_syscall) efer.syscall_enable = true;
        if (x86_64.info.has_execute_disable) efer.no_execute_enable = true;

        efer.write();

        log.debug("EFER set", .{});
    }
}
