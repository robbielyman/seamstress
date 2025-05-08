const std = @import("std");
const e = @import("embed_file");

const Dep = struct {
    name: []const u8,
    module: *std.Build.Module,

    fn addImport(self: Dep, m: *std.Build.Module) void {
        m.addImport(self.name, self.module);
    }
};

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

fn extensionlessBasename(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const extension = std.fs.path.extension(basename);
    return basename[0 .. basename.len - extension.len];
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const deps = createImports(b, .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addSharedLibrary(.{
        .name = "seamstress",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (deps) |dep| dep.addImport(lib.root_module);
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
    for (deps) |dep| dep.addImport(exe.root_module);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    for (deps) |dep| dep.addImport(tests.root_module);
    const tests_run = b.addRunArtifact(tests);

    const tests_step = b.step("test", "test seamstress");
    tests_step.dependOn(&tests_run.step);

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
        dep.addImport(root_comp_check.root_module);
        dep.addImport(comp_check.root_module);
    }
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
    const release_mode: std.builtin.OptimizeMode = release_mode: {
        const version_str = version_str: {
            const str = std.fs.cwd().readFileAlloc(b.allocator, "version.txt", 1024) catch
                break :release_mode .ReleaseSafe;
            const index = std.mem.indexOfAny(u8, str, "\r\n\t ");
            break :version_str if (index) |n| str[0..n] else str;
        };
        const version = std.SemanticVersion.parse(version_str) catch break :release_mode .ReleaseSafe;
        break :release_mode if (version.pre != null) .ReleaseSafe else .ReleaseFast;
    };
    for (release_targets) |release_target| {
        const t = b.resolveTargetQuery(release_target);
        const release_exe = b.addExecutable(.{
            .name = "seamstress",
            .root_source_file = b.path("src/main.zig"),
            .target = t,
            .optimize = release_mode,
            .link_libc = true,
        });
        const target_deps = createImports(b, .{
            .target = t,
            .optimize = release_mode,
        });
        for (target_deps) |dep| dep.addImport(release_exe.root_module);

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
    var list: std.ArrayListUnmanaged(Dep) = .empty;
    list.ensureTotalCapacity(b.allocator, 5) catch @panic("OOM");

    const assets = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("module.zig",
            \\pub const lua = @import("lua");
            \\pub const @"test" = @import("test");
            \\pub const version = @import("version").version;
            \\
        ),
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
    {
        const ef = e.addEmbedFiles(b);
        ef.addFile(b.path("version.txt"), "semver-str", null);
        const wf_module = b.addWriteFiles().add("version.zig",
            \\const semver_str = str: {
            \\    const str = @import("semver-str").@"semver-str";
            \\    if (std.mem.indexOfAny(u8, &str, "\r\n \t")) |idx| break :str str[0..idx];
            \\    break :str &str;
            \\};
            \\const std = @import("std");
            \\
            \\pub const version = std.SemanticVersion.parse(semver_str) catch |err| {
            \\    @compileLog("string: ", semver_str);
            \\    @compileLog("error: ", err);
            \\    @compileError("semantic version string failed to parse!");
            \\};
        );
        const version = b.createModule(.{ .root_source_file = wf_module });
        version.addImport("semver-str", ef.module);
        assets.addImport("version", version);
    }

    const zlua = b.dependency("zlua", .{
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
    const known_folders = b.dependency("known_folders", .{});
    list.appendAssumeCapacity(.{ .module = zlua.module("zlua"), .name = "zlua" });
    list.appendAssumeCapacity(.{ .module = xev.module("xev"), .name = "xev" });
    list.appendAssumeCapacity(.{ .module = zosc.module("zosc"), .name = "zosc" });
    list.appendAssumeCapacity(.{ .module = known_folders.module("known-folders"), .name = "known-folders" });
    list.appendAssumeCapacity(.{ .module = assets, .name = "assets" });
    return list.items;
}
