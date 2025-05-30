pub fn register(l: *Lua) i32 {
    blk: {
        l.newMetatable("seamstress.osc.Server") catch break :blk;
        const funcs: []const zlua.FnReg = &.{
            .{ .name = "__index", .func = zlua.wrap(__index) },
            .{ .name = "__newindex", .func = zlua.wrap(__newindex) },
            .{ .name = "send", .func = zlua.wrap(send) },
            .{ .name = "dispatch", .func = zlua.wrap(dispatch) },
            .{ .name = "__gc", .func = zlua.wrap(__gc) },
            .{ .name = "add", .func = zlua.wrap(add) },
            .{ .name = "__cancel", .func = zlua.wrap(__cancel) },
            .{ .name = "__pairs", .func = zlua.wrap(__pairs) },
        };
        l.setFuncs(funcs, 0);
    }
    l.pop(1);
    l.pushFunction(zlua.wrap(new));
    return 1;
}

/// sends the bytes to the given address via the UDP server
pub fn sendOSCBytes(self: *Server, addr: std.net.Address, bytes: []const u8) !void {
    _ = try std.posix.sendto(
        self.socket,
        bytes,
        0,
        &addr.any,
        addr.getOsSockLen(),
    );
}

const Server = @This();
c: xev.Completion = .{},
c_c: xev.Completion = .{},
udp: xev.UDP,
state: xev.UDP.State = if (xev.backend == .io_uring) .{
    .userdata = null,
    .op = undefined,
} else .{
    .userdata = null,
},
addr: std.net.Address,
socket: std.posix.socket_t,
buf: [0xffff]u8 = undefined,
running: bool = true,

const handleFromPtr = lu.handleFromPtr;
const ptrFromHandle = lu.ptrFromHandle;

fn add(l: *Lua) i32 {
    l.checkType(1, .userdata);
    switch (l.typeOf(2)) {
        .userdata => {
            const client = l.checkUserdata(@import("client.zig"), 2, "seamstress.osc.Client");
            osc.pushAddress(l, .string, client.addr);
            l.pushValue(2);
        },
        .table => {
            lu.load(l, "seamstress.osc.Client");
            l.pushValue(2);
            l.call(.{ .args = 1, .results = 1 });
            const client = l.toUserdata(@import("client.zig"), -1) catch unreachable;
            osc.pushAddress(l, .string, client.addr);
            l.rotate(-2, 1);
        },
        else => l.typeError(2, "seamstress.osc.Client"),
    }
    l.setTable(1);
    return 0;
}

/// starts up the OSC Server object on top of the stack
/// stack effect: unchanged
fn run(l: *Lua) !void {
    const self = try l.toUserdata(Server, -1);
    l.pushValue(-1);
    const handle = try l.ref(zlua.registry_index);
    const seamstress = lu.getSeamstress(l);
    self.udp.read(
        &seamstress.loop,
        &self.c,
        &self.state,
        .{ .slice = &self.buf },
        anyopaque,
        ptrFromHandle(handle),
        struct {
            fn callback(
                ud: ?*anyopaque,
                loop: *xev.Loop,
                c: *xev.Completion,
                s: *xev.UDP.State,
                addr: std.net.Address,
                udp: xev.UDP,
                b: xev.ReadBuffer,
                r: xev.ReadError!usize,
            ) xev.CallbackAction {
                const lua = lu.getLua(loop);
                const top = if (builtin.mode == .Debug) lua.getTop();
                defer if (builtin.mode == .Debug) std.debug.assert(top == lua.getTop()); // stack must be unchanged
                const len = r catch |err| {
                    lua.unref(zlua.registry_index, handleFromPtr(ud)); // release the reference to the server
                    if (err == error.Canceled) return .disarm;
                    _ = lua.pushFString("UDP read error! %s", .{@errorName(err).ptr});
                    lu.reportError(lua);
                    return .disarm;
                };
                // runs server:dispatch(addr, bytes)
                _ = lua.rawGetIndex(zlua.registry_index, handleFromPtr(ud));
                _ = lua.getMetaField(-1, "dispatch") catch unreachable;
                lua.rotate(-2, 1);
                osc.pushAddress(lua, .string, addr);
                _ = lua.pushString(b.slice[0..len]);
                lu.doCall(lua, 3, 0) catch lu.reportError(lua);
                // go again
                udp.read(loop, c, s, b, anyopaque, ud, @This().callback);
                return .disarm;
            }
        }.callback,
    );
}

/// stops the OSC Server object on top of the stack
/// stack effect: unchanged
fn stop(l: *Lua) !void {
    const server = try l.toUserdata(Server, -1);
    l.pushValue(-1);
    const handle = try l.ref(zlua.registry_index);
    server.c_c = .{
        .op = .{
            .cancel = .{ .c = &server.c },
        },
        .userdata = ptrFromHandle(handle),
        .callback = lu.unrefCallback,
    };
    const seamstress = lu.getSeamstress(l);
    seamstress.loop.add(&server.c_c);
}

/// should only be called by seamstress's internal quit handler
/// asserts that running is true and cancels the read callback
/// panics on failure
fn __cancel(l: *Lua) i32 {
    const server = l.checkUserdata(Server, 1, "seamstress.osc.Server");
    if (!server.running) return 0;
    server.running = false;
    l.pushValue(1);
    stop(l) catch std.debug.panic("error stopping seamstress.osc.Server!", .{});
    return 0;
}

/// closes the socket
fn __gc(l: *Lua) i32 {
    const server = l.checkUserdata(Server, 1, "seamstress.osc.Server");
    std.posix.close(server.udp.fd);
    std.posix.close(server.socket);
    return 0;
}

/// function seamstress.osc.Server:dispatch(addr, msg, time)
/// if there is a matching client, use that to respond
/// otherwise, use the default client
fn dispatch(l: *Lua) i32 {
    const time_exists = l.typeOf(4) != .none;
    l.checkType(1, .userdata); // server
    const addr = osc.parseAddress(l, 2) catch l.typeError(2, "address"); // address
    osc.pushAddress(l, .string, addr); // use the address as a key to the server
    switch (l.getTable(1)) {
        .userdata => { // found a matching client
            // call client:dispatch(bytes)
            _ = l.getMetaField(-1, "dispatch") catch unreachable;
            l.rotate(-2, 1);
            l.pushValue(3); // message
            if (time_exists) {
                l.pushNil();
                l.pushValue(4);
                l.call(.{ .args = 4 });
            } else l.call(.{ .args = 2 });
        },
        .none, .nil => { // no matching client found, use default
            _ = l.getField(1, "default");
            // call client:dispatch(bytes, addr)
            _ = l.getMetaField(-1, "dispatch") catch unreachable;
            l.rotate(-2, 1);
            l.pushValue(3); // message
            l.pushValue(2); // address
            if (time_exists) {
                l.pushValue(4);
                l.call(.{ .args = 4 });
            } else l.call(.{ .args = 3 });
        },
        else => l.typeError(1, "seamstress.osc.Server"),
    }
    return 0;
}

fn new(l: *Lua) i32 {
    const @"i64" = l.checkInteger(1); // port number
    const is_client = switch (l.typeOf(2)) { // did we pass a default client?
        .table, .userdata => true, // yes
        .nil, .none => false, // no
        else => l.typeError(2, "seamstress.osc.Client"),
    };
    const port = std.math.cast(u16, @"i64") orelse l.argError(1, "port number must be between 0 and 65535");
    const server: *Server = l.newUserdata(Server, 1);
    server.* = .{
        .addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port),
        .udp = xev.UDP.init(server.addr) catch l.raiseErrorStr("unable to open UDP socket at port %d", .{port}),
        .socket = std.posix.socket(server.addr.any.family, std.posix.SOCK.DGRAM, 0) catch l.raiseErrorStr("unable to open UDP socket for sending!", .{}),
    };

    std.posix.setsockopt(server.socket, std.posix.SOL.SOCKET, if (builtin.os.tag == .windows) std.posix.SO.REUSE_MULTICASTPORT else std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch
        l.raiseErrorStr("unable to set socket option: reuse port", .{});
    std.posix.setsockopt(server.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch
        l.raiseErrorStr("unable to set socket option: reuse addr", .{});

    server.udp.bind(server.addr) catch |err| l.raiseErrorStr("unable to bind to UDP socket at port %d; %s", .{ port, @errorName(err).ptr });
    l.newTable(); // our uservalue table
    if (is_client) switch (l.typeOf(2)) { // we passed a default client
        .userdata => { // as a seamstress.osc.Client
            _ = l.checkUserdata(@import("client.zig"), 2, "seamstress.osc.Client");
            l.pushValue(2);
            l.setField(-2, "default");
        },
        .table => { // we passed it as a table, so create the client by calling Client on it
            lu.load(l, "seamstress.osc.Client");
            l.pushValue(2);
            lu.doCall(l, 1, 1) catch l.typeError(2, "seamstress.osc.Client");
            l.setField(-2, "default");
        },
        else => unreachable,
    } else { // create a default Client
        lu.load(l, "seamstress.osc.Client");
        l.call(.{ .results = 1 });
        l.setField(-2, "default");
    }
    l.setUserValue(-2, 1) catch unreachable;
    _ = l.getMetatableRegistry("seamstress.osc.Server");
    l.setMetatable(-2); // set the metatable
    run(l) catch {
        l.raiseErrorStr("unable to start receiving UDP at port %d", .{port});
    }; // start the server
    return 1;
}

/// signature: server:send(addr, message)
fn send(l: *Lua) i32 {
    const server = l.checkUserdata(Server, 1, "seamstress.osc.Server"); // self
    const addr: std.net.Address = switch (l.typeOf(2)) {
        .number, .string, .table => osc.parseAddress(l, 2) catch l.typeError(2, "address"), // address
        .userdata => client: { // if the second argument is a userdata, it must be a client, and we'll use the client's address
            const client = l.checkUserdata(@import("client.zig"), 2, "seamstress.osc.Client");
            break :client client.addr;
        },
        else => l.typeError(2, "address or seamstress.osc.Client"),
    };
    // grab the message and its path
    const message: *z.Message.Builder, const path: []const u8 = switch (l.typeOf(3)) {
        .table => msg: { // if passed as a table, convert it to a Message
            lu.load(l, "seamstress.osc.Message");
            l.pushValue(3);
            lu.doCall(l, 1, 1) catch
                l.typeError(3, "seamstress.osc.Message");
            _ = l.getUserValue(-1, 1) catch unreachable;
            const path = l.toString(-1) catch l.argError(3, "seamstress.osc.Message is missing a path");
            l.pop(1);
            break :msg .{ l.toUserdata(z.Message.Builder, -1) catch unreachable, path };
        },
        .userdata => msg: { // already a Message
            const message = l.checkUserdata(z.Message.Builder, 3, "seamstress.osc.Message");
            _ = l.getUserValue(-1, 1) catch unreachable;
            const path = l.toString(-1) catch l.argError(3, "seamstress.osc.Message is missing a path");
            l.pop(1);
            break :msg .{ message, path };
        },
        else => l.typeError(3, "seamstress.osc.Message"),
    };
    // get the bytes
    const msg = message.commit(lu.allocator(l), path) catch l.raiseErrorStr("out of memory!", .{});
    // defer if (l.typeOf(3) == .table) message.deinit();
    defer msg.unref();
    // send it!
    server.sendOSCBytes(addr, msg.toBytes()) catch |err| {
        msg.unref();
        osc.pushAddress(l, .string, addr);
        const addr_str = l.toString(-1) catch unreachable;
        defer l.raiseErrorStr("unable to send OSC message to %s over UDP! %s", .{
            addr_str.ptr,
            @errorName(err).ptr,
        });
    };
    return 0;
}

fn __index(l: *Lua) i32 {
    const server = l.checkUserdata(Server, 1, "seamstress.osc.Server");
    _ = l.pushStringZ("running");
    _ = l.pushStringZ("address");
    if (l.compare(-1, 2, .eq)) { // k == "address"
        osc.pushAddress(l, .table, server.addr);
        return 1;
    }
    if (l.compare(-2, 2, .eq)) { // k == "running"
        l.pushBoolean(server.running);
        return 1;
    }
    l.getMetatable(1) catch unreachable;
    l.pushValue(2); // check the metatable
    switch (l.getTable(-2)) {
        .nil, .none => { // it didn't have it
            _ = l.getUserValue(1, 1) catch unreachable; // so check the uservalue table
            l.pushValue(2);
            return switch (l.getTable(-2)) {
                .nil, .none => 0,
                else => 1,
            };
        },
        else => return 1,
    }
}

fn __newindex(l: *Lua) i32 {
    _ = l.pushStringZ("running");
    if (l.compare(2, -1, .eq)) return ret: { // k == "running"
        const server = l.checkUserdata(Server, 1, "seamstress.osc.Server");
        const running = l.toBoolean(3);
        if (server.running != running) {
            server.running = running;
            l.pushValue(1);
            const err = if (running) run(l) else stop(l);
            err catch |e|
                l.raiseErrorStr("error while setting server's running status! %s", .{@errorName(e).ptr});
        }
        break :ret 0;
    };
    _ = l.pushStringZ("address");
    if (l.compare(2, -1, .eq)) { // k == "address"
        l.raiseErrorStr("unable to change address after creation; close and reopen", .{});
    }
    _ = l.pushStringZ("default"); // k == "default"
    if (l.compare(2, -1, .eq)) return ret: {
        _ = l.checkUserdata(@import("client.zig"), 3, "seamstress.osc.Client"); // v must be a Client
        _ = l.getUserValue(1, 1) catch unreachable; // this is t
        l.pushValue(2); // k
        l.pushValue(3); // v
        l.setTable(-3); // t[k] = v
        break :ret 0;
    };
    if (l.typeOf(2) == .string) blk: { // type(k) == "string"
        _ = osc.parseAddress(l, 2) catch break :blk; // is the string an address?
        _ = l.checkUserdata(@import("client.zig"), 3, "seamstress.osc.Client"); // if so, are we assigning a Client?
        _ = l.getUserValue(1, 1) catch unreachable; // great, do the assignment, this is t
        l.pushValue(2); // k
        l.pushValue(3); // v
        l.setTable(-3); // t[k] = v
        return 0;
    }
    l.typeError(2, "\"default\", \"running\" or IP string expected");
}

fn __pairs(l: *Lua) i32 {
    const iterator = struct {
        fn f(lua: *Lua) i32 {
            _ = lua.pushStringZ("default");
            const default_str = lua.getTop();
            while (true) {
                lua.pushValue(2);
                if (!lua.next(1)) return 0;
                if (lua.compare(default_str, -2, .eq)) {
                    lua.pop(1); // remove val
                    lua.replace(2); // replace key
                    continue;
                }
                if (!lua.isUserdata(-1)) {
                    lua.pop(1); // remove val
                    lua.replace(2); // replace key
                    continue;
                }
                if (!lua.isString(-2)) {
                    lua.pop(1); // remove val
                    lua.replace(2); //replace key
                    continue;
                }
                return 2;
            }
        }
    }.f;
    // return iterator, tbl, nil
    l.pushFunction(zlua.wrap(iterator));
    _ = l.getUserValue(1, 1) catch unreachable;
    l.pushNil();
    return 3;
}

const z = @import("zosc");
const osc = @import("../osc.zig");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const xev = @import("xev");
const std = @import("std");
const lu = @import("../lua_util.zig");
const builtin = @import("builtin");
