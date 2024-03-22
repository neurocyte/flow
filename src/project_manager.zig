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
    if (pid.expired()) return;
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

pub fn request_recent_files() tp.result {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "request_recent_files", project });
}

const Process = struct {
    a: std.mem.Allocator,
    parent: tp.pid,
    logger: log.Logger,
    receiver: Receiver,
    projects: ProjectsMap,

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

        if (try m.match(.{ "walk_tree_entry", tp.extract(&project_directory), tp.extract(&path) })) {
            if (self.projects.get(project_directory)) |project|
                project.add_file(path) catch |e| self.logger.err("walk_tree_entry", e);
            // self.logger.print("file: {s}", .{path});
        } else if (try m.match(.{ "walk_tree_done", tp.extract(&project_directory) })) {
            const project = self.projects.get(project_directory) orelse return;
            self.logger.print("opened: {s} with {d} files in {d} ms", .{
                project_directory,
                project.files.count(),
                std.time.milliTimestamp() - project.open_time,
            });
        } else if (try m.match(.{ "open", tp.extract(&project_directory) })) {
            self.open(project_directory) catch |e| return from.send_raw(tp.exit_message(e));
        } else if (try m.match(.{ "request_recent_files", tp.extract(&project_directory) })) {
            self.request_recent_files(from, project_directory) catch |e| return from.send_raw(tp.exit_message(e));
        } else if (try m.match(.{"shutdown"})) {
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
            try walk_tree_async(self.a, project_directory);
        }
    }

    fn request_recent_files(self: *Process, from: tp.pid_ref, project_directory: []const u8) error{ OutOfMemory, Exit }!void {
        const project = if (self.projects.get(project_directory)) |p| p else return tp.exit("No project");
        return project.request_recent_files(from);
    }
};

const Project = struct {
    a: std.mem.Allocator,
    name: []const u8,
    files: FilesMap,
    open_time: i64,

    const FilesMap = std.StringHashMap(void);

    fn init(a: std.mem.Allocator, name: []const u8) error{OutOfMemory}!Project {
        return .{
            .a = a,
            .name = try a.dupe(u8, name),
            .files = FilesMap.init(a),
            .open_time = std.time.milliTimestamp(),
        };
    }

    fn deinit(self: *Project) void {
        var i = self.files.iterator();
        while (i.next()) |p| self.a.free(p.key_ptr.*);
        self.files.deinit();
        self.a.free(self.name);
    }

    fn add_file(self: *Project, path: []const u8) error{OutOfMemory}!void {
        if (self.files.get(path) != null) return;
        try self.files.put(try self.a.dupe(u8, path), {});
    }

    fn request_recent_files(self: *Project, from: tp.pid_ref) error{ OutOfMemory, Exit }!void {
        var i = self.files.iterator();
        while (i.next()) |file| {
            try from.send(.{ "PRJ", "recent", file.key_ptr.* });
        }
    }
};

fn walk_tree_async(a_: std.mem.Allocator, root_path_: []const u8) tp.result {
    return struct {
        a: std.mem.Allocator,
        root_path: []const u8,
        parent: tp.pid,

        const tree_walker = @This();

        fn spawn_link(a: std.mem.Allocator, root_path: []const u8) tp.result {
            const self = a.create(tree_walker) catch |e| return tp.exit_error(e);
            self.* = tree_walker.init(a, root_path) catch |e| return tp.exit_error(e);
            const pid = tp.spawn_link(a, self, tree_walker.start, module_name ++ ".tree_walker") catch |e| return tp.exit_error(e);
            pid.deinit();
        }

        fn init(a: std.mem.Allocator, root_path: []const u8) error{OutOfMemory}!tree_walker {
            return .{
                .a = a,
                .root_path = try a.dupe(u8, root_path),
                .parent = tp.self_pid().clone(),
            };
        }

        fn start(self: *tree_walker) tp.result {
            self.walk() catch |e| return tp.exit_error(e);
            return tp.exit_normal();
        }

        fn deinit(self: *tree_walker) void {
            self.a.free(self.root_path);
            self.parent.deinit();
        }

        fn walk(self: *tree_walker) !void {
            const frame = tracy.initZone(@src(), .{ .name = "project scan" });
            defer frame.deinit();
            defer {
                self.parent.send(.{ "walk_tree_done", self.root_path }) catch {};
                self.deinit();
            }
            var dir = try std.fs.cwd().openDir(self.root_path, .{ .iterate = true });
            defer dir.close();

            var walker = try walk_filtered(dir, self.a);
            defer walker.deinit();

            while (try walker.next()) |path|
                try self.parent.send(.{ "walk_tree_entry", self.root_path, path });
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
                            error.NameTooLong => unreachable, // no path sep in base.name
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
