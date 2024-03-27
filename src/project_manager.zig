const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const tracy = @import("tracy");

pid: tp.pid_ref,

const Self = @This();
const module_name = @typeName(Self);

pub fn get() error{Exit}!Self {
    const pid = tp.env.get().proc(module_name);
    return if (pid.expired()) create() else .{ .pid = pid };
}

fn create() error{Exit}!Self {
    const pid = Process.create() catch |e| return tp.exit_error(e);
    defer pid.deinit();
    tp.env.get().proc_set(module_name, pid.ref());
    return .{ .pid = tp.env.get().proc(module_name) };
}

pub fn shutdown() void {
    const pid = tp.env.get().proc(module_name);
    if (pid.expired()) {
        tp.self_pid().send(.{ "project_manager", "shutdown" }) catch {};
        return;
    }
    pid.send(.{"shutdown"}) catch {};
}

pub fn open_cwd() tp.result {
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "(none)";
    return open(cwd);
}

pub fn open(project_directory: []const u8) tp.result {
    tp.env.get().str_set("project", project_directory);
    return (try get()).pid.send(.{ "open", project_directory });
}

pub fn request_recent_files(max: usize) tp.result {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "request_recent_files", project, max });
}

const Process = struct {
    a: std.mem.Allocator,
    parent: tp.pid,
    logger: log.Logger,
    receiver: Receiver,
    projects: ProjectsMap,
    walker: ?tp.pid = null,

    const Receiver = tp.Receiver(*Process);
    const ProjectsMap = std.StringHashMap(*Project);

    fn create() !tp.pid {
        const a = std.heap.c_allocator;
        const self = try a.create(Process);
        self.* = .{
            .a = a,
            .parent = tp.self_pid().clone(),
            .logger = log.logger(module_name),
            .receiver = Receiver.init(Process.receive, self),
            .projects = ProjectsMap.init(a),
        };
        return tp.spawn_link(self.a, self, Process.start, module_name) catch |e| tp.exit_error(e);
    }

    fn deinit(self: *Process) void {
        var i = self.projects.iterator();
        while (i.next()) |p| {
            self.a.free(p.key_ptr.*);
            p.value_ptr.*.deinit();
            self.a.destroy(p.value_ptr.*);
        }
        self.projects.deinit();
        self.parent.deinit();
        self.a.destroy(self);
    }

    fn start(self: *Process) tp.result {
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        var project_directory: []const u8 = undefined;
        var path: []const u8 = undefined;
        var high: i64 = 0;
        var low: i64 = 0;
        var max: usize = 0;

        if (try m.match(.{ "walk_tree_entry", tp.extract(&project_directory), tp.extract(&path), tp.extract(&high), tp.extract(&low) })) {
            const mtime = (@as(i128, @intCast(high)) << 64) | @as(i128, @intCast(low));
            if (self.projects.get(project_directory)) |project|
                project.add_file(path, mtime) catch |e| self.logger.err("walk_tree_entry", e);
            // self.logger.print("file: {s}", .{path});
        } else if (try m.match(.{ "walk_tree_done", tp.extract(&project_directory) })) {
            if (self.walker) |pid| pid.deinit();
            self.walker = null;
            const project = self.projects.get(project_directory) orelse return;
            project.sort_files_by_mtime();
            self.logger.print("opened: {s} with {d} files in {d} ms", .{
                project_directory,
                project.files.items.len,
                std.time.milliTimestamp() - project.open_time,
            });
        } else if (try m.match(.{ "open", tp.extract(&project_directory) })) {
            self.open(project_directory) catch |e| return from.send_raw(tp.exit_message(e));
        } else if (try m.match(.{ "request_recent_files", tp.extract(&project_directory), tp.extract(&max) })) {
            self.request_recent_files(from, project_directory, max) catch |e| return from.send_raw(tp.exit_message(e));
        } else if (try m.match(.{"shutdown"})) {
            if (self.walker) |pid| pid.send(.{"stop"}) catch {};
            try from.send(.{ "project_manager", "shutdown" });
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", "normal" })) {
            return;
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }

    fn open(self: *Process, project_directory: []const u8) error{ OutOfMemory, Exit }!void {
        self.logger.print("opening: {s}", .{project_directory});
        if (self.projects.get(project_directory) == null) {
            const project = try self.a.create(Project);
            project.* = try Project.init(self.a, project_directory);
            try self.projects.put(try self.a.dupe(u8, project_directory), project);
            self.walker = try walk_tree_async(self.a, project_directory);
        }
    }

    fn request_recent_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize) error{ OutOfMemory, Exit }!void {
        const project = if (self.projects.get(project_directory)) |p| p else return tp.exit("No project");
        project.sort_files_by_mtime();
        return project.request_recent_files(from, max);
    }
};

const Project = struct {
    a: std.mem.Allocator,
    name: []const u8,
    files: std.ArrayList(File),
    open_time: i64,

    const File = struct {
        path: []const u8,
        mtime: i128,
    };

    fn init(a: std.mem.Allocator, name: []const u8) error{OutOfMemory}!Project {
        return .{
            .a = a,
            .name = try a.dupe(u8, name),
            .files = std.ArrayList(File).init(a),
            .open_time = std.time.milliTimestamp(),
        };
    }

    fn deinit(self: *Project) void {
        for (self.files.items) |file| self.a.free(file.path);
        self.files.deinit();
        self.a.free(self.name);
    }

    fn add_file(self: *Project, path: []const u8, mtime: i128) error{OutOfMemory}!void {
        (try self.files.addOne()).* = .{ .path = try self.a.dupe(u8, path), .mtime = mtime };
    }

    fn sort_files_by_mtime(self: *Project) void {
        const less_fn = struct {
            fn less_fn(_: void, lhs: File, rhs: File) bool {
                return lhs.mtime > rhs.mtime;
            }
        }.less_fn;
        std.mem.sort(File, self.files.items, {}, less_fn);
    }

    fn request_recent_files(self: *Project, from: tp.pid_ref, max: usize) error{ OutOfMemory, Exit }!void {
        for (self.files.items, 0..) |file, i| {
            try from.send(.{ "PRJ", "recent", file.path });
            if (i >= max) return;
        }
    }
};

fn walk_tree_async(a_: std.mem.Allocator, root_path_: []const u8) error{Exit}!tp.pid {
    return struct {
        a: std.mem.Allocator,
        root_path: []const u8,
        parent: tp.pid,
        receiver: Receiver,
        dir: std.fs.Dir,
        walker: FilteredWalker,

        const tree_walker = @This();
        const Receiver = tp.Receiver(*tree_walker);

        fn spawn_link(a: std.mem.Allocator, root_path: []const u8) error{Exit}!tp.pid {
            const self = a.create(tree_walker) catch |e| return tp.exit_error(e);
            self.* = .{
                .a = a,
                .root_path = a.dupe(u8, root_path) catch |e| return tp.exit_error(e),
                .parent = tp.self_pid().clone(),
                .receiver = Receiver.init(tree_walker.receive, self),
                .dir = std.fs.cwd().openDir(self.root_path, .{ .iterate = true }) catch |e| return tp.exit_error(e),
                .walker = walk_filtered(self.dir, self.a) catch |e| return tp.exit_error(e),
            };
            return tp.spawn_link(a, self, tree_walker.start, module_name ++ ".tree_walker") catch |e| return tp.exit_error(e);
        }

        fn start(self: *tree_walker) tp.result {
            errdefer self.deinit();
            const frame = tracy.initZone(@src(), .{ .name = "project scan" });
            defer frame.deinit();
            tp.receive(&self.receiver);
            self.next() catch |e| return tp.exit_error(e);
        }

        fn deinit(self: *tree_walker) void {
            self.walker.deinit();
            self.dir.close();
            self.a.free(self.root_path);
            self.parent.deinit();
        }

        fn receive(self: *tree_walker, _: tp.pid_ref, m: tp.message) tp.result {
            errdefer self.deinit();
            const frame = tracy.initZone(@src(), .{ .name = "project scan" });
            defer frame.deinit();

            if (try m.match(.{"next"})) {
                self.next() catch |e| return tp.exit_error(e);
            } else if (try m.match(.{"stop"})) {
                return tp.exit_normal();
            } else {
                return tp.unexpected(m);
            }
        }

        fn next(self: *tree_walker) !void {
            if (try self.walker.next()) |path| {
                const stat = self.dir.statFile(path) catch return tp.self_pid().send(.{"next"});
                const mtime = stat.mtime;
                const high: i64 = @intCast(mtime >> 64);
                const low: i64 = @truncate(mtime);
                std.debug.assert(mtime == (@as(i128, @intCast(high)) << 64) | @as(i128, @intCast(low)));
                try self.parent.send(.{ "walk_tree_entry", self.root_path, path, high, low });
                return tp.self_pid().send(.{"next"});
            } else {
                self.parent.send(.{ "walk_tree_done", self.root_path }) catch {};
                return tp.exit_normal();
            }
        }
    }.spawn_link(a_, root_path_);
}

const filtered_dirs = [_][]const u8{
    ".git",
    ".cache",
    ".var",
    "zig-out",
    "zig-cache",
    ".rustup",
    ".npm",
    ".cargo",
    "node_modules",
};

fn is_filtered_dir(dirname: []const u8) bool {
    for (filtered_dirs) |filter|
        if (std.mem.eql(u8, filter, dirname))
            return true;
    return false;
}

const FilteredWalker = struct {
    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),

    const Path = []const u8;

    const StackItem = struct {
        iter: std.fs.Dir.Iterator,
        dirname_len: usize,
    };

    pub fn next(self: *FilteredWalker) error{OutOfMemory}!?Path {
        while (self.stack.items.len != 0) {
            var top = &self.stack.items[self.stack.items.len - 1];
            var containing = top;
            var dirname_len = top.dirname_len;
            if (top.iter.next() catch {
                var item = self.stack.pop();
                if (self.stack.items.len != 0) {
                    item.iter.dir.close();
                }
                continue;
            }) |base| {
                self.name_buffer.shrinkRetainingCapacity(dirname_len);
                if (self.name_buffer.items.len != 0) {
                    try self.name_buffer.append(std.fs.path.sep);
                    dirname_len += 1;
                }
                try self.name_buffer.appendSlice(base.name);
                switch (base.kind) {
                    .directory => {
                        if (is_filtered_dir(base.name))
                            continue;
                        var new_dir = top.iter.dir.openDir(base.name, .{ .iterate = true }) catch |err| switch (err) {
                            error.NameTooLong => @panic("unexpected error.NameTooLong"), // no path sep in base.name
                            else => continue,
                        };
                        {
                            errdefer new_dir.close();
                            try self.stack.append(StackItem{
                                .iter = new_dir.iterateAssumeFirstIteration(),
                                .dirname_len = self.name_buffer.items.len,
                            });
                            top = &self.stack.items[self.stack.items.len - 1];
                            containing = &self.stack.items[self.stack.items.len - 2];
                        }
                    },
                    .file => return self.name_buffer.items,
                    else => continue,
                }
            } else {
                var item = self.stack.pop();
                if (self.stack.items.len != 0) {
                    item.iter.dir.close();
                }
            }
        }
        return null;
    }

    pub fn deinit(self: *FilteredWalker) void {
        // Close any remaining directories except the initial one (which is always at index 0)
        if (self.stack.items.len > 1) {
            for (self.stack.items[1..]) |*item| {
                item.iter.dir.close();
            }
        }
        self.stack.deinit();
        self.name_buffer.deinit();
    }
};

fn walk_filtered(dir: std.fs.Dir, allocator: std.mem.Allocator) !FilteredWalker {
    var name_buffer = std.ArrayList(u8).init(allocator);
    errdefer name_buffer.deinit();

    var stack = std.ArrayList(FilteredWalker.StackItem).init(allocator);
    errdefer stack.deinit();

    try stack.append(FilteredWalker.StackItem{
        .iter = dir.iterate(),
        .dirname_len = 0,
    });

    return FilteredWalker{
        .stack = stack,
        .name_buffer = name_buffer,
    };
}
