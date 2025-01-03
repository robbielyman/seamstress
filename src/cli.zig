const Cli = @This();
const max_input_len = 2 * 1024;

buffer: std.ArrayListUnmanaged(u8) = .{},
c: xev.Completion = .{},
c_c: xev.Completion = .{},
stdin: Stdin,
running: bool = true,

pub fn register(l: *Lua) i32 {
    const cli = l.newUserdata(Cli, 0);
    cli.* = .{ .stdin = Stdin.init() };
    blk: {
        l.newMetatable("seamstress.cli") catch break :blk;
        const funcs: []const ziglua.FnReg = &.{
            .{ .name = "__gc", .func = ziglua.wrap(__gc) },
            .{ .name = "__index", .func = ziglua.wrap(__index) },
            .{ .name = "__newindex", .func = ziglua.wrap(__newindex) },
            .{ .name = "__cancel", .func = ziglua.wrap(__cancel) },
        };
        l.setFuncs(funcs, 0);
    }
    l.pop(1);
    _ = l.getMetatableRegistry("seamstress.cli");
    l.setMetatable(-2);
    setup(l) catch l.raiseErrorStr("unable to start CLI!", .{});
    return 1;
}

/// reads from the xev.File by using the event loop
fn setup(lua: *Lua) !void {
    const self = try lua.toUserdata(Cli, -1);
    self.running = true;
    try self.buffer.ensureUnusedCapacity(lua.allocator(), max_input_len);
    const seamstress = lu.getSeamstress(lua);
    lua.pushValue(-1); // ref pops
    const h = try lua.ref(ziglua.registry_index);
    if (!builtin.is_test) try std.io.getStdOut().writeAll("> ");
    self.stdin.read(&seamstress.loop, &self.c, .{
        .slice = self.buffer.unusedCapacitySlice(),
    }, anyopaque, lu.ptrFromHandle(h), stdinCallback);
}

fn loggingOnErrWriteFn(comptime Writer: type) fn (Writer, []const u8) anyerror!usize {
    return struct {
        fn write(writer: Writer, bytes: []const u8) anyerror!usize {
            return writer.write(bytes) catch |err| {
                logger.err("unable to write to stdout: {s}", .{@errorName(err)});
                return err;
            };
        }
    }.write;
}

fn LoggingOnErrWriter(comptime Writer: type) type {
    return std.io.GenericWriter(Writer, anyerror, loggingOnErrWriteFn(Writer));
}

fn loggingOnErrWriter(writer: anytype) LoggingOnErrWriter(@TypeOf(writer)) {
    return .{ .context = writer };
}

fn stdinCallback(
    ptr: ?*anyopaque,
    loop: *xev.Loop,
    c: *xev.Completion,
    _: Stdin,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const l = lu.getLua(loop);
    const handle = lu.handleFromPtr(ptr);
    _ = l.rawGetIndex(ziglua.registry_index, handle);
    const cli = l.toUserdata(Cli, -1) catch unreachable;

    const length = r catch |err| {
        const str = @errorName(err);
        l.pop(1);
        l.unref(ziglua.registry_index, handle);
        cli.running = false;
        if (err != error.Canceled and err != error.EOF)
            logger.err("error reading from stdin! {s}", .{str});
        if (err == error.EOF) {
            lu.load(l, "seamstress");
            _ = l.getField(-1, "stop");
            l.rotate(-2, 1);
            lu.doCall(l, 1, 0) catch {
                lu.reportError(l);
            };
        }
        return .disarm;
    };
    cli.buffer.items.len += length;

    cli.stdinCallback2(l, loop, c, ptr) catch {
        lu.reportError(l);
        l.unref(ziglua.registry_index, handle);
        cli.running = false;
    };
    l.pop(1);
    return .disarm;
}

fn stdinCallback2(cli: *Cli, l: *Lua, loop: *xev.Loop, c: *xev.Completion, ptr: ?*anyopaque) !void {
    if (std.mem.eql(u8, "quit\n", cli.buffer.items)) return {
        const handle = lu.handleFromPtr(ptr);
        l.unref(ziglua.registry_index, handle);
        cli.running = false;
        lu.load(l, "seamstress");
        _ = l.getField(-1, "stop");
        l.rotate(-2, 1);
        lu.doCall(l, 1, 0) catch {
            lu.reportError(l);
        };
    };
    var buf = std.io.bufferedWriter(if (!builtin.is_test)
        std.io.getStdOut().writer()
    else
        std.io.null_writer);
    const stdout = loggingOnErrWriter(buf.writer());
    lu.load(l, "seamstress.repl");
    _ = l.pushString(cli.buffer.items);
    lu.doCall(l, 1, 1) catch {
        lu.reportError(l);
        cli.buffer.clearRetainingCapacity();
        cli.buffer.ensureUnusedCapacity(lu.allocator(l), max_input_len) catch
            logger.warn("out of memory; unable to grow input buffer!", .{});
        cli.stdin.read(loop, c, .{
            .slice = cli.buffer.unusedCapacitySlice(),
        }, anyopaque, ptr, @This().stdinCallback);
    };
    const incomplete = l.typeOf(-1) == .string and std.mem.endsWith(u8, l.toString(-1) catch unreachable, "<eof>");
    if (incomplete) {
        l.pop(1); // pop the error string
        try stdout.writeAll(">...");
        buf.flush() catch |err| {
            logger.err("unable to write to stdout! {s}", .{@errorName(err)});
            return err;
        };
        cli.buffer.ensureUnusedCapacity(lu.allocator(l), max_input_len) catch
            logger.warn("out of memory; unable to grow input buffer!", .{});
        cli.stdin.read(loop, c, .{
            .slice = cli.buffer.unusedCapacitySlice(),
        }, anyopaque, ptr, @This().stdinCallback);
        return;
    }
    // complete; let's call it
    l.pushInteger(lu.handleFromPtr(ptr)); // stack is now: cli repl_func handle
    l.pushValue(-1);
    l.pushClosure(ziglua.wrap(resumeRepl(.success)), 1);
    l.pushValue(-2);
    l.pushClosure(ziglua.wrap(resumeRepl(.failure)), 1);
    l.remove(-3);
    try lu.waitForLuaCall(l, 0);
    l.pop(1); // pop the promise
}

fn resumeRepl(comptime which: enum { success, failure }) fn (*Lua) i32 {
    return struct {
        fn f(l: *Lua) i32 {
            const idx = Lua.upvalueIndex(1);
            const handle = l.toInteger(idx) catch unreachable;
            _ = l.getIndex(ziglua.registry_index, handle); // use the handle
            const cli = l.toUserdata(Cli, -1) catch unreachable;
            l.pop(1); // pop the cli
            switch (which) {
                .success => resumeRepl2(l) catch |err| {
                    l.unref(ziglua.registry_index, @intCast(handle));
                    logger.err("unable to write to stdout! {s}", .{@errorName(err)});
                    return 0;
                },
                .failure => {
                    lu.reportError(l);
                    std.io.getStdOut().writer().writeAll("> ") catch |err| {
                        logger.err("unable to write to stdout! {s}", .{@errorName(err)});
                        return 0;
                    };
                },
            }
            const s = lu.getSeamstress(l);
            cli.buffer.clearRetainingCapacity();
            cli.buffer.ensureUnusedCapacity(lu.allocator(l), max_input_len) catch
                logger.warn("out of memory; unable to grow input buffer!", .{});

            cli.stdin.read(&s.loop, &cli.c, .{
                .slice = cli.buffer.unusedCapacitySlice(),
            }, anyopaque, lu.ptrFromHandle(@intCast(handle)), stdinCallback);
            return 0;
        }
    }.f;
}

fn resumeRepl2(l: *Lua) !void {
    var buf = std.io.bufferedWriter(if (!builtin.is_test)
        std.io.getStdOut().writer()
    else
        std.io.null_writer);
    const stdout = loggingOnErrWriter(buf.writer());
    try printAll(l, stdout);
    try stdout.writeAll("> ");
    buf.flush() catch |err| {
        logger.err("unable to write to stdout! {s}", .{@errorName(err)});
        return err;
    };
}

fn printAll(l: *Lua, stdout: anytype) !void {
    const n = l.getTop();
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        switch (l.typeOf(i)) {
            .number => if (l.isInteger(i)) {
                try stdout.print("{d}", .{l.toInteger(i) catch unreachable});
            } else {
                try stdout.print("{d}", .{l.toNumber(i) catch unreachable});
            },
            .string => try stdout.print("{s}", .{l.toString(i) catch unreachable}),
            .nil => try stdout.print("nil", .{}),
            .boolean => try stdout.print("{s}", .{if (l.toBoolean(i)) "true" else "false"}),
            else => try stdout.print("{s}", .{l.toStringEx(i)}),
        }
        try stdout.writeAll(if (i != n) "\t" else "\n");
    }
}

fn __cancel(l: *Lua) i32 {
    const self = l.checkUserdata(Cli, 1, "seamstress.cli");
    if (!self.running) return 0;
    self.running = false;
    const seamstress = lu.getSeamstress(l);
    l.pushValue(1);
    const handle = l.ref(ziglua.registry_index) catch l.raiseErrorStr("unable to register CLI!", .{});
    self.c_c = .{
        .op = .{ .cancel = .{ .c = &self.c } },
        .userdata = lu.ptrFromHandle(handle),
        .callback = lu.unrefCallback,
    };
    seamstress.loop.add(&self.c_c);
    return 0;
}

fn __gc(l: *Lua) i32 {
    const self = l.checkUserdata(Cli, 1, "seamstress.cli");
    self.buffer.deinit(lu.allocator(l));
    return 0;
}

fn __index(l: *Lua) i32 {
    const cli = l.toUserdata(Cli, 1) catch unreachable;
    _ = l.pushStringZ("running");
    if (l.compare(-1, 2, .eq)) {
        l.pushBoolean(cli.running);
        return 1;
    }
    l.argError(2, "\"running\" expected");
}

fn __newindex(l: *Lua) i32 {
    const cli = l.toUserdata(Cli, 1) catch unreachable;
    _ = l.pushStringZ("running");
    if (l.compare(-1, 2, .eq)) {
        const running = l.toBoolean(3);
        if (!cli.running and running) {
            cli.running = true;
            l.pushValue(1);
            setup(l) catch l.raiseErrorStr("unable to start CLI!", .{});
        } else if (cli.running and !running) {
            cli.running = false;
            l.pushFunction(ziglua.wrap(__cancel));
            l.pushValue(1);
            l.call(1, 0);
        }
        return 0;
    }
    l.argError(2, "\"running\" expected");
}

const logger = std.log.scoped(.cli);

const std = @import("std");
const Seamstress = @import("seamstress.zig");
const xev = @import("xev");
const lu = @import("lua_util.zig");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;
const Stdin = @import("cli/stdin.zig");
const builtin = @import("builtin");
