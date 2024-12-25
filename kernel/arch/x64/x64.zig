// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const interrupts = struct {
    pub const disableInterruptsAndHalt = lib_x64.instructions.disableInterruptsAndHalt;
};

const std = @import("std");
const kernel = @import("kernel");
const lib_x64 = @import("lib_x64");
