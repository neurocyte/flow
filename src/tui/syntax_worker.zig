const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const syntax = @import("syntax");
const Buffer = @import("Buffer");
const tracy = @import("tracy");

const module_name = @typeName(@This());

pub const Job = usize;

var last_job: Job = 0;

pub fn create() !Worker {
    return .{ .pid = try Process.create() };
}

pub const Worker = struct {
    pid: ?tp.pid,

    pub fn deinit(self: *@This()) void {
        if (self.pid) |pid| {
            pid.send(.{"shutdown"}) catch {};
            pid.deinit();
            self.pid = null;
        }
    }

    pub fn parse(self: @This(), parser: []const u8, text: *Buffer.SharedText, query_cache: *syntax.QueryCache) error{Exit}!Job {
        errdefer text.release();
        const pid = self.pid orelse return error.Exit;
        last_job += 1;
        try pid.send(.{ "P", last_job, parser, @intFromPtr(text), @intFromPtr(query_cache) });
        return last_job;
    }
};

pub const Result = union(enum) {
    syntax: *syntax,
    failed: []const u8,
};

pub fn match_result(m: tp.message, job: *Job) ?Result {
    var syn: usize = 0;
    var err: []const u8 = undefined;
    return if (cbor.match(m.buf, .{ "SYNTAX", cbor.extract(job), cbor.extract(&syn) }) catch false)
        .{ .syntax = @ptrFromInt(syn) }
    else if (cbor.match(m.buf, .{ "SYNTAX", cbor.extract(job), "error", cbor.extract(&err) }) catch false)
        .{ .failed = err }
    else
        null;
}

pub fn drop_result(m: tp.message) bool {
    var job: Job = 0;
    const result = match_result(m, &job) orelse return false;
    switch (result) {
        .syntax => |syn| syn.destroy(),
        .failed => {},
    }
    return true;
}

const Process = struct {
    receiver: Receiver,

    const Receiver = tp.Receiver(*Process);
    const allocator = std.heap.c_allocator;

    pub fn create() !tp.pid {
        const self = try allocator.create(Process);
        errdefer allocator.destroy(self);
        self.* = .{
            .receiver = .init(receive, dtor, self),
        };
        return tp.spawn_link(allocator, self, Process.start, module_name);
    }

    fn start(self: *Process) tp.result {
        tp.receive(&self.receiver);
    }

    fn dtor(self: *Process) void {
        allocator.destroy(self);
    }

    fn receive(_: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        var job: Job = 0;
        var parser: []const u8 = undefined;
        var text_ptr: usize = 0;
        var query_cache_ptr: usize = 0;

        return if (try m.match(.{ "P", tp.extract(&job), tp.extract(&parser), tp.extract(&text_ptr), tp.extract(&query_cache_ptr) })) {
            const text: *Buffer.SharedText = @ptrFromInt(text_ptr);
            defer text.release();
            const syn = parse(parser, text.text, @ptrFromInt(query_cache_ptr)) catch |e|
                return from.send(.{ "SYNTAX", job, "error", @errorName(e) });
            from.send(.{ "SYNTAX", job, @intFromPtr(syn) }) catch |e| {
                syn.destroy();
                return e;
            };
        } else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn parse(parser: []const u8, text: []const u8, query_cache: *syntax.QueryCache) !*syntax {
        const frame = tracy.initZone(@src(), .{ .name = "syntax worker parse" });
        defer frame.deinit();
        const syn = try syntax.create_file_type_static(allocator, parser, query_cache);
        errdefer syn.destroy();
        try syn.refresh_full(text);
        return syn;
    }
};
