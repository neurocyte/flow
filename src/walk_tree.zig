const std = @import("std");
const tp = @import("thespian");
const tracy = @import("tracy");

const module_name = @typeName(@This());

const SpawnError = (OutOfMemoryError || error{ThespianSpawnFailed});
const OutOfMemoryError = error{OutOfMemory};

pub const EntryCallBack = *const fn (parent: tp.pid_ref, root_path: []const u8, path: []const u8, mtime_high: i64, mtime_low: i64) error{Exit}!void;
pub const DoneCallBack = *const fn (parent: tp.pid_ref, root_path: []const u8) error{Exit}!void;

pub fn start(a_: std.mem.Allocator, root_path_: []const u8, entry_handler: EntryCallBack, done_handler: DoneCallBack) (SpawnError || std.fs.Dir.OpenError)!tp.pid {
    return struct {
        allocator: std.mem.Allocator,
        root_path: []const u8,
        parent: tp.pid,
        receiver: Receiver,
        dir: std.fs.Dir,
        walker: FilteredWalker,
        entry_handler: EntryCallBack,
        done_handler: DoneCallBack,

        const tree_walker = @This();
        const Receiver = tp.Receiver(*tree_walker);

        fn spawn_link(allocator: std.mem.Allocator, root_path: []const u8, entry_handler_: EntryCallBack, done_handler_: DoneCallBack) (SpawnError || std.fs.Dir.OpenError)!tp.pid {
            const self = try allocator.create(tree_walker);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .root_path = try allocator.dupe(u8, root_path),
                .parent = tp.self_pid().clone(),
                .receiver = .init(tree_walker.receive, self),
                .dir = try std.fs.cwd().openDir(self.root_path, .{ .iterate = true }),
                .walker = try .init(self.dir, self.allocator),
                .entry_handler = entry_handler_,
                .done_handler = done_handler_,
            };
            return tp.spawn_link(allocator, self, tree_walker.start, module_name ++ ".tree_walker");
        }

        fn start(self: *tree_walker) tp.result {
            errdefer self.deinit();
            const frame = tracy.initZone(@src(), .{ .name = "project scan" });
            defer frame.deinit();
            tp.receive(&self.receiver);
            self.next() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }

        fn deinit(self: *tree_walker) void {
            self.walker.deinit();
            self.dir.close();
            self.allocator.free(self.root_path);
            self.parent.deinit();
        }

        fn receive(self: *tree_walker, _: tp.pid_ref, m: tp.message) tp.result {
            errdefer self.deinit();
            const frame = tracy.initZone(@src(), .{ .name = "project scan" });
            defer frame.deinit();

            if (try m.match(.{"next"})) {
                self.next() catch |e| return tp.exit_error(e, @errorReturnTrace());
            } else if (try m.match(.{"stop"})) {
                return tp.exit_normal();
            } else {
                return tp.unexpected(m);
            }
        }

        fn next(self: *tree_walker) !void {
            if (try self.walker.next()) |path| {
                const stat = self.dir.statFile(path) catch {
                    try self.entry_handler(self.parent.ref(), self.root_path, path, 0, 0);
                    return tp.self_pid().send(.{"next"});
                };
                const mtime = stat.mtime;
                const high: i64 = @intCast(mtime >> 64);
                const low: i64 = @truncate(mtime);
                std.debug.assert(mtime == (@as(i128, @intCast(high)) << 64) | @as(i128, @intCast(low)));
                try self.entry_handler(self.parent.ref(), self.root_path, path, high, low);
                return tp.self_pid().send(.{"next"});
            } else {
                self.done_handler(self.parent.ref(), self.root_path) catch {};
                return tp.exit_normal();
            }
        }
    }.spawn_link(a_, root_path_, entry_handler, done_handler);
}

const filtered_dirs = [_][]const u8{
    "AppData",
    ".cache",
    ".cargo",
    ".git",
    ".jj",
    "node_modules",
    ".npm",
    ".rustup",
    ".var",
    ".zig-cache",
};

fn is_filtered_dir(dirname: []const u8) bool {
    for (filtered_dirs) |filter|
        if (std.mem.eql(u8, filter, dirname))
            return true;
    return false;
}

const FilteredWalker = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayListUnmanaged(StackItem),
    name_buffer: std.ArrayListUnmanaged(u8),

    const Path = []const u8;

    const StackItem = struct {
        iter: std.fs.Dir.Iterator,
        dirname_len: usize,
    };

    pub fn init(dir: std.fs.Dir, allocator: std.mem.Allocator) !FilteredWalker {
        var stack: std.ArrayListUnmanaged(FilteredWalker.StackItem) = .{};
        errdefer stack.deinit(allocator);

        try stack.append(allocator, .{
            .iter = dir.iterate(),
            .dirname_len = 0,
        });

        return .{
            .allocator = allocator,
            .stack = stack,
            .name_buffer = .{},
        };
    }

    pub fn deinit(self: *FilteredWalker) void {
        // Close any remaining directories except the initial one (which is always at index 0)
        if (self.stack.items.len > 1) {
            for (self.stack.items[1..]) |*item| {
                item.iter.dir.close();
            }
        }
        self.stack.deinit(self.allocator);
        self.name_buffer.deinit(self.allocator);
    }

    pub fn next(self: *FilteredWalker) OutOfMemoryError!?Path {
        while (self.stack.items.len != 0) {
            var top = &self.stack.items[self.stack.items.len - 1];
            var containing = top;
            var dirname_len = top.dirname_len;
            if (top.iter.next() catch {
                var item_ = self.stack.pop();
                if (item_) |*item|
                    if (self.stack.items.len != 0) {
                        item.iter.dir.close();
                    };
                continue;
            }) |base| {
                self.name_buffer.shrinkRetainingCapacity(dirname_len);
                if (self.name_buffer.items.len != 0) {
                    try self.name_buffer.append(self.allocator, std.fs.path.sep);
                    dirname_len += 1;
                }
                try self.name_buffer.appendSlice(self.allocator, base.name);
                switch (base.kind) {
                    .directory => {
                        _ = try self.next_directory(&base, &top, &containing);
                        continue;
                    },
                    .file => return self.name_buffer.items,
                    .sym_link => if (try self.next_sym_link(&base, &top, &containing, 5)) |file|
                        return file
                    else
                        continue,
                    else => continue,
                }
            } else {
                var item_ = self.stack.pop();
                if (item_) |*item|
                    if (self.stack.items.len != 0) {
                        item.iter.dir.close();
                    };
            }
        }
        return null;
    }

    fn next_directory(self: *FilteredWalker, base: *const std.fs.Dir.Entry, top: **StackItem, containing: **StackItem) !void {
        if (is_filtered_dir(base.name))
            return;
        var new_dir = top.*.iter.dir.openDir(base.name, .{ .iterate = true }) catch |err| switch (err) {
            error.NameTooLong => @panic("unexpected error.NameTooLong"), // no path sep in base.name
            else => return,
        };
        {
            errdefer new_dir.close();
            try self.stack.append(self.allocator, .{
                .iter = new_dir.iterateAssumeFirstIteration(),
                .dirname_len = self.name_buffer.items.len,
            });
            top.* = &self.stack.items[self.stack.items.len - 1];
            containing.* = &self.stack.items[self.stack.items.len - 2];
        }
        return;
    }

    fn next_sym_link(self: *FilteredWalker, base: *const std.fs.Dir.Entry, top: **StackItem, containing: **StackItem, stat_depth: usize) !?[]const u8 {
        if (stat_depth == 0) return null;
        const st = top.*.iter.dir.statFile(base.name) catch return null;
        switch (st.kind) {
            .directory => {
                _ = try self.next_directory(base, top, containing);
                return null;
            },
            .file => return self.name_buffer.items,
            .sym_link => return try self.next_sym_link(base, top, containing, stat_depth - 1),
            else => return null,
        }
    }
};
