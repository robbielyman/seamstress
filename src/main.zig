pub fn main() !void {
    // allocation
    var gpa: if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 20,
    }) else void = if (builtin.mode == .Debug) .{};
    defer if (builtin.mode == .Debug) {
        if (gpa.deinit() == .leak) {
            std.debug.print("leaked memory!\n", .{});
            // the leaks are printed to /tmp/seamstress.log,
            // but it would be nice to know to check for them!
        }
    };
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    // logging
    var bw = blk: {
        const cache_base = try folders.open(allocator, .cache, .{}) orelse break :blk null;
        try cache_base.makePath("seamstress");
        const path = "seamstress" ++ std.fs.path.sep_str ++ "seamstress.log";
        const logfile = try cache_base.createFile(path, .{ .truncate = false });
        const end = try logfile.getEndPos();
        try logfile.seekTo(end);
        break :blk std.io.bufferedWriter(logfile.writer());
    };
    defer if (bw) |*w| w.flush() catch {};
    if (bw) |*w| log_writer = w.writer().any();

    // arguments
    {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        maybePrintSweetNothingsAndExit(args);
    }

    // environment variables
    const environ = try setEnvironmentVariables(allocator);
    const old_environ =
        switch (builtin.os.tag) {
        .windows => old: {
            const old = std.os.windows.peb().ProcessParameters.Environment;
            std.os.windows.peb().ProcessParameters.Environment = @ptrCast(environ.ptr);
            break :old old;
        },
        .linux, .macos => old: {
            const old = std.c.environ;
            std.c.environ = environ.ptr;
            break :old old;
        },
        else => @compileError("os unsupported!"),
    };
    defer switch (builtin.os.tag) {
        .windows => {
            std.os.windows.peb().ProcessParameters.Environment = old_environ;
            freeEnviron(allocator, environ);
        },
        .linux, .macos => {
            std.c.environ = old_environ;
            freeEnviron(allocator, environ);
        },
        else => @compileError("os unsupported!"),
    };

    // handle SIGABRT (called by lua in Debug mode)
    const using_sigaction = builtin.mode == .Debug and builtin.os.tag != .windows;
    const act: if (using_sigaction) std.posix.Sigaction else void = if (using_sigaction) .{
        .handler = .{
            .handler = struct {
                fn handleAbrt(_: c_int) callconv(.C) noreturn {
                    if (panic_closure) |p| {
                        panic_closure = null;
                        p.panic_fn(p.ctx);
                        std.debug.dumpCurrentStackTrace(@returnAddress());
                    }
                    std.process.exit(1);
                }
            }.handleAbrt,
        },
        .mask = if (builtin.os.tag == .linux) std.posix.empty_sigset else 0,
        .flags = 0,
    };
    if (using_sigaction) try std.posix.sigaction(std.posix.SIG.ABRT, &act, null);

    const l = try Lua.init(&allocator);
    defer l.close();

    panic_closure = .{
        .ctx = l,
        .panic_fn = Seamstress.panicCleanup,
    };

    try Seamstress.main(l);
    // flush any accumulated logs
    if (bw) |*w| try w.flush();
    // in release modes, this calls `exit(0)`, saving us from having to wait for memory to be freed
    std.process.cleanExit();
}

const EnvBlockType = switch (builtin.os.tag) {
    .macos, .linux => [:null]?[*:0]u8,
    .windows => []u16,
    else => @compileError("os unsupported!"),
};

/// normalizes environment variables that seamstress uses
fn setEnvironmentVariables(allocator: std.mem.Allocator) !EnvBlockType {
    var map = try std.process.getEnvMap(allocator);
    defer map.deinit();
    luarocks: {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "luarocks", "path" },
        }) catch |err| {
            if (err == error.FileNotFound) break :luarocks;
            return err;
        };
        defer allocator.free(result.stderr);
        defer allocator.free(result.stdout);
        // `luarocks path` returns a series of commands of the form `export VARIABLE="value"`.
        // for each one, we set VARIABLE to value (without quotes) in our map
        var iter = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (iter.next()) |token| {
            const inner = std.mem.trimLeft(u8, token, "export ");
            const equals = std.mem.indexOfScalar(u8, inner, '=') orelse continue;
            const key = inner[0..equals];
            const value = inner[equals + 2 .. inner.len - 1];
            try map.put(key, value);
        }
    }
    if (map.get("SEAMSTRESS_HOME") == null) {
        const home = map.get("HOME") orelse {
            std.debug.print(
                \\$HOME and $SEAMSTRESS_HOME undefined!
                \\define $SEAMSTRESS_HOME and try again
                \\
            , .{});
            std.process.exit(1);
        };
        const seamstress_home = try std.fs.path.join(allocator, &.{ home, "seamstress" });
        defer allocator.free(seamstress_home);
        try map.put("SEAMSTRESS_HOME", seamstress_home);
    }
    return switch (builtin.os.tag) {
        .windows => try std.process.createWindowsEnvBlock(allocator, &map),
        .macos, .linux => try std.process.createEnvironFromMap(allocator, &map, .{}),
        else => comptime unreachable,
    };
}

/// frees memory
fn freeEnviron(allocator: std.mem.Allocator, environ: EnvBlockType) void {
    switch (builtin.os.tag) {
        .macos, .linux => {
            for (environ) |variable| {
                const slice = std.mem.sliceTo(variable orelse continue, 0);
                allocator.free(slice);
            }
            allocator.free(environ);
        },
        .windows => allocator.free(environ),
        else => comptime unreachable,
    }
}

/// if we get an agrument starting with -h, --h, -v or --v, print usage and exit
fn maybePrintSweetNothingsAndExit(args: []const []const u8) void {
    const needles: []const []const u8 = &.{ "-h", "--h", "--v", "-v" };
    blk: {
        for (args) |arg| {
            for (needles) |needle| if (std.mem.startsWith(u8, arg, needle)) break :blk;
        }
        return;
    }
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    stdout.print(
        \\SEAMSTRESS
        \\seamstress version: {}
        \\seamstress is an art engine,
        \\usage: seamstress [script_file_name]
        \\goodbye.
        \\
    , .{Seamstress.version}) catch {};
    bw.flush() catch {};
    std.process.exit(0);
}

// used by logFn (called by std.log), so global state is unavoidable
var log_writer: ?std.io.AnyWriter = null;

pub const std_options: std.Options = .{
    .logFn = struct {
        fn logFn(
            comptime level: std.log.Level,
            comptime scope: @TypeOf(.enum_literal),
            comptime fmt: []const u8,
            args: anytype,
        ) void {
            const w = log_writer orelse return;
            const prefix = "[" ++ @tagName(scope) ++ "]" ++ " (" ++ comptime level.asText() ++ "): ";
            w.print(prefix ++ fmt ++ "\n", args) catch {};
        }
    }.logFn,
    .log_level = switch (builtin.mode) {
        .ReleaseFast, .ReleaseSmall => .warn,
        .Debug, .ReleaseSafe => .debug,
    },
};

// used by std.debug.panic, so global state is unavoidable
var panic_closure: ?struct {
    ctx: *Lua,
    panic_fn: *const fn (*Lua) void,
} = null;

// allows us to shut down cleanly when panicking
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (panic_closure) |p| {
        panic_closure = null;
        p.panic_fn(p.ctx);
    }
    // inline so that stack traces are correct
    @call(.always_inline, std.builtin.default_panic, .{ msg, error_return_trace, ret_addr });
}

pub const known_folders_config: folders.KnownFolderConfig = .{
    .xdg_force_default = true,
    .xdg_on_mac = true,
};

const std = @import("std");
const builtin = @import("builtin");
const Seamstress = @import("seamstress.zig");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;
const lu = @import("lua_util.zig");
const folders = @import("known-folders");

test "ref" {
    _ = Seamstress;
}
