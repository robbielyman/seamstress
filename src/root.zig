export fn luaopen_seamstress(l: ?*zlua.LuaState) c_int {
    const lua: *Lua = @ptrCast(l.?);
    return @call(.always_inline, Seamstress.register, .{lua});
}

const Seamstress = @import("seamstress.zig");
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
