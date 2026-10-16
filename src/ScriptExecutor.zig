const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

const log = std.log.scoped(.exec);

const module_name = @typeName(@This());

pub fn spawn(allocator: std.mem.Allocator, ctx: *tp.context, eh: anytype, env: ?tp.env, target: tp.pid_ref, script: []const u8, then: ?tp.message) !void {
    const args = try Process.Args.init(allocator, target, script, then);
    errdefer args.deinit();
    const pid = try ctx.spawn_link(args, Process.start, module_name, eh, env);
    pid.deinit();
}

const Command = struct {
    name: []const u8,
    args: []const u8,
};

const Process = struct {
    allocator: std.mem.Allocator,
    target: tp.pid,
    commands: []Command,
    then: ?[]const u8,
    next: usize = 0,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        target: tp.pid,
        commands: []Command,
        then: ?[]const u8,

        fn init(allocator: std.mem.Allocator, target: tp.pid_ref, script: []const u8, then: ?tp.message) !Args {
            const commands = try parse(allocator, script);
            errdefer free_commands(allocator, commands);
            const then_owned = if (then) |m| try allocator.dupe(u8, m.buf) else null;
            return .{ .allocator = allocator, .target = target.clone(), .commands = commands, .then = then_owned };
        }

        fn deinit(self: Args) void {
            self.target.deinit();
            free_commands(self.allocator, self.commands);
            if (self.then) |then| self.allocator.free(then);
        }
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| {
            log.err("start failed: {t}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn init(args: Args) !void {
        const self = args.allocator.create(@This()) catch |e| {
            args.deinit();
            return e;
        };
        self.* = .{
            .allocator = args.allocator,
            .target = args.target,
            .commands = args.commands,
            .then = args.then,
            .receiver = .init(receive_fn, @This().deinit, self),
        };
        errdefer self.deinit();
        _ = tp.set_trap(true);
        try self.target.link();
        try self.run_next();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.target.deinit();
        free_commands(self.allocator, self.commands);
        if (self.then) |then| self.allocator.free(then);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| {
            self.send_then();
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var id: u64 = 0;
        var exit_msg: cbor.Raw = .empty;
        var reason: []const u8 = "";

        if (try m.match(.{ "reply", tp.extract(&id), "ok" })) {
            if (id != self.next + 1) return;
            self.next += 1;
            return self.run_next();
        } else if (try m.match(.{ "reply", tp.extract(&id), .{ "error", tp.extract(&exit_msg) } })) {
            if (id != self.next + 1) return;
            const name = self.commands[self.next].name;
            const skipped = self.commands.len - self.next - 1;
            var buf: [256]u8 = undefined;
            if (!try cbor.match(exit_msg.bytes, .{ "exit", cbor.extract(&reason), cbor.more }))
                reason = (tp.message{ .buf = exit_msg.bytes }).to_json(&buf) catch "(unknown)";
            if (skipped > 0)
                log.err("{s} failed: {s}, skipping {d} remaining command(s)", .{ name, reason, skipped })
            else
                log.err("{s} failed: {s}", .{ name, reason });
            return self.finish();
        } else if (try m.match(.{ "exit", tp.more })) {
            if (from.instance_id() == self.target.instance_id()) return tp.exit_normal();
        }
    }

    fn run_next(self: *@This()) !void {
        if (self.next >= self.commands.len) return self.finish();
        const command = self.commands[self.next];
        try self.target.send(.{ "cmd", command.name, cbor.Raw{ .bytes = command.args }, .{ "reply", tp.self_pid().instance_id(), self.next + 1 } });
    }

    fn finish(self: *@This()) error{Exit} {
        self.send_then();
        return tp.exit_normal();
    }

    fn send_then(self: *@This()) void {
        const then = self.then orelse return;
        self.then = null;
        defer self.allocator.free(then);
        self.target.send_raw(.{ .buf = then }) catch {};
    }
};

fn parse(allocator: std.mem.Allocator, script: []const u8) ![]Command {
    var commands: std.ArrayList(Command) = .empty;
    errdefer {
        for (commands.items) |command| free_command(allocator, command);
        commands.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, script, ';');
    while (it.next()) |text| {
        var parts = std.mem.splitScalar(u8, text, ':');
        const name = parts.first();
        if (name.len == 0) continue;
        var count: usize = 0;
        while (parts.next()) |_| count += 1;

        var args: std.Io.Writer.Allocating = .init(allocator);
        defer args.deinit();
        try cbor.writeArrayHeader(&args.writer, count);
        parts.reset();
        _ = parts.first();
        while (parts.next()) |arg| {
            if (std.fmt.parseInt(isize, arg, 10) catch null) |i|
                try cbor.writeValue(&args.writer, i)
            else
                try cbor.writeValue(&args.writer, arg);
        }

        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const args_owned = try allocator.dupe(u8, args.written());
        errdefer allocator.free(args_owned);
        try commands.append(allocator, .{ .name = name_owned, .args = args_owned });
    }
    return commands.toOwnedSlice(allocator);
}

fn free_command(allocator: std.mem.Allocator, command: Command) void {
    allocator.free(command.name);
    allocator.free(command.args);
}

fn free_commands(allocator: std.mem.Allocator, commands: []Command) void {
    for (commands) |command| free_command(allocator, command);
    allocator.free(commands);
}
