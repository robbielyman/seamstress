/// bare-bones CLI communication layer
// @module seamstress.cli
const Cli = @This();

l: *Lua,
stdout: BufferedWriter,
stdin_buf: std.ArrayList(u8),
file: xev.File,
c: xev.Completion = .{},
c_c: xev.Completion = .{},
continuing: bool = false,
dirty: bool = false,

/// flushes stdout and stderr, and re-prompts (usually)
fn render(ctx: *anyopaque, _: u64) void {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    if (!self.dirty) return;
    self.dirty = false;
    const writer = self.stdout.writer();
    if (self.continuing)
        writer.writeAll(">... ") catch panic("unable to print!", .{})
    else
        writer.writeAll("> ") catch panic("unable to print!", .{});
    self.stdout.flush() catch panic("unable to print!", .{});
}

/// processes a chunk of stdin, renders, rinses and repeats
fn handleStdin(
    self: ?*Cli,
    l: *xev.Loop,
    c: *xev.Completion,
    f: xev.File,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const len = r catch 0;
    if (std.mem.indexOf(u8, buf.slice, "quit\n")) |idx| {
        if (idx == 0 or buf.slice[idx - 1] == '\n') {
            const wheel: *Wheel = @fieldParentPtr("loop", l);
            wheel.quit();
            return .disarm;
        }
    }
    self.?.stdin_buf.items.len += len;
    self.?.continuing = lu.processChunk(self.?.l, self.?.stdin_buf.items);
    if (!self.?.continuing) self.?.stdin_buf.clearRetainingCapacity();
    lu.luaPrint(self.?.l);
    self.?.dirty = true;
    f.read(l, c, .{ .slice = self.?.stdin_buf.unusedCapacitySlice() }, Cli, self, handleStdin);
    return .disarm;
}

/// says hello
fn hello(l: *Lua) i32 {
    const self: *Cli = lu.closureGetContext(l, Cli);
    const writer = self.stdout.writer();
    writer.print("SEAMSTRESS\n", .{}) catch return 0;
    writer.print("seamstress version: {}\n", .{@import("../seamstress.zig").version}) catch return 0;
    self.dirty = true;
    render(self, 0);
    return 0;
}

/// replaces `print`
pub fn printFn(l: *Lua) i32 {
    // how many things are we printing?
    const n = l.getTop();
    // get our closed-over value
    const self = lu.closureGetContext(l, Cli);
    const ctx = self.stdout.writer();
    // printing nothing should do nothing
    if (n == 0) return 0;
    // while loop because for loops are limited to `usize` in zig
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        // separate with tabs
        if (i > 1) ctx.writeAll("\t") catch {};
        const t = l.typeOf(i);
        switch (t) {
            .number => {
                if (l.isInteger(i)) {
                    const int = l.checkInteger(i);
                    ctx.print("{d}", .{int}) catch {};
                } else {
                    const double = l.checkNumber(i);
                    ctx.print("{d}", .{double}) catch {};
                }
            },
            .table => {
                const str = l.toString(i) catch {
                    const ptr = l.toPointer(i) catch unreachable;
                    ctx.print("table: 0x{x}", .{@intFromPtr(ptr)}) catch {};
                    continue;
                };
                ctx.print("{s}", .{str}) catch {};
            },
            .function => {
                const ptr = l.toPointer(i) catch unreachable;
                ctx.print("function: 0x{x}", .{@intFromPtr(ptr)}) catch {};
            },
            else => {
                const str = l.toStringEx(i);
                ctx.print("{s}", .{str}) catch {};
            },
        }
    }
    // finish with a newline
    ctx.writeAll("\n") catch {};
    const wheel = lu.getWheel(l);
    wheel.awaken();
    return 0;
}

fn init(m: *Module, l: *Lua, allocator: std.mem.Allocator) anyerror!void {
    const self = try allocator.create(Cli);
    errdefer allocator.destroy(self);
    const stdout_backing = try allocator.create(std.fs.File.Writer);
    errdefer allocator.destroy(stdout_backing);
    stdout_backing.* = std.io.getStdOut().writer();
    m.self = self;
    self.* = .{
        .l = l,
        .stdout = std.io.bufferedWriter(stdout_backing.any()),
        .stdin_buf = std.ArrayList(u8).init(allocator),
        .file = xev.File.init(std.io.getStdIn()) catch panic("unable to open stdin!", .{}),
    };
    l.pushLightUserdata(self);
    l.pushClosure(ziglua.wrap(printFn), 1);
    l.setGlobal("print");
    lu.registerSeamstress(l, null, "hello", hello, self);
}

fn cancelCallback(ud: ?*anyopaque, l: *xev.Loop, _: *xev.Completion, r: xev.Result) xev.CallbackAction {
    _ = r.cancel catch unreachable;
    const m: *Module = @ptrCast(@alignCast(ud.?));
    const lua = Wheel.getLua(l);
    m.deinit(lua, lua.allocator(), .full);
    return .disarm;
}

fn deinit(m: *Module, l: *Lua, allocator: std.mem.Allocator, kind: Cleanup) void {
    if (kind == .canceled) {
        const wheel = lu.getWheel(l);
        const self: *Cli = @ptrCast(@alignCast(m.self orelse return));
        self.c_c = .{
            .op = .{ .cancel = .{ .c = &self.c } },
            .userdata = m,
            .callback = cancelCallback,
        };
        wheel.loop.add(&self.c_c);
        return;
    }
    if (kind != .full) return;
    const self: *Cli = @ptrCast(@alignCast(m.self orelse return));
    self.stdout.flush() catch {};
    self.stdin_buf.deinit();
    allocator.destroy(@as(*const std.fs.File.Writer, @ptrCast(@alignCast(self.stdout.unbuffered_writer.context))));
    allocator.destroy(self);
    m.self = null;
}

fn launch(m: *const Module, l: *Lua, wheel: *Wheel) anyerror!void {
    const self: *Cli = @ptrCast(@alignCast(m.self.?));
    try self.stdin_buf.ensureUnusedCapacity(4096);
    const slice = self.stdin_buf.unusedCapacitySlice();
    wheel.render = .{
        .ctx = self,
        .render_fn = render,
    };
    self.file.read(&wheel.loop, &self.c, .{ .slice = slice[0..@min(slice.len, 4096)] }, Cli, self, handleStdin);
    _ = l; // autofix
}

pub fn module() Module {
    return .{ .vtable = &.{
        .init_fn = init,
        .deinit_fn = deinit,
        .launch_fn = launch,
    } };
}

const BufferedWriter = std.io.BufferedWriter(4096, std.io.AnyWriter);
const Module = @import("../module.zig");
const Spindle = @import("../spindle.zig");
const Wheel = @import("../wheel.zig");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;
const Cleanup = @import("../seamstress.zig").Cleanup;
const std = @import("std");
const xev = @import("xev");
const panic = std.debug.panic;
const lu = @import("../lua_util.zig");

test "ref" {
    _ = Cli;
}
