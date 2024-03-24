const std = @import("std");
const tp = @import("thespian");
const log = @import("log");

const tui = @import("tui.zig");

pub const ID = usize;

pub const Context = struct {
    args: tp.message = .{},

    pub fn fmt(value: anytype) Context {
        return .{ .args = tp.message.fmtbuf(&context_buffer, value) catch @panic("command.Context.fmt failed") };
    }
};
threadlocal var context_buffer: [tp.max_message_size]u8 = undefined;
pub const fmt = Context.fmt;

const Vtable = struct {
    id: ID = 0,
    name: []const u8,
    run: *const fn (self: *Vtable, ctx: Context) tp.result,
};

pub fn Closure(comptime T: type) type {
    return struct {
        vtbl: Vtable,
        f: FunT,
        data: T,

        const FunT: type = *const fn (T, ctx: Context) tp.result;
        const Self = @This();

        pub fn init(f: FunT, data: T, name: []const u8) Self {
            return .{
                .vtbl = .{
                    .run = run,
                    .name = name,
                },
                .f = f,
                .data = data,
            };
        }

        pub fn register(self: *Self) !void {
            self.vtbl.id = try addCommand(&self.vtbl);
            // try log.logger("cmd").print("addCommand({s}) => {d}", .{ self.vtbl.name, self.vtbl.id });
        }

        pub fn unregister(self: *Self) void {
            removeCommand(self.vtbl.id);
        }

        fn run(vtbl: *Vtable, ctx: Context) tp.result {
            const self: *Self = fromVtable(vtbl);
            return self.f(self.data, ctx);
        }

        fn fromVtable(vtbl: *Vtable) *Self {
            return @fieldParentPtr(Self, "vtbl", vtbl);
        }
    };
}

const CommandTable = std.ArrayList(?*Vtable);
var commands: CommandTable = CommandTable.init(std.heap.page_allocator);

fn addCommand(cmd: *Vtable) !ID {
    try commands.append(cmd);
    return commands.items.len - 1;
}

pub fn removeCommand(id: ID) void {
    commands.items[id] = null;
}

pub fn execute(id: ID, ctx: Context) tp.result {
    _ = tui.current(); // assert we are in tui thread scope
    if (id >= commands.items.len)
        return tp.exit_fmt("CommandNotFound: {d}", .{id});
    const cmd = commands.items[id];
    if (cmd) |p| {
        // var buf: [tp.max_message_size]u8 = undefined;
        // log.logger("cmd").print("execute({s}) {s}", .{ p.name, ctx.args.to_json(&buf) catch "" }) catch |e| return tp.exit_error(e);
        return p.run(p, ctx);
    } else {
        return tp.exit_fmt("CommandNotAvailable: {d}", .{id});
    }
}

pub fn getId(name: []const u8) ?ID {
    for (commands.items) |cmd| {
        if (cmd) |p|
            if (std.mem.eql(u8, p.name, name))
                return p.id;
    }
    return null;
}

pub fn get_id_cache(name: []const u8, id: *?ID) ?ID {
    for (commands.items) |cmd| {
        if (cmd) |p|
            if (std.mem.eql(u8, p.name, name)) {
                id.* = p.id;
                return p.id;
            };
    }
    return null;
}

pub fn executeName(name: []const u8, ctx: Context) tp.result {
    return execute(getId(name) orelse return tp.exit_fmt("CommandNotFound: {s}", .{name}), ctx);
}

fn CmdDef(comptime T: type) type {
    return struct {
        const Fn = fn (T, Context) tp.result;
        name: [:0]const u8,
        f: *const Fn,
    };
}

fn getTargetType(comptime Namespace: type) type {
    return @field(Namespace, "Target");
}

fn getCommands(comptime Namespace: type) []CmdDef(*getTargetType(Namespace)) {
    comptime switch (@typeInfo(Namespace)) {
        .Struct => |info| {
            var count = 0;
            const Target = getTargetType(Namespace);
            // @compileLog(Namespace, Target);
            for (info.decls) |decl| {
                // @compileLog(decl.name, @TypeOf(@field(Namespace, decl.name)));
                if (@TypeOf(@field(Namespace, decl.name)) == CmdDef(*Target).Fn)
                    count += 1;
            }
            var cmds: [count]CmdDef(*Target) = undefined;
            var i = 0;
            for (info.decls) |decl| {
                if (@TypeOf(@field(Namespace, decl.name)) == CmdDef(*Target).Fn) {
                    cmds[i] = .{ .f = &@field(Namespace, decl.name), .name = decl.name };
                    i += 1;
                }
            }
            return &cmds;
        },
        else => @compileError("expected tuple or struct type"),
    };
}

pub fn Collection(comptime Namespace: type) type {
    const cmds = comptime getCommands(Namespace);
    const Target = getTargetType(Namespace);
    const Clsr = Closure(*Target);
    var fields: [cmds.len]std.builtin.Type.StructField = undefined;
    inline for (cmds, 0..) |cmd, i| {
        @setEvalBranchQuota(10_000);
        fields[i] = .{
            .name = cmd.name,
            .type = Clsr,
            .default_value = null,
            .is_comptime = false,
            .alignment = if (@sizeOf(Clsr) > 0) @alignOf(Clsr) else 0,
        };
    }
    const Fields = @Type(.{
        .Struct = .{
            .is_tuple = false,
            .layout = .auto,
            .decls = &.{},
            .fields = &fields,
        },
    });
    return struct {
        fields: Fields,

        const Self = @This();

        pub fn init(self: *Self, targetPtr: *Target) !void {
            if (cmds.len == 0)
                @compileError("no commands found in type " ++ @typeName(Target) ++ " (did you mark them public?)");
            inline for (cmds) |cmd| {
                @field(self.fields, cmd.name) = Closure(*Target).init(cmd.f, targetPtr, cmd.name);
                try @field(self.fields, cmd.name).register();
            }
        }

        pub fn deinit(self: *Self) void {
            inline for (cmds) |cmd|
                Closure(*Target).unregister(&@field(self.fields, cmd.name));
        }
    };
}
