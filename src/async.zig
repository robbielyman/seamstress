/// A `Promise` is an opaque handle to an operation
/// which will be executed on the event loop.
/// `Promise` objects always execute and cannot be canceled or altered once created.
const Promise = @This();

status: enum { waiting, pending, fulfilled, rejected },
c: xev.Completion = .{},
c_c: xev.Completion = .{},
data: union(enum) {
    timer: xev.Timer, // for use with lua-generated promises
    @"async": xev.Async, // for use with other modules
},

pub const Which = enum { @"async", promise };

const handleFromPtr = lu.handleFromPtr;
const ptrFromHandle = lu.ptrFromHandle;

pub fn register(comptime which: Which) fn (*Lua) i32 {
    return switch (which) {
        .@"async" => struct {
            fn f(l: *Lua) i32 {
                l.newTable(); // t
                blk: {
                    l.newMetatable("seamstress.async") catch break :blk; // new metatable
                    _ = l.pushStringZ("__call"); // __call
                    l.pushFunction(zlua.wrap(@"async")); // fn
                    l.setTable(-3); // metatable.__call = fn
                }
                l.setMetatable(-2); // setmetatable(t, metatable)

                _ = l.pushStringZ("Promise"); // Promise
                lu.load(l, "seamstress.async.Promise"); // s
                l.setTable(-3); // t.Promise = s
                return 1;
            }
        }.f,
        .promise => struct {
            fn f(l: *Lua) i32 {
                blk: {
                    l.newMetatable("seamstress.async.Promise") catch break :blk; // new metatable
                    l.setFuncs(&.{
                        .{ .name = "anon", .func = zlua.wrap(anon) },
                        .{ .name = "catch", .func = zlua.wrap(@"catch") },
                        .{ .name = "finally", .func = zlua.wrap(finally) },
                        .{ .name = "await", .func = zlua.wrap(@"await") },
                        .{ .name = "__cancel", .func = zlua.wrap(__cancel) },
                    }, 0); // register functions
                    _ = l.pushStringZ("__index"); // __index
                    l.pushValue(-2); // metatable
                    l.setTable(-3); // metatable.__index = metatable
                }
                l.pop(1); // pop metatable

                l.createTable(0, 3); // t
                l.createTable(0, 1); // its metatable
                _ = l.pushStringZ("__call"); // __call
                l.pushFunction(zlua.wrap(new)); // function
                l.setTable(-3); // metatable.__call = function
                l.setMetatable(-2); // setmetatable(t, metatable)
                const how: [3]How = .{ .all, .any, .race };
                inline for (how) |h| {
                    _ = l.pushStringZ(@tagName(h)); // s
                    l.pushFunction(zlua.wrap(multi(h))); // f
                    l.setTable(-3); // t[s] = f
                }
                return 1;
            }
        }.f,
    };
}

fn __cancel(l: *Lua) i32 {
    const promise = l.checkUserdata(Promise, 1, "seamstress.async.Promise");
    l.pushValue(1);
    const handle = l.ref(zlua.registry_index) catch
        std.debug.panic("unable to register Promise!", .{});
    promise.c_c = .{
        .op = .{ .cancel = .{ .c = &promise.c } },
        .userdata = ptrFromHandle(handle),
        .callback = lu.unrefCallback,
    };
    const seamstress = lu.getSeamstress(l);
    seamstress.loop.add(&promise.c_c);
    return 0;
}

const How = enum { all, any, race };

/// TODO: refactor
fn multi(comptime how: How) fn (*Lua) i32 {
    return struct {
        fn f(l: *Lua) i32 {
            const p = oneFromMany(l); // create Promise
            l.pushValue(-1); // push it again
            const h = l.ref(zlua.registry_index) catch |err|
                l.raiseErrorStr("unable to register Promise! %s", .{@errorName(err).ptr});
            const s = lu.getSeamstress(l);
            p.data.timer.run(&s.loop, &p.c, 2, anyopaque, ptrFromHandle(h), struct {
                fn callback(
                    ptr: ?*anyopaque,
                    loop: *xev.Loop,
                    c: *xev.Completion,
                    r: xev.Timer.RunError!void,
                ) xev.CallbackAction {
                    const handle = handleFromPtr(ptr);
                    const lua = lu.getLua(loop);
                    _ = r catch |err| {
                        lua.unref(zlua.registry_index, handle);
                        _ = lua.pushFString("unexpected timer error! %s", .{@errorName(err).ptr});
                        lu.reportError(lua);
                        return .disarm;
                    };
                    _ = lua.rawGetIndex(zlua.registry_index, handle); // push the Promise onto the stack
                    const promise = lua.toUserdata(Promise, -1) catch unreachable;
                    _ = lua.getUserValue(-1, 1) catch unreachable; // get the thread
                    const stack = lua.toThread(-1) catch unreachable;
                    lua.pop(1); // pop the stack
                    _ = lua.getUserValue(-1, 2) catch unreachable;
                    const n = lua.toInteger(-1) catch unreachable; // get the number of associated Promises
                    lua.pop(1); // pop n
                    var i: i32 = 1;
                    // special case: no promises passed in
                    if (n == 0) {
                        switch (how) {
                            .any => promise.status = .rejected, // we reject
                            .all => promise.status = .fulfilled, // we fulfill
                            .race => promise.status = .fulfilled, // TODO: does this match expectations?
                        }
                        lua.unref(zlua.registry_index, handle); // the promise is settled, and we don't need the reference
                        promise.data.timer.deinit();
                        return .disarm;
                    }
                    var all_of_em = true;
                    while (i <= n) : (i += 1) {
                        _ = lua.getUserValue(-1, 2 + i) catch unreachable; // grab the ith Promise
                        const other = lua.toUserdata(Promise, -1) catch unreachable;
                        switch (other.status) {
                            .fulfilled => switch (how) {
                                .any, .race => {
                                    promise.status = .fulfilled; // we fulfill
                                    _ = lua.getUserValue(-1, 1) catch unreachable;
                                    const thread = lua.toThread(-1) catch unreachable;
                                    lua.pop(2);
                                    thread.xMove(stack, thread.getTop()); // pull from its stack
                                    stack.remove(2); // remove the reject handler
                                    var res: i32 = undefined;
                                    _ = stack.resumeThread(lua, stack.getTop() - 1, &res) catch unreachable; // our resolve handler never fails
                                    break;
                                },
                                .all => {}, // do nothing yet
                            },
                            .rejected => switch (how) {
                                .any => {}, // do nothing yet
                                .all, .race => {
                                    promise.status = .rejected; // we reject
                                    _ = lua.getUserValue(-1, 1) catch unreachable; // grab the other Promise's stack
                                    const thread = lua.toThread(-1) catch unreachable;
                                    lua.pop(2);
                                    thread.xMove(stack, thread.getTop()); // pull from its stack
                                    stack.remove(1); // remove the resolve handler
                                    var res: i32 = undefined;
                                    _ = stack.resumeThread(lua, stack.getTop() - 1, &res) catch {}; // should always error
                                    break;
                                },
                            },
                            else => all_of_em = false,
                        }
                        lua.pop(1); // pop it
                    } else {
                        // we didn't break
                        if (all_of_em) {
                            promise.status = if (how == .all) .fulfilled else .rejected;
                            var j: i32 = 1;
                            while (j <= n) : (j += 1) {
                                _ = lua.getUserValue(-1, 2 + j) catch unreachable; // grab the jth Promise
                                _ = lua.getUserValue(-1, 1) catch unreachable; // grab the other Promise's stack
                                const thread = lua.toThread(-1) catch unreachable;
                                lua.pop(2);
                                thread.xMove(stack, if (promise.status == .fulfilled) thread.getTop() else 1); // pull from it
                            }
                            if (promise.status == .rejected) {
                                var k: i32 = 3; // the first two values are functions
                                const m = stack.getTop();
                                stack.newTable();
                                while (k <= m) : (k += 1) {
                                    stack.pushValue(3); // push the 3rd value
                                    stack.setIndex(-2, k - 2); // assign it to the table
                                    stack.remove(3); // remove it from the stack
                                }
                            }
                            stack.remove(if (promise.status == .fulfilled) 2 else 1); // remove the handler
                            var res: i32 = undefined;
                            _ = stack.resumeThread(lua, stack.getTop() - 1, &res) catch if (promise.status == .fulfilled) unreachable else {};
                            // the promise is sttled and we don't need the reference
                            lua.unref(zlua.registry_index, handle);
                            promise.data.timer.deinit();
                            return .disarm;
                        }
                        // we're not done, so go again
                        promise.data.timer.run(loop, c, 2, anyopaque, ptr, @This().callback); // try again in 2ms
                        return .disarm;
                    }
                    // if we got here, the promise is settled, and we don't need the reference
                    lua.unref(zlua.registry_index, handle);
                    promise.data.timer.deinit();
                    return .disarm;
                }
            }.callback); // add to the event loop
            return 1; // return the new promise
        }
    }.f;
}

/// creates a Promise that references all the Promises passed in
fn oneFromMany(l: *Lua) *Promise {
    const n = l.getTop(); // how many Promises?
    var i: i32 = 1;
    const p: *Promise = l.newUserdata(Promise, 2 + n); // thread, n, ...
    _ = l.getMetatableRegistry("seamstress.async.Promise"); // metatable
    l.setMetatable(-2); // setmetatable(promise, metatable)
    const stack = l.newThread(); // new thread
    stack.pushFunction(zlua.wrap(struct {
        /// default promise resolution handler
        fn noOp(lua: *Lua) i32 {
            return lua.getTop();
        }
    }.noOp));
    stack.pushFunction(zlua.wrap(struct {
        /// throws an error
        fn throw(lua: *Lua) i32 {
            lua.raiseError();
            return 0;
        }
    }.throw));
    l.setUserValue(-2, 1) catch unreachable; // assign stack to Promise
    l.pushInteger(n); // push n
    l.setUserValue(-2, 2) catch unreachable; // assign to Promise
    while (i <= n) : (i += 1) {
        _ = l.checkUserdata(Promise, i, "seamstress.async.Promise");
        l.pushValue(i); // push the other Promise
        l.setUserValue(-2, 2 + i) catch unreachable; // assign to our Promise
    }
    p.* = .{
        .status = .pending,
        .data = .{ .timer = xev.Timer.init() catch |err|
            l.raiseErrorStr("unable to create timer! %s", .{@errorName(err)}) },
    };
    return p;
}

/// Executes its function argument asynchronously
fn new(l: *Lua) i32 {
    l.remove(1); // we don't need the metatable
    const n = l.getTop(); // the function and its arguments
    const thread = l.newThread(); // create a thread
    l.rotate(-n - 1, 1); // put it at the bottom of the stack
    l.xMove(thread, n); // move the function and its arguments to the thread
    const promise: *Promise = l.newUserdata(Promise, 2); // Promise
    _ = l.getMetatableRegistry("seamstress.async.Promise"); // metatable
    l.setMetatable(-2); // setmetatable(promise, metatable)
    l.rotate(-2, 1); // put the Promise below the thread
    l.setUserValue(-2, 1) catch unreachable; // assign the thread to the Promise
    l.newTable();
    l.setUserValue(-2, 2) catch unreachable; // the table of depending promises
    promise.* = .{
        .status = .waiting,
        .data = .{ .timer = xev.Timer.init() catch |err|
            l.raiseErorStr("error creating new Promise: %s", .{@errorName(err).ptr}) },
    };
    l.pushValue(-1); // push the Promise
    const handle = l.ref(zlua.registry_index) catch |err|
        l.raiseErrorStr("unable to register Promise! %s", .{@errorName(err).ptr}); // ref pops
    const s = lu.getSeamstress(l);
    promise.data.timer.run(&s.loop, &promise.c, 2, anyopaque, ptrFromHandle(handle), settle); // add to the event loop
    return 1;
}

/// Creates an asynchronous function with body `f`.
/// Internally `f` is executed on a cooutine,
/// so calling `coroutine.yield()` and awaiting `Promise` objects
/// from within `f` is valid.
fn @"async"(lua: *Lua) i32 {
    lu.checkCallable(lua, 2);
    lua.pushClosure(zlua.wrap(struct {
        /// calls an async function, returning a new Promise
        fn f(l: *Lua) i32 {
            const i = Lua.upvalueIndex(1); // the function we passed into `seamstress.async`
            const n = l.getTop(); // the number of arguments to the function
            const p: *Promise = l.newUserdata(Promise, 2); // create a Promise
            _ = l.getMetatableRegistry("seamstress.async.Promise"); // grab the metatable
            l.setMetatable(-2); // setmetatable(promise, metatable);
            const new_l = l.newThread(); // create a thread
            l.pushValue(i); // push the function
            var j: i32 = 1;
            while (j <= n) : (j += 1) {
                l.pushValue(j); // for each function argument, push it onto the stack
            }
            l.xMove(new_l, n + 1); // move the function and its arguments to the new thread
            l.setUserValue(-2, 1) catch unreachable; // assign the thread to the Promise
            p.* = .{
                .status = .waiting,
                .data = .{
                    .timer = xev.Timer.init() catch |err|
                        l.raiseErrorStr("error creating new Promise: %s", .{@errorName(err).ptr}),
                },
            };
            l.newTable();
            l.setUserValue(-2, 2) catch unreachable; // the table of depending promises
            l.pushValue(-1); // push the Promise again
            const handle = l.ref(zlua.registry_index) catch |err| l.raiseErrorStr("unable to register Promise! %s", .{@errorName(err).ptr}); // ref pops
            const s = lu.getSeamstress(l);
            p.data.timer.run(&s.loop, &p.c, 2, anyopaque, ptrFromHandle(handle), settle); // add to the event loop
            return 1; // return Promise
        }
    }.f), 1);
    return 1;
}

/// attempts to resolve a Promise by resuming its coroutine
fn settle(ptr: ?*anyopaque, loop: *xev.Loop, c: *xev.Completion, r: xev.Timer.RunError!void) xev.CallbackAction {
    const l = lu.getLua(loop);
    const handle = handleFromPtr(ptr);
    _ = r catch |err| {
        l.unref(zlua.registry_index, handle);
        _ = l.pushFString("unexpected timer error! %s", .{@errorName(err).ptr});
        lu.reportError(l);
        return .disarm;
    };
    _ = l.rawGetIndex(zlua.registry_index, handle); // push the Promise onto the stack
    const promise = l.toUserdata(Promise, -1) catch unreachable;
    _ = l.getUserValue(-1, 1) catch unreachable; // get the thread
    const thread = l.toThread(-1) catch unreachable;
    defer l.pop(2); // stack effect should be 0
    var res: i32 = undefined;
    if (thread.resumeThread(l, switch (promise.status) {
        .waiting => thread.getTop() - 1, // pass the arguments to the function
        .pending => 0, // otherwise nothing to pass
        else => unreachable,
    }, &res)) |result| {
        switch (result) {
            .ok => {
                promise.status = .fulfilled; // the function returned!
                promise.data.timer.deinit(); // the timer is done
            },
            .yield => {
                promise.status = .pending; // the function yielded
                thread.pop(res); // remove the values it passed to yield
                promise.data.timer.run(loop, c, 2, anyopaque, ptr, settle); // try again in 2ms
                return .disarm;
            },
        }
    } else |_| {
        promise.status = .rejected; // the function had an error
        promise.data.timer.deinit();
    }
    l.unref(zlua.registry_index, handle); // if we got here, the promise settled, so we don't need the reference
    _ = l.getUserValue(-2, 2) catch unreachable; // the table of depending promises
    l.pushNil(); // start the iteration
    while (l.next(-2)) {
        const other_promise = l.toUserdata(Promise, -1) catch unreachable;
        other_promise.data.@"async".notify() catch |err| {
            _ = l.pushFString("unexpected wakeup error! %s", .{@errorName(err).ptr});
            lu.reportError(l);
        };
        l.pop(1); // leave key for next call to next()
    }
    l.pop(1); // pop the table
    return .disarm;
}

fn anonCallback(ptr: ?*anyopaque, loop: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
    const l = lu.getLua(loop);
    const handle = handleFromPtr(ptr);
    _ = r catch |err| {
        l.unref(zlua.registry_index, handle);
        _ = l.pushFString("unexpected async error! %s", .{@errorName(err).ptr});
        lu.reportError(l);
        return .disarm;
    };
    _ = l.rawGetIndex(zlua.registry_index, handle); // push the Promise
    const promise = l.toUserdata(Promise, -1) catch unreachable;
    _ = l.getUserValue(-1, 3) catch unreachable; // push the other Promise
    const other = l.toUserdata(Promise, -1) catch unreachable;
    _ = l.getUserValue(-2, 1) catch unreachable; // get our stack
    const thread = l.toThread(-1) catch unreachable;
    // our stack has both the resolve and reject functions on it
    // let's pop the right one
    thread.remove(switch (other.status) {
        .waiting, .pending => unreachable,
        .fulfilled => 2,
        .rejected => 1,
    });
    _ = l.getUserValue(-2, 1) catch unreachable; // get the other Promise's stack
    const other_thread = l.toThread(-1) catch unreachable;
    other_thread.xMove(thread, other_thread.getTop());
    // copyStack(other_thread, thread); // move return values from the other stack to ours
    l.pop(3); // remove stacks and Promises except for ours
    l.pushNil(); // we no longer need the dependant Promise, so let's release the reference to it
    l.setUserValue(-2, 3) catch unreachable;
    l.pop(1); // now pop the last promise
    promise.data.@"async".deinit(); // we're done with the Async, so let's ditch it.
    promise.data = .{ .timer = xev.Timer.init() catch |err| {
        l.unref(zlua.registry_index, handle);
        l.pushFString("error creating new timer: %s", .{@errorName(err).ptr});
        lu.reportError(l);
        return .disarm;
    } };
    // we're just waiting to settle!
    promise.data.timer.run(loop, &promise.c, 2, anyopaque, ptrFromHandle(handle), settle);
    return .disarm;
}

pub fn waitForLua(l: *Lua, waiting_on: union(enum) {
    function_with_num_args: i32,
    async_function_with_num_args: i32,
    promise: void,
}) !void {
    const builtin = @import("builtin");
    const a = try xev.Async.init();
    const top = if (builtin.mode == .Debug) blk: {
        const top = l.getTop();
        const num_args: i32 = switch (waiting_on) {
            .promise => 0,
            .function_with_num_args, .async_function_with_num_args => |n| n,
        };
        std.debug.assert(top >= num_args + 2 + 1);
        break :blk top;
    };
    switch (waiting_on) {
        .promise => l.rotate(-3, 2), // stack is now: closure closure promise
        .function_with_num_args => |num_args| {
            lu.load(l, "seamstress.async.Promise");
            l.rotate(-num_args - 4, 3); // stack is now: closure closure Promise function ...
            try lu.doCall(l, num_args + 1, 1); // stack is now closure closure returned_promise
        },
        .async_function_with_num_args => |num_args| {
            l.rotate(-num_args - 3, 3); // stack is now: closure closure function ...
            try lu.doCall(l, num_args, 1); // stack is now closure closure returned_promise
        },
    }
    const promise: *Promise = l.newUserdata(Promise, 3);
    l.pushValue(-1); // copy it
    const handle = try l.ref(zlua.registry_index); // ref pops
    defer if (builtin.mode == .Debug) {
        const num_args: i32 = switch (waiting_on) {
            .promise => 0,
            .function_with_num_args, .async_function_with_num_args => |n| n,
        };
        std.debug.assert(l.getTop() + num_args + 2 == top);
    };
    const thread = l.newThread();
    l.rotate(-5, -2); // stack is now: returned_promise new_promise thread closure closure
    l.xMove(thread, 2); // pops closures
    l.setUserValue(-2, 1) catch unreachable; // assign the thread to the promise; pops
    promise.* = .{
        .status = .waiting,
        .data = .{ .@"async" = a },
    };
    _ = l.getUserValue(-2, 2) catch unreachable; // get the table of dependent promises
    l.len(-1); // get its length
    const len = l.toInteger(-1) catch unreachable;
    l.pop(1);
    l.pushValue(-2); // copy new_promise
    l.setIndex(-2, len + 1); // assign as dependent promise
    l.pop(1); // pop the table
    l.rotate(-2, 1); // stack is now new_promise returned_promise
    l.setUserValue(-2, 3) catch unreachable;
    l.newTable();
    l.setUserValue(-2, 2) catch unreachable; // no depending promises to start with
    const s = lu.getSeamstress(l);
    promise.data.@"async".wait(&s.loop, &promise.c, anyopaque, ptrFromHandle(handle), Promise.anonCallback);
    // leave new_promise on the stack
}

/// default promise rejection handler
fn throw(lua: *Lua) i32 {
    lua.raiseError(); // throws an error
    return 0;
}

/// Sequences actions to take after the resolution of `self`.
/// The name is chosen for expressions like "I shall return anon":
/// in JavaScript the same functionality is provided by a function named "then",
/// which is a reserved word in Lua.
/// Values (or errors) returned by the `Promise` are passed as arguments to the appropriate function.
fn anon(l: *Lua) i32 {
    const t3 = l.typeOf(3);
    const other = l.checkUserdata(Promise, 1, "seamstress.async.Promise"); // self should be a Promise
    const promise: *Promise = l.newUserdata(Promise, 3); // create Promise
    l.pushValue(-1); // push the promise
    const handle = l.ref(zlua.registry_index) catch |err|
        l.raiseErrorStr("unable to register Promise! %s", .{@errorName(err).ptr}); // ref pops
    _ = l.getMetatableRegistry("seamstress.async.Promise"); // metatable
    l.setMetatable(-2); // setmetatable(promise, metatable)
    const new_l = l.newThread();
    l.setUserValue(-2, 1) catch unreachable;
    lu.checkCallable(l, 2); // second argument should be callable
    l.pushValue(2);
    if (t3 != .nil and t3 != .none) {
        lu.checkCallable(l, 3); // third argument should be nil or callable
        l.pushValue(3);
    } else {
        l.pushFunction(zlua.wrap(throw));
    }
    const s = lu.getSeamstress(l);
    switch (other.status) {
        .fulfilled, .rejected => |which| {
            l.remove(if (which == .fulfilled) -1 else -2); // pop the appropriate handler
            l.xMove(new_l, 1); // move the other handler to the new thread
            _ = l.getUserValue(1, 1) catch unreachable; // get the other Promise's stack
            const thread = l.toThread(-1) catch unreachable;
            thread.xMove(new_l, thread.getTop());
            // copyStack(thread, new_l); // copy the contents of the Promise's stack over
            l.pop(1); // pop the thread
            l.newTable();
            l.setUserValue(-2, 2) catch unreachable; // assign the table to the Promise
            // we skip assigning the previous Promise to us so that it can be garbage collected faster
            promise.* = .{
                .status = .waiting,
                .data = .{ .timer = xev.Timer.init() catch |err|
                    l.raiseErrorStr("error creating new timer: %s", .{@errorName(err).ptr}) },
            };
            // we're just waiting to settle!
            promise.data.timer.run(&s.loop, &promise.c, 2, anyopaque, ptrFromHandle(handle), settle);
        },
        .waiting, .pending => {
            l.xMove(new_l, 2); // move both functions to the new thread

            l.newTable();
            l.setUserValue(-2, 2) catch unreachable; // assign the table to the Promise
            _ = l.getUserValue(1, 2) catch unreachable; // get previous Promise's table
            const length = l.rawLen(-1);
            l.pushValue(-2); // new promise
            l.setIndex(-2, @intCast(length + 1)); // add to list of dependent promises
            l.pop(1); // pop the list
            l.pushValue(1); // previous Promise
            l.setUserValue(-2, 3) catch unreachable; // assign previous Promise to us
            promise.* = .{
                .status = .waiting,
                .data = .{ .@"async" = xev.Async.init() catch |err|
                    l.raiseErrorStr("error creating new async: %s", .{@errorName(err).ptr}) },
            };
            promise.data.@"async".wait(&s.loop, &promise.c, anyopaque, ptrFromHandle(handle), anonCallback);
        },
    }
    return 1; // return the new promise
}

fn copyStack(from: *Lua, to: *Lua) void {
    const n = from.getTop();
    var idx: i32 = 1;
    while (idx <= n) : (idx += 1) {
        from.copy(idx, n + 1);
        from.xMove(to, 1);
    }
}

/// Convenient alias for `self:anon(function(...) return ... end, f)`.
fn @"catch"(l: *Lua) i32 {
    _ = l.checkUserdata(Promise, 1, "seamstress.async.Promise"); // self is a Promise
    l.pushFunction(zlua.wrap(anon)); // we're going to call self:anon
    l.pushValue(1); // on self
    l.pushFunction(zlua.wrap(struct {
        /// default promise resolution handler
        fn noOp(lua: *Lua) i32 {
            return lua.getTop();
        }
    }.noOp));
    lu.checkCallable(l, 2); // the second argument should be callable
    l.pushValue(2);
    l.call(.{ .args = 3, .results = 1 }); // call self:anon
    return 1; // return the new Promise
}

/// Convenient alias for `self:anon(f, f)`.
fn finally(l: *Lua) i32 {
    _ = l.checkUserdata(Promise, 1, "seamstress.async.Promise"); // self is a Promise
    l.pushFunction(zlua.wrap(anon)); // we're going to call self:anon
    l.pushValue(1); // on self
    lu.checkCallable(l, 2); // the second argument should be callable
    l.pushValue(2); // push it
    l.pushValue(2); // push it again
    l.call(.{ .args = 3, .results = 1 }); // call self:anon
    return 1; // return the new Promise
}

/// Waits on the successful completion of a `Promise` and returns its return values.
/// Because awaiting a promise yields execution, `await` may only be called from within a coroutine
/// or asynchronous context like an async function or a `Promise`.
fn @"await"(l: *Lua) i32 {
    _ = l.checkUserdata(Promise, 1, "seamstress.async.Promise"); // we're awaiting a Promise
    if (!l.isYieldable()) l.raiseErrorStr("cannot await a Promise outside of an async context (i.e. a coroutine or an async function)", .{}); // we'd better be able to yield
    l.yieldCont(0, 0, zlua.wrap(struct {
        fn @"continue"(lua: *Lua, _: zlua.Status, _: zlua.Context) i32 {
            const promise: *Promise = lua.checkUserdata(Promise, 1, "seamstress.async.Promise"); // we're awaiting a Promise
            switch (promise.status) {
                .waiting, .pending => {
                    lua.yieldCont(0, 0, zlua.wrap(@This().@"continue")); // we'll keep waiting
                },
                .fulfilled, .rejected => {
                    _ = lua.getUserValue(1, 1) catch unreachable; // get the Promise's stack
                    const stack = lua.toThread(-1) catch unreachable;
                    lua.pop(1); // pop the stack
                    const n = stack.getTop(); // move to our stack
                    stack.xMove(lua, n);
                    if (promise.status == .rejected) lua.raiseError();
                    return n; // return the values
                },
            }
        }
    }.@"continue")); // 'cause we're gonna
}

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const lu = @import("lua_util.zig");
const xev = @import("xev");
