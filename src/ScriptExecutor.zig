const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

const log = std.log.scoped(.exec);

const module_name = @typeName(@This());

pub fn spawn(allocator: std.mem.Allocator, ctx: *tp.context, eh: anytype, env: ?tp.env, target: tp.pid_ref, script: Script, then: ?tp.message) !void {
    const args = try Process.Args.init(allocator, target, script, then);
    errdefer args.deinit();
    const pid = try ctx.spawn_link(args, Process.start, module_name, eh, env);
    pid.deinit();
}

const Command = struct {
    name: []const u8,
    args: []const u8,
};

pub const Script = struct {
    allocator: std.mem.Allocator,
    commands: []Command,

    pub fn deinit(self: Script) void {
        free_commands(self.allocator, self.commands);
    }
};

pub const Diagnostic = struct {
    line: usize = 0,
    text: []const u8 = "",
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

        fn init(allocator: std.mem.Allocator, target: tp.pid_ref, script: Script, then: ?tp.message) !Args {
            errdefer script.deinit();
            const then_owned = if (then) |m| try allocator.dupe(u8, m.buf) else null;
            return .{ .allocator = allocator, .target = target.clone(), .commands = script.commands, .then = then_owned };
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

pub fn parse_exec(allocator: std.mem.Allocator, text: []const u8) !Script {
    var commands: CommandList = .{ .allocator = allocator };
    errdefer commands.deinit();
    var it = std.mem.splitScalar(u8, text, ';');
    while (it.next()) |command| {
        var parts = std.mem.splitScalar(u8, command, ':');
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
        try commands.append(name, args.written());
    }
    return commands.to_script();
}

/// parse script file: one `command_name [json_value...]` per line.
/// empty lines and lines starting with `#` are ignored.
pub fn parse_file(allocator: std.mem.Allocator, content: []const u8, diag: *Diagnostic) !Script {
    var commands: CommandList = .{ .allocator = allocator };
    errdefer commands.deinit();
    var it = std.mem.splitScalar(u8, content, '\n');
    var lineno: usize = 0;
    while (it.next()) |line_| {
        lineno += 1;
        const line = std.mem.trim(u8, line_, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        diag.* = .{ .line = lineno, .text = line };
        const name_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        var rest = line[name_end..];

        var values: std.ArrayList(u8) = .empty;
        defer values.deinit(allocator);
        var count: usize = 0;
        while (true) {
            rest = std.mem.trimStart(u8, rest, " \t");
            if (rest.len == 0) break;
            const end = json_value_end(rest) orelse return error.InvalidScriptValue;
            const value = cbor.fromJsonAlloc(allocator, rest[0..end]) catch return error.InvalidScriptValue;
            defer allocator.free(value);
            try values.appendSlice(allocator, value);
            count += 1;
            rest = rest[end..];
        }

        var args: std.Io.Writer.Allocating = .init(allocator);
        defer args.deinit();
        try cbor.writeArrayHeader(&args.writer, count);
        try args.writer.writeAll(values.items);
        try commands.append(line[0..name_end], args.written());
    }
    diag.* = .{};
    return commands.to_script();
}

fn json_value_end(text: []const u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
                if (depth == 0) return i + 1;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            ' ', '\t' => if (depth == 0) return i,
            else => {},
        }
    }
    return if (depth == 0 and !in_string) text.len else null;
}

const CommandList = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Command) = .empty,

    fn append(self: *CommandList, name: []const u8, args: []const u8) !void {
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const args_owned = try self.allocator.dupe(u8, args);
        errdefer self.allocator.free(args_owned);
        try self.list.append(self.allocator, .{ .name = name_owned, .args = args_owned });
    }

    fn to_script(self: *CommandList) !Script {
        return .{ .allocator = self.allocator, .commands = try self.list.toOwnedSlice(self.allocator) };
    }

    fn deinit(self: *CommandList) void {
        for (self.list.items) |command| free_command(self.allocator, command);
        self.list.deinit(self.allocator);
    }
};

fn free_command(allocator: std.mem.Allocator, command: Command) void {
    allocator.free(command.name);
    allocator.free(command.args);
}

fn free_commands(allocator: std.mem.Allocator, commands: []Command) void {
    for (commands) |command| free_command(allocator, command);
    allocator.free(commands);
}
