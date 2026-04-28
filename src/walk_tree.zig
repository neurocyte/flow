const std = @import("std");
const tp = @import("thespian");
const tracy = @import("tracy");
const root = @import("soft_root").root;

const module_name = @typeName(@This());

const SpawnError = (OutOfMemoryError || error{ThespianSpawnFailed});
const OutOfMemoryError = error{OutOfMemory};

pub const EntryCallBack = *const fn (parent: tp.pid_ref, root_path: []const u8, path: []const u8, mtime_high: i64, mtime_low: i64) error{Exit}!void;
pub const DoneCallBack = *const fn (parent: tp.pid_ref, root_path: []const u8) error{Exit}!void;

pub const Options = struct {
    follow_directory_symlinks: bool = false,
    maximum_symlink_depth: usize = 1,
    log_ignored_links: bool = false,
};

pub fn start(a_: std.mem.Allocator, root_path_: []const u8, entry_handler: EntryCallBack, done_handler: DoneCallBack, options: Options) (SpawnError || std.Io.Dir.OpenError)!tp.pid {
    return struct {
        allocator: std.mem.Allocator,
        root_path: []const u8,
        parent: tp.pid,
        receiver: Receiver,
        dir: std.Io.Dir,
        walker: FilteredWalker,
        entry_handler: EntryCallBack,
        done_handler: DoneCallBack,
        options: Options,

        const tree_walker = @This();
        const Receiver = tp.Receiver(*tree_walker);

        fn spawn_link(allocator: std.mem.Allocator, root_path: []const u8, entry_handler_: EntryCallBack, done_handler_: DoneCallBack, options_: Options) (SpawnError || std.Io.Dir.OpenError)!tp.pid {
            const io = root.get_init().io;
            const self = try allocator.create(tree_walker);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .root_path = try allocator.dupe(u8, root_path),
                .parent = tp.self_pid().clone(),
                .receiver = .init(receive, dtor, self),
                .dir = try std.Io.Dir.cwd().openDir(io, self.root_path, .{ .iterate = true }),
                .walker = try .init(io, self.dir, self.allocator, options_),
                .entry_handler = entry_handler_,
                .done_handler = done_handler_,
                .options = options_,
            };
            return tp.spawn_link(allocator, self, tree_walker.start, module_name ++ ".tree_walker");
        }

        fn start(self: *tree_walker) tp.result {
            const frame = tracy.initZone(@src(), .{ .name = "project scan" });
            defer frame.deinit();
            tp.receive(&self.receiver);
            self.next() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }

        fn dtor(self: *tree_walker) void {
            const io = root.get_init().io;
            self.walker.deinit(io);
            self.dir.close(io);
            self.allocator.free(self.root_path);
            self.parent.deinit();
            self.allocator.destroy(self);
        }

        fn receive(self: *tree_walker, _: tp.pid_ref, m: tp.message) tp.result {
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
            const io = root.get_init().io;
            if (try self.walker.next(io)) |path| {
                const stat = self.dir.statFile(io, path, .{}) catch {
                    try self.entry_handler(self.parent.ref(), self.root_path, path, 0, 0);
                    return tp.self_pid().send(.{"next"});
                };
                const mtime: i128 = @as(i128, stat.mtime.nanoseconds);
                const high: i64 = @intCast(mtime >> 64);
                const low: i64 = @truncate(mtime);
                try self.entry_handler(self.parent.ref(), self.root_path, path, high, low);
                return tp.self_pid().send(.{"next"});
            } else {
                self.done_handler(self.parent.ref(), self.root_path) catch {};
                return tp.exit_normal();
            }
        }
    }.spawn_link(a_, root_path_, entry_handler, done_handler, options);
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
    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),
    options: Options,

    const Path = []const u8;

    const StackItem = struct {
        dir: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
        dirname_len: usize,
        symlink_depth: usize,
    };

    fn init(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, options: Options) !FilteredWalker {
        var stack: std.ArrayList(FilteredWalker.StackItem) = .empty;
        errdefer stack.deinit(allocator);

        try stack.append(allocator, .{
            .dir = dir,
            .iter = dir.iterate(),
            .dirname_len = 0,
            .symlink_depth = options.maximum_symlink_depth,
        });
        _ = io;

        return .{
            .allocator = allocator,
            .stack = stack,
            .name_buffer = .empty,
            .options = options,
        };
    }

    fn deinit(self: *FilteredWalker, io: std.Io) void {
        // Close any remaining directories except the initial one (index 0 is closed by tree_walker)
        if (self.stack.items.len > 1) {
            for (self.stack.items[1..]) |*item| {
                item.dir.close(io);
            }
        }
        self.stack.deinit(self.allocator);
        self.name_buffer.deinit(self.allocator);
    }

    fn next(self: *FilteredWalker, io: std.Io) OutOfMemoryError!?Path {
        while (self.stack.items.len != 0) {
            var top = &self.stack.items[self.stack.items.len - 1];
            var containing = top;
            var dirname_len = top.dirname_len;
            if (top.iter.next(io) catch {
                var item_ = self.stack.pop();
                if (item_) |*item|
                    if (self.stack.items.len != 0) {
                        item.dir.close(io);
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
                        _ = try self.next_directory(io, &base, &top, &containing, top.symlink_depth);
                        continue;
                    },
                    .file => return self.name_buffer.items,
                    .sym_link => {
                        if (top.symlink_depth == 0) {
                            if (self.options.log_ignored_links)
                                std.log.warn("TOO MANY LINKS! ignoring symlink: {s}", .{base.name});
                            continue;
                        }
                        if (try self.next_sym_link(io, &base, &top, &containing, top.symlink_depth -| 1)) |file|
                            return file
                        else
                            continue;
                    },
                    else => continue,
                }
            } else {
                var item_ = self.stack.pop();
                if (item_) |*item|
                    if (self.stack.items.len != 0) {
                        item.dir.close(io);
                    };
            }
        }
        return null;
    }

    fn next_directory(self: *FilteredWalker, io: std.Io, base: *const std.Io.Dir.Entry, top: **StackItem, containing: **StackItem, symlink_depth: usize) !void {
        if (is_filtered_dir(base.name))
            return;
        var new_dir = top.*.dir.openDir(io, base.name, .{ .iterate = true }) catch |err| switch (err) {
            error.NameTooLong => @panic("unexpected error.NameTooLong"), // no path sep in base.name
            else => return,
        };
        {
            errdefer new_dir.close(io);
            try self.stack.append(self.allocator, .{
                .dir = new_dir,
                .iter = new_dir.iterateAssumeFirstIteration(),
                .dirname_len = self.name_buffer.items.len,
                .symlink_depth = symlink_depth,
            });
            top.* = &self.stack.items[self.stack.items.len - 1];
            containing.* = &self.stack.items[self.stack.items.len - 2];
        }
        return;
    }

    fn next_sym_link(self: *FilteredWalker, io: std.Io, base: *const std.Io.Dir.Entry, top: **StackItem, containing: **StackItem, symlink_depth: usize) !?[]const u8 {
        const st = top.*.dir.statFile(io, base.name, .{}) catch return null;
        switch (st.kind) {
            .directory => {
                if (self.options.follow_directory_symlinks)
                    _ = try self.next_directory(io, base, top, containing, symlink_depth);
                return null;
            },
            .file => return self.name_buffer.items,
            .sym_link => {
                if (symlink_depth == 0) {
                    if (self.options.log_ignored_links)
                        std.log.warn("TOO MANY LINKS! ignoring symlink: {s}", .{base.name});
                    return null;
                }
                return try self.next_sym_link(io, base, top, containing, symlink_depth -| 1);
            },
            else => return null,
        }
    }
};
