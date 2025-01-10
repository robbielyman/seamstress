const Args = @This();

logging: logging.Args,
run: Seamstress.RunArgs,

pub fn format(args: Args, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    try writer.print("log file: {s}, log level: {s}\n", .{ args.logging.path orelse "default", switch (args.logging.level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    } });
    if (args.run.file) |name| {
        try writer.print("root lua file: {s}\n", .{name});
    }
    if (!args.run.tests.run_tests) return;
    try writer.writeAll("running tests\n");
    const dir = args.run.tests.dir orelse return;
    try writer.print("additional tests directory: {s}\n", .{dir});
}

pub fn process(cli_args: []const []const u8) Args {
    var file: ?[]const u8 = null;
    var logging_arg: logging.Args = .{};
    var maybe_level: ?std.log.Level = null;
    var maybe_test: ?bool = null;
    var maybe_test_dir: ?[]const u8 = null;
    var index: usize = 1;
    while (index < cli_args.len) : (index += 1) {
        const arg = cli_args[index];
        if (mem.eql(u8, arg, "-v") or mem.eql(u8, arg, "--version")) fatalVersion();
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) fatalHelp();
        if (mem.eql(u8, arg, "--log")) {
            index += 1;
            if (index >= cli_args.len) fatal("filename expected after --log", .{});
            if (logging_arg.path != null) fatal("duplicate --log arg found", .{});
            logging_arg.path = cli_args[index];
            continue;
        }
        if (mem.eql(u8, arg, "--log-level")) {
            index += 1;
            if (index >= cli_args.len) fatal("level expected after --log-level", .{});
            if (maybe_level != null) fatal("duplicate --log-level arg found", .{});
            inline for (valid_levels) |level|
                if (mem.eql(u8, cli_args[index], level.asText())) {
                    maybe_level = level;
                };
            logging_arg.level = maybe_level orelse fatal(
                \\invalid log level arg: {s}
                \\valid levels are {s}
            , .{ cli_args[index], levelsString() });
            continue;
        }
        if (mem.eql(u8, arg, "--test")) {
            if (maybe_test != null) fatal("duplicate --test arg found", .{});
            maybe_test = true;
            continue;
        }
        if (mem.eql(u8, arg, "--test-dir")) {
            index += 1;
            if (index >= cli_args.len) fatal("level expected after --test-dir", .{});
            if (maybe_test_dir != null) fatal("duplicate --test-dir arg found", .{});
            maybe_test_dir = cli_args[index];
            continue;
        }
        if (file != null) fatal("duplicate file found", .{});
        file = arg;
    }
    return .{
        .logging = logging_arg,
        .run = .{
            .file = file,
            .tests = .{
                .run_tests = maybe_test orelse (maybe_test_dir != null),
                .dir = maybe_test_dir,
            },
        },
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn fatalVersion() noreturn {
    std.debug.print(
        \\seamstress version: {} optimization level: {s}
        \\
    , .{ Seamstress.version, @tagName(builtin.mode) });
    std.process.exit(0);
}

fn fatalHelp() noreturn {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();
    const path = folders.getPath(allocator, .cache) catch unreachable orelse unreachable;
    const args: logging.Args = .{};
    fatal(
        \\seamstress is an art engine
        \\seamstress version: {} optimization level: {s}
        \\
        \\usage: seamstress [lua_file] [options]
        \\
        \\  lua_file (optional)   path to lua_file to be run on startup
        \\
        \\options:
        \\  --version, -v         print version info and exit
        \\  --help, -h            print this help and exit
        \\  --log filename        log to file_name
        \\                        by default logs are written to
        \\                        {s}{s}
        \\  --log-level level     valid levels: {s}
        \\                        default: {s}
        \\  --test                run seamstress tests
        \\                        (requires luarocks + busted)
        \\  --test-dir dir        load additional tests from dir
        \\                        test files should have filenames ending in _spec
        \\                        (requires luarocks + busted)
        \\
    , .{
        Seamstress.version,
        @tagName(builtin.mode),
        path,
        std.fs.path.sep_str ++ "seamstress" ++ std.fs.path.sep_str ++ "seamstress.log",
        levelsString(),
        args.level.asText(),
    });
}

const max_level: std.log.Level = switch (builtin.mode) {
    .ReleaseFast, .ReleaseSmall => .warn,
    .Debug, .ReleaseSafe => .debug,
};

const valid_levels: []const std.log.Level = blk: {
    var lev: []const std.log.Level = &.{};
    const fields = std.meta.tags(std.log.Level);
    for (fields) |field|
        if (@intFromEnum(field) <= @intFromEnum(max_level)) {
            lev = lev ++ .{field};
        };
    break :blk lev;
};

fn levelsString() []const u8 {
    const string = comptime blk: {
        const lev = valid_levels;
        var w = std.io.countingWriter(std.io.null_writer);
        for (lev, 0..) |level, i| {
            if (i > 0) w.writer().writeAll(", ") catch unreachable;
            try w.writer().writeAll(level.asText());
        }
        var buf: [w.bytes_written]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        for (lev, 0..) |level, i| {
            if (i > 0) try stream.writer().writeAll(", ");
            try stream.writer().writeAll(level.asText());
        }
        const string = buf;
        break :blk string;
    };
    return &string;
}

const std = @import("std");
const mem = std.mem;
const Seamstress = @import("seamstress.zig");
const folders = @import("known-folders");
const builtin = @import("builtin");
const logging = @import("logging.zig");
