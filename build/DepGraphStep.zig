// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const Application = @import("Application.zig");
const Kernel = @import("Kernel.zig");
const Library = @import("Library.zig");
const Tool = @import("Tool.zig");

const DepGraphStep = @This();

b: *std.Build,

step: Step,

dep_file: std.Build.GeneratedFile,
dep_lazy_path: std.Build.LazyPath,

kernels: Kernel.Collection,
libraries: Library.Collection,
tools: Tool.Collection,
applications: Application.Collection,

pub fn register(
    b: *std.Build,
    kernels: Kernel.Collection,
    libraries: Library.Collection,
    tools: Tool.Collection,
    applications: Application.Collection,
) !void {
    const dep_graph_step = try DepGraphStep.create(b, kernels, libraries, tools, applications);

    const run_step = b.step("dep_graph", "Generate the dependency graph");
    run_step.dependOn(&dep_graph_step.step);
}

fn create(
    b: *std.Build,
    kernels: Kernel.Collection,
    libraries: Library.Collection,
    tools: Tool.Collection,
    applications: Application.Collection,
) !*DepGraphStep {
    const self = try b.allocator.create(DepGraphStep);

    self.* = .{
        .b = b,
        .step = Step.init(.{
            .id = .custom,
            .name = "build dependency graph",
            .owner = b,
            .makeFn = make,
        }),
        .dep_file = undefined,
        .dep_lazy_path = undefined,

        .kernels = kernels,
        .libraries = libraries,
        .tools = tools,
        .applications = applications,
    };
    self.dep_file = .{ .step = &self.step };
    self.dep_lazy_path = .{ .generated = .{ .file = &self.dep_file } };

    return self;
}

fn make(step: *Step, progress_node: std.Progress.Node) !void {
    const self: *DepGraphStep = @fieldParentPtr("step", step);

    var node = progress_node.start(
        step.name,
        self.kernels.count() + self.libraries.count() + self.tools.count() + self.applications.count(),
    );
    defer node.end();

    var timer = try std.time.Timer.start();

    const dep_grap_file_path = self.b.pathJoin(&.{ "zig-out", "dependency_graph.d2" });
    try std.fs.cwd().makePath(std.fs.path.dirname(dep_grap_file_path).?);

    var output_file = try std.fs.cwd().createFile(dep_grap_file_path, .{});
    defer output_file.close();

    var buffered_writer = std.io.bufferedWriter(output_file.writer());
    const writer = buffered_writer.writer();

    try writer.writeAll(
        \\classes: {
        \\  binary: { shape: circle }
        \\  library
        \\}
        \\
    );

    var kernel_iterator = self.kernels.iterator();

    while (kernel_iterator.next()) |kernel| {
        const kernel_name = try std.fmt.allocPrint(self.b.allocator, "{s}_kernel", .{@tagName(kernel.key_ptr.*)});
        try writer.print("{s}: {{class: binary}}\n", .{kernel_name});

        for (kernel.value_ptr.dependencies) |dep| {
            try writer.print("{s} -> {s}\n", .{ kernel_name, dep.library.name });
        }

        node.completeOne();
    }

    var tool_iterator = self.tools.iterator();

    while (tool_iterator.next()) |tool| {
        const tool_name = tool.key_ptr.*;
        try writer.print("{s}: {{class: binary}}\n", .{tool_name});

        for (tool.value_ptr.dependencies) |dep| {
            try writer.print("{s} -> {s}\n", .{ tool_name, dep.library.name });
        }

        node.completeOne();
    }

    var application_iterator = self.applications.iterator();

    while (application_iterator.next()) |application| {
        const application_name = application.key_ptr.*;
        try writer.print("{s}: {{class: binary}}\n", .{application_name});

        // TODO: Support different dependencies for different targets
        var iter = application.value_ptr.valueIterator();
        const app = iter.next().?;

        for (app.dependencies) |dep| {
            try writer.print("{s} -> {s}\n", .{ application_name, dep.library.name });
        }

        node.completeOne();
    }

    var library_iterator = self.libraries.iterator();

    while (library_iterator.next()) |library| {
        const library_name = library.key_ptr.*;
        try writer.print("{s}: {{class: library}}\n", .{library_name});

        for (library.value_ptr.*.dependencies) |dep_library| {
            try writer.print("{s} -> {s}\n", .{ library_name, dep_library.library.name });
        }

        node.completeOne();
    }

    try buffered_writer.flush();

    self.dep_file.path = dep_grap_file_path;

    step.result_duration_ns = timer.read();
}
