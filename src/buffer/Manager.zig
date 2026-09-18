const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const FileStore = @import("FileStore");
const Buffer = @import("Buffer.zig");

const Self = @This();

allocator: std.mem.Allocator,
buffers: std.StringHashMapUnmanaged(*Buffer),
file_store: ?FileStore = null,
watched: std.AutoHashMapUnmanaged(*Buffer, []const u8) = .empty,
next_request_id: usize = 1,
saves: std.AutoHashMapUnmanaged(usize, PendingSave) = .empty,
save_groups: std.AutoHashMapUnmanaged(usize, SaveGroup) = .empty,
loads: std.AutoHashMapUnmanaged(usize, PendingLoad) = .empty,

pub const LoadError = error{ OutOfMemory, LoadNoFileName };

pub const LoadOptions = struct {
    then: ?cbor.Raw = null,
    on_error: ?cbor.Raw = null,
};

const PendingLoad = struct {
    io: std.Io,
    id: usize,
    stream: ?FileStore.ReadStream = null,
    file_path: []const u8,
    abs_path: []const u8,
    thens: std.ArrayList(cbor.Raw) = .empty,
    on_errors: std.ArrayList(cbor.Raw) = .empty,
    reload: ?struct { buffer: Buffer.Ref, root: Buffer.Root } = null,
    retried: bool = false,
    started: std.Io.Timestamp,

    fn deinit(self: *PendingLoad, allocator: std.mem.Allocator) void {
        if (self.stream) |*stream| stream.deinit();
        allocator.free(self.file_path);
        allocator.free(self.abs_path);
        for (self.thens.items) |then| allocator.free(then.bytes);
        self.thens.deinit(allocator);
        for (self.on_errors.items) |on_error| allocator.free(on_error.bytes);
        self.on_errors.deinit(allocator);
    }
};

pub const SaveError = error{ OutOfMemory, FileStoreNotReady, FileStoreSendFailed, SaveNoFileName };

pub const SaveOptions = struct {
    auto_save: bool = false,
    then: ?cbor.Raw = null,
};

pub const SaveAllOptions = struct {
    then: ?cbor.Raw = null,
    then_on_error: bool = false,
};

const PendingSave = struct {
    io: std.Io,
    stream: FileStore.WriteStream,
    buffer: Buffer.Ref,
    root: Buffer.Root,
    eol_mode: Buffer.EolMode,
    file_path: []const u8,
    auto_save: bool,
    then: ?cbor.Raw,
    group: ?usize,
    started: std.Io.Timestamp,
    prepare_us: i64,
    start_us: i64,
    bytes: usize,

    fn deinit(self: *PendingSave, allocator: std.mem.Allocator) void {
        self.stream.deinit();
        allocator.free(self.file_path);
        if (self.then) |then| allocator.free(then.bytes);
    }
};

const SaveGroup = struct {
    remaining: usize = 0,
    failed: bool = false,
    then: ?cbor.Raw,
    then_on_error: bool,
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .buffers = .{},
    };
}

pub fn deinit(self: *Self) void {
    var i = self.buffers.iterator();
    while (i.next()) |p| {
        self.unwatch_buffer(p.value_ptr.*);
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.deinit();
    }
    self.buffers.deinit(self.allocator);
    self.watched.deinit(self.allocator);
    var saves = self.saves.valueIterator();
    while (saves.next()) |pending| {
        if (self.file_store) |*file_store| pending.stream.abort(file_store);
        pending.deinit(self.allocator);
    }
    self.saves.deinit(self.allocator);
    var groups = self.save_groups.valueIterator();
    while (groups.next()) |group| if (group.then) |then| self.allocator.free(then.bytes);
    self.save_groups.deinit(self.allocator);
    var loads = self.loads.valueIterator();
    while (loads.next()) |pending| {
        if (self.file_store) |*file_store| if (pending.stream) |*stream| stream.cancel(file_store);
        pending.deinit(self.allocator);
    }
    self.loads.deinit(self.allocator);
    if (self.file_store) |*file_store| file_store.deinit();
}

fn get_buffer(self: *const Self, file_path: []const u8) ?*Buffer {
    return self.buffers.get(file_path);
}

fn add_buffer(self: *Self, buffer: *Buffer) error{OutOfMemory}!void {
    try self.buffers.put(self.allocator, try self.allocator.dupe(u8, buffer.get_file_path()), buffer);
}

pub fn delete_buffer(self: *Self, buffer_: *Buffer) void {
    const buffer = self.buffer_from_ref(buffer_.to_ref()) orelse return; // check buffer is valid
    self.unwatch_buffer(buffer);
    if (self.buffers.fetchRemove(buffer.get_file_path())) |kv| {
        self.allocator.free(kv.key);
        kv.value.deinit();
    } else buffer.deinit();
}

pub fn open_file(self: *Self, file_path: []const u8, now: std.Io.Timestamp) error{BufferNotLoaded}!*Buffer {
    const buffer = self.get_buffer(file_path) orelse return error.BufferNotLoaded;
    buffer.update_last_used_time(now);
    buffer.hidden = false;
    return buffer;
}

pub fn needs_load(self: *const Self, file_path: []const u8) bool {
    const buffer = self.get_buffer(file_path) orelse return true;
    return !buffer.ephemeral and buffer.hidden;
}

pub fn load(self: *Self, io: std.Io, file_path: []const u8, options: LoadOptions) LoadError!void {
    const then: ?cbor.Raw = if (options.then) |t| .{ .bytes = try self.allocator.dupe(u8, t.bytes) } else null;
    errdefer if (then) |t| self.allocator.free(t.bytes);
    const on_error: ?cbor.Raw = if (options.on_error) |t| .{ .bytes = try self.allocator.dupe(u8, t.bytes) } else null;
    errdefer if (on_error) |t| self.allocator.free(t.bytes);
    const pending = self.find_load(file_path) orelse try self.add_load(io, file_path, null);
    try pending.thens.ensureUnusedCapacity(self.allocator, 1);
    try pending.on_errors.ensureUnusedCapacity(self.allocator, 1);
    if (then) |t| pending.thens.appendAssumeCapacity(t);
    if (on_error) |t| pending.on_errors.appendAssumeCapacity(t);
    if (pending.stream == null) self.start_load_stream(pending);
}

pub fn reload(self: *Self, io: std.Io, buffer: *Buffer) LoadError!void {
    if (buffer.is_ephemeral()) return;
    const pending = try self.add_load(io, buffer.get_file_path(), .{ .buffer = buffer.to_ref(), .root = buffer.root });
    self.start_load_stream(pending);
}

fn find_load(self: *Self, file_path: []const u8) ?*PendingLoad {
    var it = self.loads.valueIterator();
    while (it.next()) |pending|
        if (pending.reload == null and std.mem.eql(u8, pending.file_path, file_path)) return pending;
    return null;
}

fn add_load(self: *Self, io: std.Io, file_path: []const u8, reload_of: @FieldType(PendingLoad, "reload")) LoadError!*PendingLoad {
    const abs_path = try self.resolve_path(file_path) orelse return error.LoadNoFileName;
    errdefer self.allocator.free(abs_path);
    const owned_path = try self.allocator.dupe(u8, file_path);
    errdefer self.allocator.free(owned_path);
    const id = self.new_request_id();
    try self.loads.put(self.allocator, id, .{
        .io = io,
        .id = id,
        .file_path = owned_path,
        .abs_path = abs_path,
        .reload = reload_of,
        .started = .now(io, .awake),
    });
    return self.loads.getPtr(id).?;
}

fn start_load_stream(self: *Self, pending: *PendingLoad) void {
    const file_store = self.file_store orelse return; // started by set_file_store
    pending.stream = FileStore.ReadStream.start(&file_store, self.allocator, pending.id, pending.abs_path, .{}) catch |e| {
        log.err("open {s} failed: {t}", .{ pending.file_path, e });
        return self.finish_load(pending.id, false);
    };
}

pub const LoadResult = enum { nochange, modified };

fn load_progress(self: *Self, id: usize, m: tp.message) LoadResult {
    const pending = self.loads.getPtr(id) orelse return .nochange;
    const file_store = self.file_store orelse return .nochange;
    const stream = if (pending.stream) |*stream| stream else return .nochange;
    const result = stream.receive(&file_store, m) catch |e| {
        if (e == error.FileStoreStreamFailed and !pending.retried and
            std.mem.eql(u8, stream.error_name, "FileChangedDuringRead"))
        {
            pending.retried = true;
            stream.deinit();
            pending.stream = null;
            self.start_load_stream(pending);
            return .nochange;
        }
        log.err("open {s} failed: {s}", .{
            pending.file_path,
            if (e == error.FileStoreStreamFailed) stream.error_name else @errorName(e),
        });
        self.finish_load(id, false);
        return .nochange;
    };
    if (result == .pending) return .nochange;
    self.finish_load(id, true);
    return .modified;
}

fn finish_load(self: *Self, id: usize, ok: bool) void {
    var kv = self.loads.fetchRemove(id) orelse return;
    defer kv.value.deinit(self.allocator);
    const pending = &kv.value;
    self.complete_load(pending, ok) catch
        for (pending.on_errors.items) |on_error| tp.self_pid().send_raw(.{ .buf = on_error.bytes }) catch {};
}

fn complete_load(self: *Self, pending: *PendingLoad, ok: bool) error{LoadFailed}!void {
    if (!ok) return error.LoadFailed;
    const stream = if (pending.stream) |*stream| stream else return error.LoadFailed;
    const io = pending.io;
    const stream_us = pending.started.durationTo(.now(io, .awake)).toMicroseconds();
    const bytes = stream.take_content() catch |e| {
        log.err("open {s} failed: {t}", .{ pending.file_path, e });
        return error.LoadFailed;
    };
    const size = bytes.len;
    const buffer = self.apply_load(pending, bytes, stream.exists) catch |e| {
        log.err("open {s} failed: {t}", .{ pending.file_path, e });
        return error.LoadFailed;
    };
    if (buffer == null) return;
    const total_us = pending.started.durationTo(.now(io, .awake)).toMicroseconds();
    perf_log.info("{s} {s} total {d:.3}ms bytes {d} [stream {d:.3} load {d:.3}]", .{
        if (pending.reload != null) "reload" else "open",
        pending.file_path,
        to_ms(total_us),
        size,
        to_ms(stream_us),
        to_ms(total_us - stream_us),
    });
    for (pending.thens.items) |then| tp.self_pid().send_raw(.{ .buf = then.bytes }) catch {};
}

fn apply_load(self: *Self, pending: *PendingLoad, bytes: []u8, exists: bool) !?*Buffer {
    const io = pending.io;
    const now: std.Io.Timestamp = .now(io, .real);
    if (pending.reload) |reload_of| {
        const buffer = self.buffer_from_ref(reload_of.buffer) orelse {
            self.allocator.free(bytes);
            return null;
        };
        if (buffer.root != reload_of.root) {
            log.warn("reload {s} dropped: the buffer changed while reloading", .{pending.file_path});
            self.allocator.free(bytes);
            return null;
        }
        try buffer.load_from_owned_bytes_and_update(io, buffer.get_file_path(), bytes, exists, now);
        buffer.update_last_used_time(now);
        return buffer;
    }
    if (self.get_buffer(pending.file_path)) |buffer| {
        try buffer.load_from_owned_bytes_and_update(io, pending.file_path, bytes, exists, now);
        buffer.hidden = false;
        return buffer;
    }
    var buffer = try Buffer.create(self.allocator, now);
    errdefer buffer.deinit();
    try buffer.load_from_owned_bytes_and_update(io, pending.file_path, bytes, exists, now);
    try self.add_buffer(buffer);
    self.watch_buffer(buffer);
    return buffer;
}

fn start_queued_loads(self: *Self) void {
    var ids: std.ArrayList(usize) = .empty;
    defer ids.deinit(self.allocator);
    var it = self.loads.valueIterator();
    while (it.next()) |pending| if (pending.stream == null)
        ids.append(self.allocator, pending.id) catch {};
    for (ids.items) |id| if (self.loads.getPtr(id)) |pending| self.start_load_stream(pending);
}

pub fn open_scratch(self: *Self, file_path: []const u8, content: []const u8, now: std.Io.Timestamp) Buffer.LoadError!*Buffer {
    const buffer = if (self.buffers.get(file_path)) |buffer| buffer else blk: {
        var buffer = try Buffer.create(self.allocator, now);
        errdefer buffer.deinit();
        try buffer.load_from_string_and_update(file_path, content, now);
        buffer.file_exists = true;
        try self.add_buffer(buffer);
        break :blk buffer;
    };
    buffer.update_last_used_time(now);
    buffer.hidden = false;
    buffer.ephemeral = true;
    return buffer;
}

pub fn mark_not_ephemeral(self: *Self, buffer: *Buffer) void {
    buffer.mark_not_ephemeral();
    self.watch_buffer(buffer);
}

pub fn write_state(self: *const Self, writer: *std.Io.Writer) error{ Stop, OutOfMemory, WriteFailed }!void {
    const buffers = self.list_unordered(self.allocator) catch return;
    defer self.allocator.free(buffers);
    try cbor.writeArrayHeader(writer, buffers.len);
    for (buffers) |buffer| {
        tp.trace(tp.channel.debug, .{ @typeName(Self), "write_state", buffer.get_file_path(), buffer.file_type_name });
        buffer.write_state(writer) catch |e| {
            tp.trace(tp.channel.debug, .{ @typeName(Self), "write_state", "failed", e });
            return;
        };
    }
}

pub fn extract_state(self: *Self, iter: *[]const u8, now: std.Io.Timestamp) !void {
    var len = try cbor.decodeArrayHeader(iter);
    tp.trace(tp.channel.debug, .{ @typeName(Self), "extract_state", len });
    while (len > 0) : (len -= 1) {
        var buffer = try Buffer.create(self.allocator, now);
        errdefer buffer.deinit();
        try buffer.extract_state(iter, now);
        try self.add_buffer(buffer);
        self.watch_buffer(buffer);
        tp.trace(tp.channel.debug, .{ "buffer", "extract", buffer.get_file_path(), buffer.file_type_name });
    }
}

pub fn get_buffer_for_file(self: *const Self, file_path: []const u8) ?*Buffer {
    return self.get_buffer(file_path);
}

pub fn retire(_: *Self, buffer: *Buffer, meta: ?[]const u8) void {
    if (meta) |buf| buffer.set_meta(buf) catch {};
    tp.trace(tp.channel.debug, .{ "buffer", "retire", buffer.get_file_path(), "hidden", buffer.hidden, "ephemeral", buffer.ephemeral });
    if (meta) |buf| tp.trace(tp.channel.debug, tp.message{ .buf = buf });
}

pub fn close_buffer(self: *Self, buffer: *Buffer) void {
    buffer.hidden = true;
    buffer.set_last_view(null);
    tp.trace(tp.channel.debug, .{ "buffer", "close", buffer.get_file_path(), "hidden", buffer.hidden, "ephemeral", buffer.ephemeral });
    if (buffer.is_ephemeral())
        self.delete_buffer(buffer);
}

pub fn list_most_recently_used(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}![]*Buffer {
    const result = try self.list_unordered(allocator);

    std.mem.sort(*Buffer, result, {}, struct {
        fn less_fn(_: void, lhs: *Buffer, rhs: *Buffer) bool {
            return lhs.utime > rhs.utime;
        }
    }.less_fn);

    return result;
}

pub fn list_unordered(self: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}![]*Buffer {
    var buffers = try std.ArrayListUnmanaged(*Buffer).initCapacity(allocator, self.buffers.size);
    var i = self.buffers.iterator();
    while (i.next()) |kv|
        (try buffers.addOne(allocator)).* = kv.value_ptr.*;
    return buffers.toOwnedSlice(allocator);
}

pub fn is_dirty(self: *const Self) bool {
    var i = self.buffers.iterator();
    while (i.next()) |kv|
        if (kv.value_ptr.*.is_dirty())
            return true;
    return false;
}

pub fn count_dirty_buffers(self: *const Self) usize {
    var count: usize = 0;
    var i = self.buffers.iterator();

    while (i.next()) |p| {
        const buffer = p.value_ptr.*;
        if (!buffer.is_ephemeral() and buffer.is_dirty()) {
            count += 1;
        }
    }
    return count;
}

pub fn has_any_buffers(self: *const Self) bool {
    var i = self.buffers.iterator();
    if (i.next()) |_| return true;
    return false;
}

pub fn has_any_non_hidden_buffers(self: *const Self) bool {
    var i = self.buffers.iterator();
    if (i.next()) |kv| {
        const buffer = kv.value_ptr.*;
        if (!buffer.hidden) return true;
    }
    return false;
}

pub fn is_buffer_dirty(self: *const Self, file_path: []const u8) bool {
    return if (self.get_buffer(file_path)) |buffer| buffer.is_dirty() else false;
}

pub fn save(self: *Self, io: std.Io, buffer: *Buffer, options: SaveOptions) SaveError!void {
    return self.save_in_group(io, buffer, options, null);
}

pub fn save_all(self: *Self, io: std.Io, options: SaveAllOptions) SaveError!void {
    const then: ?cbor.Raw = if (options.then) |t| .{ .bytes = try self.allocator.dupe(u8, t.bytes) } else null;
    errdefer if (then) |t| self.allocator.free(t.bytes);
    const group_id = self.new_request_id();
    try self.save_groups.put(self.allocator, group_id, .{ .remaining = 1, .then = then, .then_on_error = options.then_on_error });

    var dirty: std.ArrayList(*Buffer) = .empty;
    defer dirty.deinit(self.allocator);
    var i = self.buffers.valueIterator();
    while (i.next()) |b| {
        const buffer = b.*;
        if (buffer.is_ephemeral())
            buffer.mark_clean()
        else if (buffer.is_dirty())
            dirty.append(self.allocator, buffer) catch {
                self.save_groups.getPtr(group_id).?.failed = true;
            };
    }
    for (dirty.items) |buffer|
        self.save_in_group(io, buffer, .{ .auto_save = buffer.is_auto_save() }, group_id) catch |e| {
            log.err("save {s} failed: {t}", .{ buffer.get_file_path(), e });
            self.save_groups.getPtr(group_id).?.failed = true;
        };
    self.finish_group_member(group_id, true);
}

fn new_request_id(self: *Self) usize {
    defer self.next_request_id += 1;
    return self.next_request_id;
}

fn save_in_group(self: *Self, io: std.Io, buffer: *Buffer, options: SaveOptions, group: ?usize) SaveError!void {
    const file_store = self.file_store orelse return error.FileStoreNotReady;
    const started: std.Io.Timestamp = .now(io, .awake);
    const abs_path = try self.resolve_abs_path(buffer) orelse return error.SaveNoFileName;
    defer self.allocator.free(abs_path);

    const root = buffer.root;
    const eol_mode = buffer.file_eol_mode;
    const content = buffer.store_to_string_cached(root, eol_mode);
    const prepare_us = started.durationTo(.now(io, .awake)).toMicroseconds();

    const file_path = try self.allocator.dupe(u8, buffer.get_file_path());
    errdefer self.allocator.free(file_path);
    const then: ?cbor.Raw = if (options.then) |t| .{ .bytes = try self.allocator.dupe(u8, t.bytes) } else null;
    errdefer if (then) |t| self.allocator.free(t.bytes);

    const id = self.new_request_id();
    const stream_started: std.Io.Timestamp = .now(io, .awake);
    var stream = try FileStore.WriteStream.start(&file_store, self.allocator, id, abs_path, content, .{ .retain_symlinks = Buffer.retain_symlinks });
    const start_us = stream_started.durationTo(.now(io, .awake)).toMicroseconds();
    errdefer {
        stream.abort(&file_store);
        stream.deinit();
    }

    // overlapped buffer save replaces
    var effective_group = group;
    if (self.abort_save_for(buffer.to_ref())) |aborted_group| {
        if (group == null)
            effective_group = aborted_group
        else
            self.finish_group_member(aborted_group, false);
    }
    try self.saves.put(self.allocator, id, .{
        .io = io,
        .stream = stream,
        .buffer = buffer.to_ref(),
        .root = root,
        .eol_mode = eol_mode,
        .file_path = file_path,
        .auto_save = options.auto_save,
        .then = then,
        .group = effective_group,
        .started = started,
        .prepare_us = prepare_us,
        .start_us = start_us,
        .bytes = content.len,
    });
    if (group) |g| if (self.save_groups.getPtr(g)) |save_group| {
        save_group.remaining += 1;
    };
}

fn abort_save_for(self: *Self, buffer: Buffer.Ref) ?usize {
    var it = self.saves.iterator();
    while (it.next()) |p| {
        if (p.value_ptr.buffer != buffer) continue;
        const id = p.key_ptr.*;
        var kv = self.saves.fetchRemove(id).?;
        const group = kv.value.group;
        if (self.file_store) |*file_store| kv.value.stream.abort(file_store);
        kv.value.deinit(self.allocator);
        return group;
    }
    return null;
}

fn save_progress(self: *Self, id: usize, m: tp.message) void {
    const pending = self.saves.getPtr(id) orelse return;
    const file_store = self.file_store orelse return;
    const result = pending.stream.receive(&file_store, m) catch |e| {
        log.err("save {s} failed: {s}", .{
            pending.file_path,
            if (e == error.FileStoreStreamFailed) pending.stream.error_name else @errorName(e),
        });
        return self.finish_save(id, false);
    };
    if (result == .done) self.finish_save(id, true);
}

fn finish_save(self: *Self, id: usize, ok: bool) void {
    var kv = self.saves.fetchRemove(id) orelse return;
    defer kv.value.deinit(self.allocator);
    const pending = &kv.value;
    if (ok) {
        if (self.buffer_from_ref(pending.buffer)) |buffer| {
            buffer.mark_saved(pending.root, pending.eol_mode);
            tp.self_pid().send(.{ "cmd", "buffer_saved", .{ pending.file_path, pending.auto_save } }) catch {};
        }
        const total_us = pending.started.durationTo(.now(pending.io, .awake)).toMicroseconds();
        perf_log.info("save {s} total {d:.3}ms bytes {d} [prepare {d:.3} start {d:.3} wait {d:.3}]", .{
            pending.file_path,
            to_ms(total_us),
            pending.bytes,
            to_ms(pending.prepare_us),
            to_ms(pending.start_us),
            to_ms(total_us - pending.prepare_us - pending.start_us),
        });
        if (pending.then) |then| tp.self_pid().send_raw(.{ .buf = then.bytes }) catch {};
    }
    if (pending.group) |group| self.finish_group_member(group, ok);
}

fn finish_group_member(self: *Self, group_id: usize, ok: bool) void {
    const group = self.save_groups.getPtr(group_id) orelse return;
    if (!ok) group.failed = true;
    group.remaining -|= 1;
    if (group.remaining > 0) return;
    const kv = self.save_groups.fetchRemove(group_id) orelse return;
    const then = kv.value.then orelse return;
    defer self.allocator.free(then.bytes);
    if (!kv.value.failed or kv.value.then_on_error)
        tp.self_pid().send_raw(.{ .buf = then.bytes }) catch {};
}

fn to_ms(us: i64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

pub const ProbeError = error{ OutOfMemory, FileStoreNotReady, FileStoreSendFailed, ProbeNoFileName };

pub fn probe(self: *Self, id: usize, file_path: []const u8) ProbeError!void {
    const file_store = self.file_store orelse return error.FileStoreNotReady;
    const abs_path = try self.resolve_path(file_path) orelse return error.ProbeNoFileName;
    defer self.allocator.free(abs_path);
    return file_store.probe(id, abs_path);
}

pub fn is_file_store(self: *const Self, pid: tp.pid_ref) bool {
    const file_store = self.file_store orelse return false;
    return file_store.pid.instance_id() == pid.instance_id();
}

pub fn file_store_exited(self: *Self) void {
    var ids: std.ArrayList(usize) = .empty;
    defer ids.deinit(self.allocator);
    var it = self.saves.iterator();
    while (it.next()) |p| {
        log.err("save {s} failed: file store exited", .{p.value_ptr.file_path});
        ids.append(self.allocator, p.key_ptr.*) catch {};
    }
    const file_store = self.file_store;
    self.file_store = null;
    for (ids.items) |id| self.finish_save(id, false);
    var loads = self.loads.valueIterator();
    while (loads.next()) |pending| if (pending.stream) |*stream| {
        stream.deinit();
        pending.stream = null;
    };
    var watched = self.watched.valueIterator();
    while (watched.next()) |path| self.allocator.free(path.*);
    self.watched.clearRetainingCapacity();
    if (file_store) |fs| {
        var owned = fs;
        owned.deinit();
    }
}

pub fn reload_all(self: *Self, io: std.Io) LoadError!void {
    var i = self.buffers.valueIterator();
    while (i.next()) |b| {
        const buffer = b.*;
        if (buffer.is_ephemeral())
            buffer.mark_clean()
        else
            try self.reload(io, buffer);
    }
}

pub fn delete_all(self: *Self) void {
    var i = self.buffers.iterator();
    while (i.next()) |p| {
        self.unwatch_buffer(p.value_ptr.*);
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.deinit();
    }
    self.buffers.clearRetainingCapacity();
}

pub fn delete_others(self: *Self, protected: *Buffer) error{OutOfMemory}!void {
    var to_delete = try std.ArrayList(*Buffer).initCapacity(self.allocator, self.buffers.size);
    defer to_delete.deinit(self.allocator);

    var it = self.buffers.iterator();

    while (it.next()) |p| {
        const buffer = p.value_ptr.*;
        if (buffer != protected)
            to_delete.appendAssumeCapacity(buffer);
    }
    for (to_delete.items) |buffer|
        _ = self.delete_buffer(buffer);
}

pub fn close_others(self: *Self, protected: *Buffer) error{OutOfMemory}!usize {
    var remaining: usize = 0;
    var to_delete = try std.ArrayList(*Buffer).initCapacity(self.allocator, self.buffers.size);
    defer to_delete.deinit(self.allocator);

    var it = self.buffers.iterator();
    while (it.next()) |p| {
        const buffer = p.value_ptr.*;
        if (buffer != protected) {
            if (buffer.is_ephemeral() or !buffer.is_dirty()) {
                to_delete.appendAssumeCapacity(buffer);
            } else {
                remaining += 1;
            }
        }
    }
    for (to_delete.items) |buffer|
        self.delete_buffer(buffer);
    return remaining;
}

pub fn buffer_from_ref(self: *Self, buffer_ref: Buffer.Ref) ?*Buffer {
    var i = self.buffers.iterator();
    while (i.next()) |p|
        if (@intFromPtr(p.value_ptr.*) == @backingInt(buffer_ref))
            return p.value_ptr.*;
    tp.trace(tp.channel.debug, .{ "buffer_from_ref", "failed", buffer_ref });
    return null;
}

pub fn set_file_store(self: *Self, file_store: FileStore) void {
    self.unwatch_all();
    if (self.file_store) |*old| old.deinit();
    self.file_store = file_store;
    var i = self.buffers.valueIterator();
    while (i.next()) |buffer| self.watch_buffer(buffer.*);
    self.start_queued_loads();
}

pub fn take_file_store(self: *Self) ?FileStore {
    self.unwatch_all();
    const file_store = self.file_store;
    self.file_store = null;
    return file_store;
}

fn resolve_abs_path(self: *Self, buffer: *Buffer) error{OutOfMemory}!?[]const u8 {
    return self.resolve_path(buffer.get_file_path());
}

fn resolve_path(self: *Self, file_path: []const u8) error{OutOfMemory}!?[]const u8 {
    const project = tp.env.get().str("project");
    return if (std.fs.path.isAbsolute(file_path))
        std.fs.path.resolve(self.allocator, &.{file_path}) catch return error.OutOfMemory
    else if (project.len > 0)
        std.fs.path.resolve(self.allocator, &.{ project, file_path }) catch return error.OutOfMemory
    else
        null;
}

fn watch_buffer(self: *Self, buffer: *Buffer) void {
    if (buffer.is_ephemeral()) return;
    const file_store = self.file_store orelse return;
    if (self.watched.contains(buffer)) return;

    const abs_path = (self.resolve_abs_path(buffer) catch return) orelse return;
    self.watched.put(self.allocator, buffer, abs_path) catch {
        self.allocator.free(abs_path);
        return;
    };
    file_store.watch(abs_path) catch |e| std.log.err("file_store.watch: {s} -> {}", .{ abs_path, e });
}

fn unwatch_buffer(self: *Self, buffer: *Buffer) void {
    const kv = self.watched.fetchRemove(buffer) orelse return;
    defer self.allocator.free(kv.value);
    if (self.file_store) |*file_store| file_store.unwatch(kv.value) catch {};
}

fn unwatch_all(self: *Self) void {
    var i = self.buffers.valueIterator();
    while (i.next()) |buffer| self.unwatch_buffer(buffer.*);
}

fn buffer_for_watched_path(self: *const Self, abs_path: []const u8) ?*Buffer {
    var i = self.watched.iterator();
    while (i.next()) |p|
        if (std.mem.eql(u8, p.value_ptr.*, abs_path))
            return p.key_ptr.*;
    return null;
}

pub fn receive_file_store_message(self: *Self, from: tp.pid_ref, m: tp.message) LoadResult {
    if (FileStore.reply_id(m)) |id| {
        if (self.saves.contains(id)) {
            self.save_progress(id, m);
            return .nochange;
        }
        return self.load_progress(id, m);
    }
    var path: []const u8 = undefined;
    var from_path: []const u8 = undefined;
    var event_type: FileStore.EventType = undefined;
    var object_type: FileStore.ObjectType = undefined;
    if (m.match(.{ "FS", "change", tp.extract(&path), tp.extract(&event_type), tp.extract(&object_type) }) catch false) {
        self.file_changed(path, event_type, object_type);
    } else if (m.match(.{ "FS", "rename", tp.extract(&from_path), tp.extract(&path), tp.extract(&object_type) }) catch false) {
        self.file_renamed(from_path, path, object_type);
    } else if (m.match(.{ "FS", "ready" }) catch false) {
        self.set_file_store(.{ .pid = from.clone() });
    }
    return .nochange;
}

fn file_changed(self: *Self, abs_path: []const u8, event_type: FileStore.EventType, object_type: FileStore.ObjectType) void {
    const buffer = self.buffer_for_watched_path(abs_path) orelse return;
    log.debug("file {t}: {s} ({t})", .{ event_type, buffer.get_file_path(), object_type });
}

fn file_renamed(self: *Self, from_path: []const u8, to_path: []const u8, object_type: FileStore.ObjectType) void {
    if (self.buffer_for_watched_path(from_path)) |buffer|
        log.debug("file renamed: {s} -> {s} ({t})", .{ buffer.get_file_path(), to_path, object_type });
    if (self.buffer_for_watched_path(to_path)) |buffer|
        log.debug("file replaced: {s} <- {s} ({t})", .{ buffer.get_file_path(), from_path, object_type });
}

const log = std.log.scoped(.buffer_manager);
const perf_log = std.log.scoped(.buffer_io);
