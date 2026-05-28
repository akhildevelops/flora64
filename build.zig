const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Shared modules
    // -----------------------------------------------------------------------

    const merge_core_mod = b.addModule("merge_core", .{
        .root_source_file = b.path("src/merge_core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const data_types_mod = b.addModule("data_types", .{
        .root_source_file = b.path("src/data_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const flora64_mod = b.addModule("flora64", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -----------------------------------------------------------------------
    // Native executable (CLI)
    // -----------------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "flora64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/geojson.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flora64", .module = flora64_mod },
                .{ .name = "data_types", .module = data_types_mod },
                .{ .name = "merge_core", .module = merge_core_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // -----------------------------------------------------------------------
    // WASM library (browser)
    // -----------------------------------------------------------------------

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "flora64_merge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_merge.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "merge_core", .module = merge_core_mod },
            },
        }),
    });
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    // Copy WASM into www/public/ so the frontend can fetch it.
    const install_wasm = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "../www/public" } },
    });
    b.getInstallStep().dependOn(&install_wasm.step);

    // -----------------------------------------------------------------------
    // Steps
    // -----------------------------------------------------------------------

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = flora64_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
