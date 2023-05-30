// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch = kernel_options.arch;
pub const version = kernel_options.version;

// This must be kept in sync with the linker scripts.
pub const kernel_base_address = kernel.VirtAddr.fromInt(0xffffffff80000000);

pub var hhdm = kernel.VirtRange.fromAddr(kernel.VirtAddr.zero, core.Size.zero);
pub var non_cached_hhdm = kernel.VirtRange.fromAddr(kernel.VirtAddr.zero, core.Size.zero);
/// This is the offset between the virtual address the kernel expects to be loaded at and the actual address it is loaded at due to kaslr.
pub var kernel_kaslr_offset: core.Size = core.Size.zero;

/// This is the offset between the virtual addresses of the kernel's sections and the physical addresses.
pub var kernel_section_offset: core.Size = core.Size.zero;
