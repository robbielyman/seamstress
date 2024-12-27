const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addSharedLibrary(.{
        .name = "seamstress",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addImports(b, &lib.root_module, target, optimize);
    const lib_install = b.addInstallFileWithDir(lib.getEmittedBin(), .lib, "seamstress.so");
    lib_install.step.dependOn(&lib.step);
    const lib_install_step = b.step("lib", "build seamstress as a dynamic library");
    lib_install_step.dependOn(&lib_install.step);

    const exe = b.addExecutable(.{
        .name = "seamstress",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addImports(b, &exe.root_module, target, optimize);
    b.installArtifact(exe);

    const install_lua_files = b.addInstallDirectory(.{
        .source_dir = b.path("lua"),
        .install_dir = .{ .custom = "share/seamstress" },
        .install_subdir = "lua",
    });
    b.getInstallStep().dependOn(&install_lua_files.step);

    const tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    addImports(b, &tests.root_module, target, optimize);
    const tests_run = b.addRunArtifact(tests);
    tests_run.setEnvironmentVariable("SEAMSTRESS_LUA_PATH", b.path("lua").getPath(b));

    const run_lua_tests = b.addRunArtifact(exe);
    run_lua_tests.step.dependOn(b.getInstallStep());
    run_lua_tests.addArg("test");
    const tests_step = b.step("test", "test seamstress");
    tests_step.dependOn(&tests_run.step);
    tests_step.dependOn(&run_lua_tests.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "run seamstress");
    run_step.dependOn(&run.step);

    const comp_check = b.addExecutable(.{
        .name = "seamstress",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_comp_check = b.addSharedLibrary(.{
        .name = "seamstress",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addImports(b, &root_comp_check.root_module, target, optimize);
    addImports(b, &comp_check.root_module, target, optimize);
    const check = b.step("check", "check for compile errors");
    check.dependOn(&comp_check.step);
    check.dependOn(&root_comp_check.step);

    const release_targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
    };
    const release_step = b.step("release", "build release");
    for (release_targets) |release_target| {
        const t = b.resolveTargetQuery(release_target);
        const release_exe = b.addExecutable(.{
            .name = "seamstress",
            .root_source_file = b.path("src/main.zig"),
            .target = t,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        addImports(b, &release_exe.root_module, t, .ReleaseFast);

        const target_output = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{
                .custom = try std.fs.path.join(b.allocator, &.{
                    try release_target.zigTriple(b.allocator),
                    "bin",
                }),
            } },
        });
        const target_install_lua_files = b.addInstallDirectory(.{
            .source_dir = b.path("lua"),
            .install_dir = .{
                .custom = try std.fs.path.join(b.allocator, &.{
                    try release_target.zigTriple(b.allocator),
                    "share",
                    "seamstress",
                }),
            },
            .install_subdir = "lua",
        });
        release_step.dependOn(&target_output.step);
        release_step.dependOn(&target_install_lua_files.step);
    }
}

fn addImports(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const ziglua = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
    });
    m.addImport("ziglua", ziglua.module("ziglua"));

    const xev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    m.addImport("xev", xev.module("xev"));

    const zosc = b.dependency("zosc", .{
        .target = target,
        .optimize = optimize,
    });
    m.addImport("zosc", zosc.module("zosc"));
}
