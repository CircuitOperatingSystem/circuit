// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

/// Ext2/3/4
pub const ext = @import("ext.zig");

/// File Allocation Table (FAT)
pub const fat = @import("fat.zig");

/// GUID Partition Table (GPT)
pub const gpt = @import("gpt.zig");

/// Master Boot Record (MBR)
pub const mbr = @import("mbr.zig");

comptime {
    refAllDeclsRecursive(@This(), true);
}

fn refAllDeclsRecursive(comptime T: type, comptime first: bool) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            // don't analyze if the decl is not pub unless we are the first level of this call chain
            if (!first) continue;

            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name), false),
                else => {},
            }
        }
        return;
    }
}
