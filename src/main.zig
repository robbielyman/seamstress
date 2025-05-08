pub fn main() !void {
    // allocation
    var gpa: std.heap.GeneralPurposeAllocator(if (builtin.mode == .Debug)
        .{ .stack_trace_frames = 20 }
    else
        .{}) = .{};
    const allocator = gpa.allocator();

    const cli_args = try std.process.argsAlloc(allocator);
    const args = Args.process(cli_args);

    logging.init(allocator, args.log);

    std.log.scoped(.args).debug("{}", .{args});

    defer {
        std.process.argsFree(allocator, cli_args);
        if (gpa.deinit() == .leak) {
            std.debug.print("leaked memory!\n", .{});
            // the leaks are logged
            // but it would be nice to know to check for them!
        }
        logging.deinit();
    }

    const environ = Env.set(allocator);
    defer if (environ) |env| env.deinit(allocator);

    // handle SIGABRT (raised by lua in Debug mode)
    const using_sigaction = builtin.mode == .Debug and builtin.os.tag != .windows;
    if (using_sigaction) setAbrtHandler() catch {};

    const l = try Lua.init(allocator);
    defer l.deinit();

    panic_closure = .{
        .ctx = l,
        .panic_fn = Seamstress.panicCleanup,
    };

    try Seamstress.main(l, args.run);
    // in release modes, this calls `exit(0)`, saving us from having to wait for memory to be freed
    if (builtin.mode != .Debug) logging.deinit();
    std.process.cleanExit();
}

fn setAbrtHandler() !void {
    const act: std.posix.Sigaction = .{
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
        .mask = if (builtin.os.tag == .linux) std.posix.sigemptyset() else 0,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.ABRT, &act, null);
}

pub const known_folders_config = logging.known_folders_config;
pub const std_options: std.Options = .{
    .logFn = logging.logFn,
    // this is the lowest level of logging which we'll compile in capability for
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
    if (error_return_trace) |trace| std.debug.dumpStackTrace(trace.*);
    @call(.always_inline, std.debug.defaultPanic, .{ msg, ret_addr });
}

const std = @import("std");
const builtin = @import("builtin");
const Seamstress = @import("seamstress.zig");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const lu = @import("lua_util.zig");
const logging = @import("logging.zig");
const Args = @import("args.zig");
const Env = @import("env.zig");

test "ref" {
    _ = Seamstress;
    _ = logging;
}
