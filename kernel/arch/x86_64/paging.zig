// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x86_64 = @import("x86_64.zig");

const log = kernel.log.scoped(.paging_x86_64);

const PageTable = x86_64.PageTable;
const MapType = kernel.vmm.MapType;
const MapError = kernel.arch.paging.MapError;

pub const higher_half = core.VirtualAddress.fromInt(0xffff800000000000);

/// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
///
/// Caller must ensure:
///  - the virtual range address and size are aligned to the standard page size
///  - the physical range address and size are aligned to the standard page size
///  - the virtual range size is equal to the physical range size
///  - the virtual range is not already mapped
///
/// This function:
///  - uses only the standard page size for the architecture
///  - does not flush the TLB
///  - on error is not required roll back any modifications to the page tables
pub fn mapToPhysicalRange(
    page_table: *PageTable,
    virtual_range: core.VirtualRange,
    physical_range: core.PhysicalRange,
    map_type: kernel.vmm.MapType,
) MapError!void {
    log.debug("mapToPhysicalRange - {} - {} - {}", .{ virtual_range, physical_range, map_type });

    var current_virtual_address = virtual_range.address;
    const end_virtual_address = virtual_range.end();
    var current_physical_address = physical_range.address;

    var kib_page_mappings: usize = 0;

    while (current_virtual_address.lessThan(end_virtual_address)) {
        mapTo4KiB(
            page_table,
            current_virtual_address,
            current_physical_address,
            map_type,
        ) catch |err| {
            // TODO: roll back any modifications to the page tables
            log.err("failed to map {} to {} 4KiB", .{ current_virtual_address, current_physical_address });
            return err;
        };

        kib_page_mappings += 1;

        current_virtual_address.moveForwardInPlace(x86_64.PageTable.small_page_size);
        current_physical_address.moveForwardInPlace(x86_64.PageTable.small_page_size);
    }

    log.debug("mapToPhysicalRange - satified using {} 4KiB pages", .{kib_page_mappings});
}
/// Maps a 4 KiB page.
fn mapTo4KiB(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
) MapError!void {
    core.debugAssert(virtual_address.isAligned(PageTable.small_page_size));
    core.debugAssert(physical_address.isAligned(PageTable.small_page_size));

    const level4_entry = level4_table.getEntryLevel4(virtual_address);

    const level3_table, const created_level3_table = try ensureNextTable(
        level4_entry,
        map_type,
    );
    errdefer {
        if (created_level3_table) {
            const address = level4_entry.getAddress4kib();
            level4_entry.zero();
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    const level3_entry = level3_table.getEntryLevel3(virtual_address);

    const level2_table, const created_level2_table = try ensureNextTable(
        level3_entry,
        map_type,
    );
    errdefer {
        if (created_level2_table) {
            const address = level3_entry.getAddress4kib();
            level3_entry.zero();
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    const level2_entry = level2_table.getEntryLevel2(virtual_address);

    const level1_table, const created_level1_table = try ensureNextTable(
        level2_entry,
        map_type,
    );
    errdefer {
        if (created_level1_table) {
            const address = level2_entry.getAddress4kib();
            level2_entry.zero();
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    const entry = level1_table.getEntryLevel1(virtual_address);
    if (entry.present.read()) return error.AlreadyMapped;

    entry.setAddress4kib(physical_address);

    applyMapType(map_type, entry);

    entry.present.write(true);
}

/// Ensures the next page table level exists.
fn ensureNextTable(
    self: *PageTable.Entry,
    map_type: MapType,
) error{ PhysicalMemoryExhausted, MappingNotValid }!struct { *PageTable, bool } {
    var opt_backing_range: ?core.PhysicalRange = null;

    const next_level_phys_address = if (self.present.read()) blk: {
        if (self.huge.read()) return error.MappingNotValid;

        break :blk self.getAddress4kib();
    } else blk: {
        // ensure there are no stray bits set
        self.zero();

        const backing_range = try kernel.pmm.allocatePage();

        opt_backing_range = backing_range;

        break :blk backing_range.address;
    };
    errdefer {
        self.zero();

        if (opt_backing_range) |backing_range| {
            kernel.pmm.deallocatePage(backing_range);
        }
    }

    applyParentMapType(map_type, self);

    const next_level = kernel.directMapFromPhysical(next_level_phys_address).toPtr(*PageTable);

    if (opt_backing_range) |backing_range| {
        next_level.zero();
        self.setAddress4kib(backing_range.address);
        self.present.write(true);
    }

    return .{ next_level, opt_backing_range != null };
}

fn applyMapType(map_type: MapType, entry: *PageTable.Entry) void {
    if (map_type.user) {
        entry.user_accessible.write(true);
    }

    if (map_type.global) {
        entry.global.write(true);
    }

    if (!map_type.executable and x86_64.info.cpu_id.execute_disable) entry.no_execute.write(true);

    if (map_type.writeable) entry.writeable.write(true);

    if (map_type.no_cache) {
        entry.no_cache.write(true);
        entry.write_through.write(true);
    }
}

fn applyParentMapType(map_type: MapType, entry: *PageTable.Entry) void {
    entry.writeable.write(true);
    if (map_type.user) entry.user_accessible.write(true);
}

pub const init = struct {
    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - the physical range address and size are aligned to the standard page size
    ///  - the virtual range size is equal to the physical range size
    ///  - the virtual range is not already mapped
    ///
    /// This function:
    ///  - uses all page sizes available to the architecture
    ///  - does not flush the TLB
    ///  - on error is not required roll back any modifications to the page tables
    pub fn mapToPhysicalRangeAllPageSizes(
        page_table: *PageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: MapType,
    ) MapError!void {
        core.debugAssert(virtual_range.address.isAligned(kernel.arch.paging.standard_page_size));
        core.debugAssert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));
        core.debugAssert(physical_range.address.isAligned(kernel.arch.paging.standard_page_size));
        core.debugAssert(physical_range.size.isAligned(kernel.arch.paging.standard_page_size));
        core.debugAssert(virtual_range.size.equal(virtual_range.size));

        var current_virtual_address = virtual_range.address;
        const end_virtual_address = virtual_range.end();
        var current_physical_address = physical_range.address;
        var size_remaining = virtual_range.size;

        var gib_page_mappings: usize = 0;
        var mib_page_mappings: usize = 0;
        var kib_page_mappings: usize = 0;

        while (current_virtual_address.lessThan(end_virtual_address)) {
            const map_1gib = x86_64.info.cpu_id.gbyte_pages and
                size_remaining.greaterThanOrEqual(PageTable.large_page_size) and
                current_virtual_address.isAligned(PageTable.large_page_size) and
                current_physical_address.isAligned(PageTable.large_page_size);

            if (map_1gib) {
                mapTo1GiB(
                    page_table,
                    current_virtual_address,
                    current_physical_address,
                    map_type,
                ) catch |err| {
                    log.err("failed to map {} to {} 1GiB", .{ current_virtual_address, current_physical_address });
                    return err;
                };

                gib_page_mappings += 1;

                current_virtual_address.moveForwardInPlace(PageTable.large_page_size);
                current_physical_address.moveForwardInPlace(PageTable.large_page_size);
                size_remaining.subtractInPlace(PageTable.large_page_size);
                continue;
            }

            const map_2mib = size_remaining.greaterThanOrEqual(PageTable.medium_page_size) and
                current_virtual_address.isAligned(PageTable.medium_page_size) and
                current_physical_address.isAligned(PageTable.medium_page_size);

            if (map_2mib) {
                mapTo2MiB(
                    page_table,
                    current_virtual_address,
                    current_physical_address,
                    map_type,
                ) catch |err| {
                    log.err("failed to map {} to {} 2MiB", .{ current_virtual_address, current_physical_address });
                    return err;
                };

                mib_page_mappings += 1;

                current_virtual_address.moveForwardInPlace(PageTable.medium_page_size);
                current_physical_address.moveForwardInPlace(PageTable.medium_page_size);
                size_remaining.subtractInPlace(PageTable.medium_page_size);
                continue;
            }

            mapTo4KiB(
                page_table,
                current_virtual_address,
                current_physical_address,
                map_type,
            ) catch |err| {
                log.err("failed to map {} to {} 4KiB", .{ current_virtual_address, current_physical_address });
                return err;
            };

            kib_page_mappings += 1;

            current_virtual_address.moveForwardInPlace(PageTable.small_page_size);
            current_physical_address.moveForwardInPlace(PageTable.small_page_size);
            size_remaining.subtractInPlace(PageTable.small_page_size);
        }

        log.debug(
            "mapToPhysicalRangeAllPageSizes - satified using {} 1GiB pages, {} 2MiB pages, {} 4KiB pages",
            .{ gib_page_mappings, mib_page_mappings, kib_page_mappings },
        );
    }

    /// This is the total size of the virtual address space that one entry in the top level of the page table covers.
    ///
    /// This is only valid for 4-level paging.
    const size_of_top_level_entry = core.Size.from(0x8000000000, .byte);

    /// This function is only called during kernel init, it is required to:
    ///   1. search the higher half of the *top level* of the given page table for a free entry
    ///   2. allocate a backing frame for it
    ///   3. map the free entry to the fresh backing frame and ensure it is zeroed
    ///   4. return the `core.VirtualRange` representing the entire virtual range that entry covers
    pub fn getTopLevelRangeAndFillFirstLevel(
        page_table: *PageTable,
    ) MapError!core.VirtualRange {
        var table_index: usize = x86_64.PageTable.p4Index(higher_half);

        while (table_index < x86_64.PageTable.number_of_entries) : (table_index += 1) {
            const entry = &page_table.entries[table_index];
            if (entry._backing != 0) continue;

            log.debug("found free top level entry for at table_index {}", .{table_index});

            _ = try ensureNextTable(entry, .{ .global = true, .writeable = true });

            return core.VirtualRange.fromAddr(
                x86_64.PageTable.indexToAddr(
                    @truncate(table_index),
                    0,
                    0,
                    0,
                ),
                size_of_top_level_entry,
            );
        }

        core.panic("unable to find unused entry in top level of page table");
    }

    /// Maps a 1 GiB page.
    ///
    /// Only kernel init maps 1 GiB pages.
    fn mapTo1GiB(
        level4_table: *PageTable,
        virtual_address: core.VirtualAddress,
        physical_address: core.PhysicalAddress,
        map_type: MapType,
    ) MapError!void {
        core.debugAssert(x86_64.info.cpu_id.gbyte_pages);
        core.debugAssert(virtual_address.isAligned(PageTable.large_page_size));
        core.debugAssert(physical_address.isAligned(PageTable.large_page_size));

        const level4_entry = level4_table.getEntryLevel4(virtual_address);

        const level3_table, const created_level3_table = try ensureNextTable(
            level4_entry,
            map_type,
        );
        errdefer {
            if (created_level3_table) {
                const address = level4_entry.getAddress4kib();
                level4_entry.zero();
                kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
            }
        }

        const entry = level3_table.getEntryLevel3(virtual_address);
        if (entry.present.read()) return error.AlreadyMapped;

        entry.setAddress1gib(physical_address);

        entry.huge.write(true);
        applyMapType(map_type, entry);

        entry.present.write(true);
    }

    /// Maps a 2 MiB page.
    ///
    /// Only kernel init maps 2 MiB pages.
    fn mapTo2MiB(
        level4_table: *PageTable,
        virtual_address: core.VirtualAddress,
        physical_address: core.PhysicalAddress,
        map_type: MapType,
    ) MapError!void {
        core.debugAssert(virtual_address.isAligned(PageTable.medium_page_size));
        core.debugAssert(physical_address.isAligned(PageTable.medium_page_size));

        const level4_entry = level4_table.getEntryLevel4(virtual_address);

        const level3_table, const created_level3_table = try ensureNextTable(
            level4_entry,
            map_type,
        );
        errdefer {
            if (created_level3_table) {
                const address = level4_entry.getAddress4kib();
                level4_entry.zero();
                kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
            }
        }

        const level3_entry = level3_table.getEntryLevel3(virtual_address);

        const level2_table, const created_level2_table = try ensureNextTable(
            level3_entry,
            map_type,
        );
        errdefer {
            if (created_level2_table) {
                const address = level3_entry.getAddress4kib();
                level3_entry.zero();
                kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
            }
        }

        const entry = level2_table.getEntryLevel2(virtual_address);
        if (entry.present.read()) return error.AlreadyMapped;

        entry.setAddress2mib(physical_address);

        entry.huge.write(true);
        applyMapType(map_type, entry);

        entry.present.write(true);
    }
};
