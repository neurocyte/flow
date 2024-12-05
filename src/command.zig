const std = @import("std");
const tp = @import("thespian");
const log = @import("log");

pub var context_check: ?*const fn () void = null;

pub const ID = usize;
pub const ID_unknown = std.math.maxInt(ID);

pub const Result = anyerror!void;
pub const Context = struct {
    args: tp.message = .{},

    pub fn fmt(value: anytype) Context {
        return .{ .args = tp.message.fmtbuf(&context_buffer, value) catch @panic("command.Context.fmt failed") };
    }
};
threadlocal var context_buffer: [tp.max_message_size]u8 = undefined;
pub const fmt = Context.fmt;

const Vtable = struct {
    id: ID = ID_unknown,
    name: []const u8,
    run: *const fn (self: *Vtable, ctx: Context) tp.result,
    meta: Metadata,
};

const Metadata = struct {
    description: []const u8 = &[_]u8{},
    arguments: []const ArgumentType = &[_]ArgumentType{},
};

pub const ArgumentType = enum {
    string,
    integer,
    float,
    object,
};

pub fn Closure(comptime T: type) type {
    return struct {
        vtbl: Vtable,
        f: FunT,
        data: T,

        ///The type signature of commands
        const FunT: type = *const fn (T, ctx: Context) Result;

        const Self = @This();

        pub fn init(f: FunT, data: T, name: []const u8, meta: Metadata) Self {
            return .{
                .vtbl = .{
                    .run = run,
                    .name = name,
                    .meta = meta,
                },
                .f = f,
                .data = data,
            };
        }

        pub fn register(self: *Self) !void {
            if (command_names.get(self.vtbl.name)) |id| {
                self.vtbl.id = id;
                reAddCommand(&self.vtbl) catch |e| return log.err("cmd", "reAddCommand", e);
                // log.print("cmd", "reAddCommand({s}) => {d}", .{ self.vtbl.name, self.vtbl.id });
            } else {
                self.vtbl.id = try addCommand(&self.vtbl);
                command_names.put(self.vtbl.name, self.vtbl.id) catch |e| return log.err("cmd", "addCommand", e);
                // log.print("cmd", "addCommand({s}) => {d}", .{ self.vtbl.name, self.vtbl.id });
            }
        }

        pub fn unregister(self: *Self) void {
            removeCommand(self.vtbl.id);
        }

        fn run(vtbl: *Vtable, ctx: Context) tp.result {
            const self: *Self = fromVtable(vtbl);
            return self.f(self.data, ctx) catch |e| tp.exit_error(e, @errorReturnTrace());
        }

        fn fromVtable(vtbl: *Vtable) *Self {
            return @fieldParentPtr("vtbl", vtbl);
        }
    };
}

const CommandTable = std.ArrayList(?*Vtable);
pub var commands: CommandTable = CommandTable.init(command_table_allocator);
var command_names: std.StringHashMap(ID) = std.StringHashMap(ID).init(command_table_allocator);
const command_table_allocator = std.heap.c_allocator;

fn addCommand(cmd: *Vtable) !ID {
    try commands.append(cmd);
    return commands.items.len - 1;
}

fn reAddCommand(cmd: *Vtable) !void {
    if (commands.items[cmd.id] != null) return error.DuplicateCommand;
    commands.items[cmd.id] = cmd;
}

pub fn removeCommand(id: ID) void {
    commands.items[id] = null;
}

pub fn execute(id: ID, ctx: Context) tp.result {
    if (context_check) |check| check();
    if (id >= commands.items.len)
        return tp.exit_fmt("CommandNotFound: {d}", .{id});
    const cmd = commands.items[id];
    if (cmd) |p| {
        // var buf: [tp.max_message_size]u8 = undefined;
        // log.print("cmd", "execute({s}) {s}", .{ p.name, ctx.args.to_json(&buf) catch "" }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        return p.run(p, ctx);
    } else {
        return tp.exit_fmt("CommandNotAvailable: {d}", .{id});
    }
}

pub fn get_id(name: []const u8) ?ID {
    for (commands.items) |cmd| {
        if (cmd) |p|
            if (std.mem.eql(u8, p.name, name))
                return p.id;
    }
    return null;
}

pub fn get_name(id: ID) ?[]const u8 {
    if (id >= commands.items.len) return null;
    return (commands.items[id] orelse return null).name;
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

pub fn get_description(id: ID) ?[]const u8 {
    if (id >= commands.items.len) return null;
    return (commands.items[id] orelse return null).meta.description;
}

pub fn get_arguments(id: ID) ?[]const ArgumentType {
    if (id >= commands.items.len) return null;
    return (commands.items[id] orelse return null).meta.arguments;
}

const suppressed_errors = .{
    "enable_fast_scroll",
    "disable_fast_scroll",
    "clear_diagnostics",
};

pub fn executeName(name: []const u8, ctx: Context) tp.result {
    const id = get_id(name);
    if (id) |id_| return execute(id_, ctx);
    inline for (suppressed_errors) |err| if (std.mem.eql(u8, err, name)) return;
    return tp.exit_fmt("CommandNotFound: {s}", .{name});
}

fn CmdDef(comptime T: type) type {
    return struct {
        const Fn = fn (T, Context) anyerror!void;
        name: [:0]const u8,
        f: *const Fn,
        meta: Metadata,
    };
}

fn getTargetType(comptime Namespace: type) type {
    return @field(Namespace, "Target");
}

fn getCommands(comptime Namespace: type) []const CmdDef(*getTargetType(Namespace)) {
    @setEvalBranchQuota(10_000);
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
                    cmds[i] = .{
                        .f = &@field(Namespace, decl.name),
                        .name = decl.name,
                        .meta = if (@hasDecl(Namespace, decl.name ++ "_meta"))
                            @field(Namespace, decl.name ++ "_meta")
                        else
                            @compileError(decl.name ++ " has no meta"),
                    };
                    i += 1;
                }
            }
            const cmds_const = cmds;
            return &cmds_const;
        },
        else => @compileError("expected tuple or struct type"),
    };
}

pub fn Collection(comptime Namespace: type) type {
    const cmds = comptime getCommands(Namespace);
    const Target = getTargetType(Namespace);
    const Clsr = Closure(*Target);
    var fields_var: [cmds.len]std.builtin.Type.StructField = undefined;
    inline for (cmds, 0..) |cmd, i| {
        @setEvalBranchQuota(10_000);
        fields_var[i] = .{
            .name = cmd.name,
            .type = Clsr,
            .default_value = null,
            .is_comptime = false,
            .alignment = if (@sizeOf(Clsr) > 0) @alignOf(Clsr) else 0,
        };
    }
    const fields: [cmds.len]std.builtin.Type.StructField = fields_var;
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
                @field(self.fields, cmd.name) = Closure(*Target).init(cmd.f, targetPtr, cmd.name, cmd.meta);
                try @field(self.fields, cmd.name).register();
            }
        }

        pub fn deinit(self: *Self) void {
            inline for (cmds) |cmd|
                Closure(*Target).unregister(&@field(self.fields, cmd.name));
        }
    };
}
