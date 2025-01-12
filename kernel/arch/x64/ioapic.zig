// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub fn routeInterrupt(interrupt: u8, vector: x64.interrupts.Interrupt) !void {
    const mapping = getMapping(interrupt);
    const ioapic = try getIOAPIC(mapping.gsi);

    ioapic.setRedirectionTableEntry(
        @intCast(mapping.gsi - ioapic.gsi_base),
        vector.toInterruptVector(),
        .fixed,
        .{ .physical = 0 }, // TODO: support routing to other/multiple processors
        mapping.polarity,
        mapping.trigger_mode,
        false,
    ) catch |err|
        core.panicFmt(
        "failed to route interrupt {}: {}",
        .{ interrupt, err },
        @errorReturnTrace(),
    );
}

fn getMapping(interrupt: u8) SourceOverride {
    return globals.source_overrides[interrupt] orelse .{
        .gsi = interrupt,
        .polarity = .active_high,
        .trigger_mode = .edge,
    };
}

fn getIOAPIC(gsi: u32) !IOAPIC {
    for (globals.io_apics.constSlice()) |io_apic| {
        if (gsi >= io_apic.gsi_base and gsi < (io_apic.gsi_base + io_apic.number_of_redirection_entries)) {
            return io_apic;
        }
    }
    return error.NoIOAPICForGSI;
}

const globals = struct {
    var io_apics: std.BoundedArray(IOAPIC, x64.config.maximum_number_of_io_apics) = .{};
    var source_overrides: [lib_x64.PageTable.number_of_entries]?SourceOverride = @splat(null);
};

const SourceOverride = struct {
    gsi: u32,
    polarity: IOAPIC.Polarity,
    trigger_mode: IOAPIC.TriggerMode,

    fn fromMADT(source_override: acpi.MADT.InterruptControllerEntry.InterruptSourceOverride) SourceOverride {
        const polarity: IOAPIC.Polarity = switch (source_override.flags.polarity) {
            .conforms => .active_high,
            .active_high => .active_high,
            .active_low => .active_low,
            else => core.panicFmt(
                "unsupported polarity: {}",
                .{source_override.flags.polarity},
                null,
            ),
        };

        const trigger_mode: IOAPIC.TriggerMode = switch (source_override.flags.trigger_mode) {
            .conforms => .edge,
            .edge_triggered => .edge,
            .level_triggered => .level,
            else => core.panicFmt(
                "unsupported trigger mode: {}",
                .{source_override.flags.trigger_mode},
                null,
            ),
        };

        return .{
            .gsi = source_override.global_system_interrupt,
            .polarity = polarity,
            .trigger_mode = trigger_mode,
        };
    }

    pub fn print(id: SourceOverride, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        try writer.writeAll("SourceOverride{ .gsi = ");
        try std.fmt.formatInt(id.gsi, 10, .lower, .{}, writer);
        try writer.writeAll(", .polarity = ");
        try writer.writeAll(@tagName(id.polarity));
        try writer.writeAll(", .trigger_mode = ");
        try writer.writeAll(@tagName(id.trigger_mode));
        try writer.writeAll(" }");
    }

    pub inline fn format(
        id: SourceOverride,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            SourceOverride.print(id, writer, 0)
        else
            SourceOverride.print(id, writer.any(), 0);
    }
};

pub const init = struct {
    pub fn captureMADTInformation(madt: *const acpi.MADT) !void {
        var iter = madt.iterate();

        while (iter.next()) |entry| {
            switch (entry.entry_type) {
                .io_apic => {
                    const io_apic_data = entry.specific.io_apic;

                    const address = kernel.vmm.nonCachedDirectMapFromPhysical(.fromInt(io_apic_data.ioapic_address));
                    const ioapic = IOAPIC.init(address, io_apic_data.global_system_interrupt_base);

                    if (ioapic.apicId() != io_apic_data.ioapic_id) return error.APICIdMismatch;

                    init_log.debug("found ioapic for gsi {}-{}", .{
                        ioapic.gsi_base,
                        ioapic.gsi_base + ioapic.number_of_redirection_entries,
                    });

                    try globals.io_apics.append(ioapic);
                },
                .interrupt_source_override => {
                    const madt_iso = entry.specific.interrupt_source_override;
                    const source_override: SourceOverride = .fromMADT(madt_iso);
                    globals.source_overrides[madt_iso.source] = source_override;
                    init_log.debug("found irq {} has {}", .{ madt_iso.source, source_override });
                },
                else => continue,
            }
        }

        // sort the io apics by gsi base
        std.mem.sort(
            IOAPIC,
            globals.io_apics.slice(),
            {},
            struct {
                fn lessThan(_: void, lhs: IOAPIC, rhs: IOAPIC) bool {
                    return lhs.gsi_base < rhs.gsi_base;
                }
            }.lessThan,
        );
    }

    const init_log = kernel.debug.log.scoped(.init_ioapic);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
const acpi = @import("acpi");
const IOAPIC = lib_x64.IOAPIC;