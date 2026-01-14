const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");

pub var log_execute: bool = false;
pub var context_check: ?*const fn () void = null;

pub const ID = usize;
pub const ID_unknown = std.math.maxInt(ID);

pub const Result = anyerror!void;
pub const Context = struct {
    args: tp.message = .{},

    pub fn fmt(value: anytype) Context {
        context_buffer.clearRetainingCapacity();
        cbor.writeValue(&context_buffer.writer, value) catch @panic("command.Context.fmt failed");
        return .{ .args = .{ .buf = context_buffer.written() } };
    }
};

const context_buffer_allocator = std.heap.c_allocator;
threadlocal var context_buffer: std.Io.Writer.Allocating = .init(context_buffer_allocator);
pub const fmt = Context.fmt;

const Vtable = struct {
    id: ID = ID_unknown,
    name: []const u8,
    run: *const fn (self: *Vtable, ctx: Context) tp.result,
    meta: Metadata,
};

pub const Metadata = struct {
    description: []const u8 = &[_]u8{},
    arguments: []const ArgumentType = &[_]ArgumentType{},
    icon: ?[]const u8 = null,
};

pub const ArgumentType = enum {
    string,
    integer,
    float,
    boolean,
    object,
    array,
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
            if (command_names.get(self.vtbl.name)) |id|
                reAddCommand(id, &self.vtbl) catch |e| return log.err("cmd", "reAddCommand", e)
            else
                addCommand(&self.vtbl);
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
pub var commands: CommandTable = .empty;
var command_names: std.StringHashMap(ID) = std.StringHashMap(ID).init(command_table_allocator);
const command_table_allocator = std.heap.c_allocator;

fn assignCommandId(name: []const u8) ID {
    commands.append(command_table_allocator, null) catch |e| std.debug.panic("assignCommandId: {t}", .{e});
    const id = commands.items.len - 1;
    command_names.put(name, id) catch |e| std.debug.panic("assignCommandId: {t}", .{e});
    return id;
}

fn addCommand(cmd: *Vtable) void {
    commands.append(command_table_allocator, cmd) catch |e| std.debug.panic("addCommand: {t}", .{e});
    const id = commands.items.len - 1;
    cmd.id = id;
    command_names.put(cmd.name, id) catch |e| std.debug.panic("assignCommandId: {t}", .{e});
}

fn reAddCommand(id: ID, cmd: *Vtable) !void {
    cmd.id = id;
    if (commands.items[id] != null) return error.DuplicateCommand;
    commands.items[id] = cmd;
}

pub fn removeCommand(id: ID) void {
    commands.items[id] = null;
}

pub fn execute(id: ID, name: []const u8, ctx: Context) tp.result {
    if (tp.env.get().enabled(tp.channel.debug)) trace: {
        var iter = ctx.args.buf;
        var len = cbor.decodeArrayHeader(&iter) catch break :trace;
        if (len < 1) {
            tp.trace(tp.channel.debug, .{ "command", "execute", id, get_name(id) });
        } else {
            var msg_cb: std.Io.Writer.Allocating = .init(command_table_allocator);
            defer msg_cb.deinit();
            const writer = &msg_cb.writer;
            cbor.writeArrayHeader(writer, 4 + len) catch break :trace;
            cbor.writeValue(writer, "command") catch break :trace;
            cbor.writeValue(writer, "execute") catch break :trace;
            cbor.writeValue(writer, id) catch break :trace;
            cbor.writeValue(writer, get_name(id)) catch break :trace;
            while (len > 0) : (len -= 1) {
                var arg: []const u8 = undefined;
                if (cbor.matchValue(&iter, cbor.extract_cbor(&arg)) catch break :trace)
                    writer.writeAll(arg) catch break :trace;
            }
            const msg: tp.message = .{ .buf = msg_cb.written() };
            tp.trace(tp.channel.debug, msg);
        }
    }
    if (context_check) |check| check();
    if (id >= commands.items.len)
        return notFoundError(id, name);
    const cmd = commands.items[id];
    if (cmd) |p| {
        if (log_execute) {
            var buf: [tp.max_message_size]u8 = undefined;
            log.print("cmd", "execute({d}) {s} {s}", .{ id, p.name, if (ctx.args.buf.len > 0) ctx.args.to_json(&buf) catch "(error)" else "" });
        }
        return p.run(p, ctx);
    } else {
        return notFoundError(id, name);
    }
}

pub fn get_id(name: []const u8) ?ID {
    const id = get_name_id(name);
    return if (commands.items[id]) |_| id else null;
}

pub fn get_name_id(name: []const u8) ID {
    return command_names.get(name) orelse assignCommandId(name);
}

pub fn get_name(id: ID) ?[]const u8 {
    if (tp.env.get().enabled(tp.channel.debug)) {
        if (id >= commands.items.len)
            tp.trace(tp.channel.debug, .{ "command", "get_name", "too large", id })
        else if (commands.items[id] == null)
            tp.trace(tp.channel.debug, .{ "command", "get_name", "null", id });
    }
    if (id >= commands.items.len) return null;
    if (commands.items[id]) |cmd| return cmd.name;
    var iter = command_names.iterator();
    while (iter.next()) |kv| if (kv.value_ptr.* == id)
        return kv.key_ptr.*;
    return null;
}

pub fn get_id_cache(name: []const u8, cached_id: *?ID) ID {
    const id = get_name_id(name);
    cached_id.* = id;
    return id;
}

pub fn get_description(id: ID) ?[]const u8 {
    if (id >= commands.items.len) return null;
    return (commands.items[id] orelse return null).meta.description;
}

pub fn get_arguments(id: ID) ?[]const ArgumentType {
    if (id >= commands.items.len) return null;
    return (commands.items[id] orelse return null).meta.arguments;
}

pub fn get_icon(id: ID) ?[]const u8 {
    if (id >= commands.items.len) return null;
    return (commands.items[id] orelse return null).meta.icon;
}

const suppressed_errors = std.StaticStringMap(void).initComptime(.{
    .{ "enable_fast_scroll", void },
    .{ "disable_fast_scroll", void },
    .{ "enable_alt_scroll", void },
    .{ "disable_alt_scroll", void },
    .{ "clear_diagnostics", void },
    .{ "palette_menu_cancel", void },
});

pub fn executeName(name: []const u8, ctx: Context) tp.result {
    return execute(get_name_id(name), name, ctx);
}

fn notFoundError(id: ID, name: []const u8) !void {
    if (!suppressed_errors.has(name))
        return tp.exit_fmt("CommandNotFound: {s}({d})", .{ name, id });
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
        .@"struct" => |info| {
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
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = if (@sizeOf(Clsr) > 0) @alignOf(Clsr) else 0,
        };
    }
    const fields: [cmds.len]std.builtin.Type.StructField = fields_var;
    const Fields = @Type(.{
        .@"struct" = .{
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
            inline for (cmds) |cmd|
                @field(self.fields, cmd.name) = Closure(*Target).init(cmd.f, targetPtr, cmd.name, cmd.meta);
            try self.register();
        }

        pub fn init_unregistered(self: *Self, targetPtr: *Target) void {
            if (cmds.len == 0)
                @compileError("no commands found in type " ++ @typeName(Target) ++ " (did you mark them public?)");
            inline for (cmds) |cmd| {
                @field(self.fields, cmd.name) = Closure(*Target).init(cmd.f, targetPtr, cmd.name, cmd.meta);
            }
        }

        pub fn deinit(self: *Self) void {
            self.unregister();
        }

        pub fn register(self: *Self) !void {
            inline for (cmds) |cmd|
                try @field(self.fields, cmd.name).register();
        }

        pub fn unregister(self: *Self) void {
            inline for (cmds) |cmd|
                Closure(*Target).unregister(&@field(self.fields, cmd.name));
        }
    };
}
