pub const Args = struct {
    path: ?[]const u8 = null,
    level: std.log.Level = switch (builtin.mode) {
        .ReleaseFast => .err,
        .Debug => .debug,
        else => .warn,
    },
};

pub fn init(gpa: std.mem.Allocator, args: Args) void {
    init2(gpa, args.path, args.level) catch |err| {
        std.debug.print(
            \\error enabling logging! {s}
            \\logging disabled!
            \\
        , .{@errorName(err)});
        log_writer = null;
    };
}

pub fn deinit() void {
    const w = log_writer orelse return;
    defer w.context.close();
    var bw = std.io.bufferedWriter(w);
    const date = Date.init(std.time.timestamp());
    bw.writer().print(
        \\-----seamstress shutdown time: {}-----
        \\
    , .{date}) catch return;
    bw.flush() catch {};
}

fn init2(gpa: std.mem.Allocator, path: ?[]const u8, level: std.log.Level) !void {
    log_level = level;
    const logfile = if (path) |p|
        try std.fs.cwd().createFile(p, .{ .truncate = false })
    else
        blk: {
            const cache_base = try folders.open(gpa, .cache, .{}) orelse break :blk null;
            try cache_base.makePath("seamstress");
            const p = "seamstress" ++ std.fs.path.sep_str ++ "seamstress.log";
            break :blk try cache_base.createFile(p, .{ .truncate = false });
        } orelse return error.Failed;
    const end = try logfile.getEndPos();
    try logfile.seekTo(end);
    const date = Date.init(std.time.timestamp());
    var bw = std.io.bufferedWriter(logfile.writer());
    bw.writer().print(
        \\
        \\-----seamstress startup time:  {}-----
        \\
    , .{date}) catch {};
    bw.flush() catch {};
    log_writer = logfile.writer();
}

const Date = struct {
    year: u16,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
    seconds: u6,

    fn init(secs: i64) Date {
        const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @max(secs, 0) };
        const into_day = epoch_secs.getDaySeconds();
        const day = epoch_secs.getEpochDay();
        const year = day.calculateYearDay();
        const month = year.calculateMonthDay();

        return .{
            .seconds = into_day.getSecondsIntoMinute(),
            .minute = into_day.getMinutesIntoHour(),
            .hour = into_day.getHoursIntoDay(),
            .day = month.day_index + 1,
            .month = month.month.numeric(),
            .year = year.year,
        };
    }

    pub fn format(date: Date, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{[year]d:0>4}-{[month]d:0>2}-{[day]d:0>2} UTC {[hour]d:0>2}:{[minute]d:0>2}:{[seconds]d:0>2}", date);
    }

    test format {
        const date: Date = .{
            .year = 2025,
            .month = 1,
            .day = 4,
            .hour = 10,
            .minute = 27,
            .seconds = 5,
        };
        var buf: [4 + 1 + 2 + 1 + 2 + 1 + 3 + 1 + 2 + 1 + 2 + 1 + 2]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{}", .{date});
        try std.testing.expectEqualStrings("2025-01-04 UTC 10:27:05", str);
    }
};

// used by logFn, so global state is unavoidable
var log_writer: ?std.fs.File.Writer = switch (builtin.os.tag) {
    .linux, .macos => std.io.getStdErr().writer(),
    else => null,
};
var log_level: std.log.Level = switch (builtin.mode) {
    .ReleaseFast, .ReleaseSmall => .warn,
    .Debug, .ReleaseSafe => .debug,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const w = log_writer orelse return;
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;
    var bw = std.io.bufferedWriter(w);
    const prefix = "[" ++ @tagName(scope) ++ "]" ++ " (" ++ comptime level.asText() ++ "): ";
    bw.writer().print(prefix ++ fmt ++ "\n", args) catch return;
    bw.flush() catch {};
}

pub const known_folders_config: folders.KnownFolderConfig = .{
    .xdg_force_default = true,
    .xdg_on_mac = true,
};

const std = @import("std");
const builtin = @import("builtin");
const folders = @import("known-folders");

test "ref" {
    _ = Date;
}
