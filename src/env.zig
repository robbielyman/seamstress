const Env = @This();

environ: switch (builtin.os.tag) {
    .macos, .linux => [:null]?[*:0]u8,
    .windows => []u16,
    else => @compileError("os unsupported!"),
},
old: switch (builtin.os.tag) {
    .macos, .linux => [*:null]?[*:0]u8,
    .windows => [*:0]u16,
    else => @compileError("os unsupported!"),
},

pub fn set(gpa: std.mem.Allocator) ?Env {
    var env = Env.init(gpa) catch return null;
    env.old = switch (builtin.os.tag) {
        .macos, .linux => std.c.environ,
        .windows => std.os.windows.peb().ProcessParameters.Environment,
        else => comptime unreachable,
    };
    return env;
}

pub fn init(gpa: std.mem.Allocator) !Env {
    var map = try std.process.getEnvMap(gpa);
    defer map.deinit();
    luarocks: {
        const result = std.process.Child.run(.{
            .allocator = gpa,
            .argv = &.{ "luarocks", "path" },
        }) catch |err| {
            if (err == error.FileNotFound) break :luarocks;
            return err;
        };
        defer gpa.free(result.stderr);
        defer gpa.free(result.stdout);
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
    return .{
        .environ = switch (builtin.os.tag) {
            .windows => try std.process.createWindowsEnvBlock(gpa, &map),
            .macos, .linux => try std.process.createEnvironFromMap(gpa, &map, .{}),
            else => comptime unreachable,
        },
        .old = undefined,
    };
}

pub fn deinit(env: Env, gpa: std.mem.Allocator) void {
    switch (builtin.os.tag) {
        .macos, .linux => {
            std.c.environ = env.old;
            for (env.environ) |variable| {
                const slice = std.mem.sliceTo(variable orelse continue, 0);
                gpa.free(slice);
            }
            gpa.free(env.environ);
        },
        .windows => {
            std.os.windows.peb().ProcessParameters.Environment = env.old;
            gpa.free(env.environ);
        },
        else => comptime unreachable,
    }
}

const std = @import("std");
const builtin = @import("builtin");
