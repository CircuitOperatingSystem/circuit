// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const dependencies: []const LibraryDependency = &[_]LibraryDependency{
    .{ .name = "containers" },
    .{ .name = "core" },
    .{ .name = "limine" },
    .{ .name = "sdf" },
};

pub const arm64_dependencies: []const LibraryDependency = &[_]LibraryDependency{
    .{ .name = "arm64" },
};

pub const riscv64_dependencies: []const LibraryDependency = &[_]LibraryDependency{
    .{ .name = "riscv64" },
};

pub const x64_dependencies: []const LibraryDependency = &[_]LibraryDependency{
    .{ .name = "x64" },
};

const LibraryDependency = @import("../build/LibraryDependency.zig");
