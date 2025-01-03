const std = @import("std");
const e = @import("embed-file");

const Dep = struct {
    name: []const u8,
    module: *std.Build.Module,

    fn addImport(self: Dep, m: *std.Build.Module) void {
        m.addImport(self.name, self.module);
    }
};

const Options = struct {
    sys: Sys,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    const Sys = struct {
        lua: ?[]const u8,

        const release: Sys = .{ .lua = null };
    };
};

fn extensionlessBasename(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const extension = std.fs.path.extension(basename);
    return basename[0 .. basename.len - extension.len];
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lua_dir = b.option([]const u8, "lua-dir", "directory containing the system Lua library");

    const assets = b.createModule(.{
        .root_source_file = b.addWriteFile("module.zig",
            \\pub const lua = @import("lua");
            \\pub const @"test" = @import("test");
            \\
        ).files.items[0].getPath(),
    });
    {
        const lua_files: []const []const u8 = &.{
            "lua/core/test.lua",
            "lua/core/event.lua",
        };
        const ef = e.addEmbedFiles(b);
        for (lua_files) |file| ef.addFile(b.path(file), extensionlessBasename(file), null);
        assets.addImport("lua", ef.module);
    }
    {
        const lua_test_files: []const []const u8 = &.{
            "lua/test/monome_spec.lua",
            "lua/test/async_spec.lua",
            "lua/test/timer_spec.lua",
            "lua/test/osc_spec.lua",
        };
        const ef = e.addEmbedFiles(b);
        for (lua_test_files) |file| ef.addFile(b.path(file), extensionlessBasename(file), null);
        assets.addImport("test", ef.module);
    }

    const deps = createImports(b, .{
        .target = target,
        .optimize = optimize,
        .sys = .{
            .lua = lua_dir,
        },
    });

    const lib = b.addSharedLibrary(.{
        .name = "seamstress",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (deps) |dep| dep.addImport(&lib.root_module);
    lib.root_module.addImport("assets", assets);
    const lib_install = b.addInstallFileWithDir(
        lib.getEmittedBin(),
        .lib,
        if (target.result.os.tag == .windows) "seamstress.dll" else "seamstress.so",
    );
    lib_install.step.dependOn(&lib.step);
    const lib_install_step = b.step("lib", "build seamstress as a dynamic library");
    lib_install_step.dependOn(&lib_install.step);

    const exe = b.addExecutable(.{
        .name = "seamstress",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (deps) |dep| dep.addImport(&exe.root_module);
    exe.root_module.addImport("assets", assets);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    for (deps) |dep| dep.addImport(&tests.root_module);
    tests.root_module.addImport("assets", assets);
    const tests_run = b.addRunArtifact(tests);

    const run_lua_tests = b.addRunArtifact(exe);
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
    for (deps) |dep| {
        dep.addImport(&root_comp_check.root_module);
        dep.addImport(&comp_check.root_module);
    }
    root_comp_check.root_module.addImport("assets", assets);
    comp_check.root_module.addImport("assets", assets);
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
        const target_deps = createImports(b, .{
            .sys = Options.Sys.release,
            .target = t,
            .optimize = .ReleaseFast,
        });
        for (target_deps) |dep| dep.addImport(&release_exe.root_module);
        release_exe.root_module.addImport("assets", assets);

        const target_output = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{
                .custom = try std.fs.path.join(b.allocator, &.{
                    try release_target.zigTriple(b.allocator),
                    "bin",
                }),
            } },
        });
        release_step.dependOn(&target_output.step);
    }
}

fn createImports(b: *std.Build, options: Options) []const Dep {
    var list: std.ArrayListUnmanaged(Dep) = .{};
    list.ensureTotalCapacity(b.allocator, 5) catch @panic("OOM");

    const ziglua = b.dependency("ziglua", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const xev = b.dependency("libxev", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const zosc = b.dependency("zosc", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const @"known-folders" = b.dependency("known-folders", .{});
    list.appendAssumeCapacity(.{ .module = ziglua.module("ziglua"), .name = "ziglua" });
    list.appendAssumeCapacity(.{ .module = xev.module("xev"), .name = "xev" });
    list.appendAssumeCapacity(.{ .module = zosc.module("zosc"), .name = "zosc" });
    list.appendAssumeCapacity(.{ .module = @"known-folders".module("known-folders"), .name = "known-folders" });

    return list.items;
}
