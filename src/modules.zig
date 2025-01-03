/// the master list of all seamstress modules
/// pub so that the loader function defined in seamstress.zig can access it
pub const list = std.StaticStringMap(*const fn (?*ziglua.LuaState) callconv(.C) i32).initComptime(.{
    .{ "seamstress", ziglua.wrap(@import("seamstress.zig").register) },
    .{ "seamstress.event", ziglua.wrap(openFn("event.lua")) },
    .{ "seamstress.async", ziglua.wrap(@import("async.zig").register(.@"async")) },
    .{ "seamstress.async.Promise", ziglua.wrap(@import("async.zig").register(.promise)) },
    .{ "seamstress.test", ziglua.wrap(openFn("test.lua")) },
    .{ "seamstress.Timer", ziglua.wrap(@import("timer.zig").register) },
    .{ "seamstress.osc", ziglua.wrap(@import("osc.zig").register(.osc)) },
    .{ "seamstress.osc.Client", ziglua.wrap(@import("osc.zig").register(.client)) },
    .{ "seamstress.osc.Server", ziglua.wrap(@import("osc.zig").register(.server)) },
    .{ "seamstress.osc.Message", ziglua.wrap(@import("osc.zig").register(.message)) },
    .{ "seamstress.monome", ziglua.wrap(@import("monome.zig").register(.monome)) },
    .{ "seamstress.monome.Grid", ziglua.wrap(@import("monome.zig").register(.grid)) },
    .{ "seamstress.monome.Arc", ziglua.wrap(@import("monome.zig").register(.arc)) },
    .{ "seamstress.repl", ziglua.wrap(@import("repl.zig").register) },
    .{ "seamstress.cli", ziglua.wrap(@import("cli.zig").register) },
    .{ "seamstress.builtin_test_files", ziglua.wrap(builtinTestFiles) },
});

fn openFn(comptime filename: []const u8) fn (*Lua) i32 {
    const extension = comptime std.fs.path.extension(filename);
    const decl_name = filename[0 .. filename.len - extension.len];
    const builtin_file_string = @field(assets.lua, decl_name);
    return struct {
        fn f(l: *Lua) i32 {
            if (std.process.hasEnvVarConstant("SEAMSTRESS_LUA_PATH")) {
                const prefix = std.process.getEnvVarOwned(lu.allocator(l), "SEAMSTRESS_LUA_PATH") catch {
                    l.raiseErrorStr("out of memory!", .{});
                };
                defer lu.allocator(l).free(prefix);
                lu.format(l, "{s}" ++ std.fs.path.sep_str ++ "core" ++ std.fs.path.sep_str ++ filename, .{prefix});
                if (l.doFile(l.toString(-1) catch unreachable)) return 1 else |_| l.pop(1); // if that fails, fall back to the builtin file
            }
            l.doString(&builtin_file_string) catch unreachable;
            return 1; // return res
        }
    }.f;
}

/// loads the seamstress module `module_name`; e.g. "seamstress" or "seamstress.event".
pub const load = if (builtin.mode == .Debug) loadComptime else loadRuntime;

fn loadRuntime(l: *Lua, module_name: [:0]const u8) void {
    const func = list.get(module_name).?;
    l.requireF(module_name, func, false);
}

fn loadComptime(l: *Lua, comptime module_name: [:0]const u8) void {
    const func = comptime list.get(module_name) orelse @compileError("no such module name: " ++ module_name);
    l.requireF(module_name, func, false);
}

fn builtinTestFiles(l: *Lua) i32 {
    const decls = comptime std.meta.declarations(assets.@"test");
    l.createTable(decls.len, 0);
    var idx: ziglua.Integer = 1;
    inline for (decls) |decl| {
        _ = l.pushAny(.{
            .filename = decl.name,
            .file = &@field(assets.@"test", decl.name),
        }) catch unreachable;
        l.setIndex(-2, idx);
        idx += 1;
    }
    return 1;
}

const assets = @import("assets");

const std = @import("std");
const builtin = @import("builtin");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;
const lu = @import("lua_util.zig");
