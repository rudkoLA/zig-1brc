const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const is_fast = b.option(bool, "fast", "Build with ReleaseFast optimization") orelse false;

    const optimize: std.builtin.OptimizeMode = if (is_fast) .ReleaseFast else b.standardOptimizeOption(.{});

    const executables = [_][]const u8{
        "1brc_1",
        "1brc_2",
        "1brc_3",
    };

    for (executables) |exe_name| {
        const src_path = b.fmt("src/{s}.zig", .{exe_name});

        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_path),
                .target = target,
                .optimize = optimize,
            }),
        });

        b.installArtifact(exe);
    }
}
