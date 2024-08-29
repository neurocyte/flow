const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const tracy = @import("tracy");
const FileType = @import("syntax").FileType;
const root = @import("root");

const Project = @import("Project.zig");

pid: tp.pid_ref,

const Self = @This();
const module_name = @typeName(Self);
const request_timeout = std.time.ns_per_s * 5;

pub fn get() !Self {
    const pid = tp.env.get().proc(module_name);
    return if (pid.expired()) create() else .{ .pid = pid };
}

fn create() !Self {
    const pid = try Process.create();
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

pub fn open(rel_project_directory: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_directory = std.fs.cwd().realpath(rel_project_directory, &path_buf) catch "(none)";
    var dir = try std.fs.openDirAbsolute(project_directory, .{});
    try dir.setAsCwd();
    dir.close();
    tp.env.get().str_set("project", project_directory);
    return (try get()).pid.send(.{ "open", project_directory });
}

pub fn request_most_recent_file(a: std.mem.Allocator) !?[]const u8 {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    const rsp = try (try get()).pid.call(a, request_timeout, .{ "request_most_recent_file", project });
    defer a.free(rsp.buf);
    var file_path: []const u8 = undefined;
    return if (try rsp.match(.{tp.extract(&file_path)})) try a.dupe(u8, file_path) else null;
}

pub fn request_recent_files(max: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "request_recent_files", project, max });
}

pub fn request_recent_projects(a: std.mem.Allocator) !tp.message {
    const project = tp.env.get().str("project");
    return (try get()).pid.call(a, request_timeout, .{ "request_recent_projects", project });
}

pub fn query_recent_files(max: usize, query: []const u8) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "query_recent_files", project, max, query });
}

pub fn did_open(file_path: []const u8, file_type: *const FileType, version: usize, text: []const u8) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    const text_ptr: usize = if (text.len > 0) @intFromPtr(text.ptr) else 0;
    return (try get()).pid.send(.{ "did_open", project, file_path, file_type.name, file_type.language_server, version, text_ptr, text.len });
}

pub fn did_change(file_path: []const u8, version: usize, root_dst: usize, root_src: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "did_change", project, file_path, version, root_dst, root_src });
}

pub fn did_save(file_path: []const u8) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "did_save", project, file_path });
}

pub fn did_close(file_path: []const u8) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "did_close", project, file_path });
}

pub fn goto_definition(file_path: []const u8, row: usize, col: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "goto_definition", project, file_path, row, col });
}

pub fn goto_declaration(file_path: []const u8, row: usize, col: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "goto_declaration", project, file_path, row, col });
}

pub fn goto_implementation(file_path: []const u8, row: usize, col: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "goto_implementation", project, file_path, row, col });
}

pub fn goto_type_definition(file_path: []const u8, row: usize, col: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "goto_type_definition", project, file_path, row, col });
}

pub fn references(file_path: []const u8, row: usize, col: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "references", project, file_path, row, col });
}

pub fn completion(file_path: []const u8, row: usize, col: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "completion", project, file_path, row, col });
}

pub fn update_mru(file_path: []const u8, row: usize, col: usize) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "update_mru", project, file_path, row, col });
}

pub fn get_mru_position(file_path: []const u8) !void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "get_mru_position", project, file_path });
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
    const RecentProject = struct {
        name: []const u8,
        last_used: i128,
    };

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
        return tp.spawn_link(self.a, self, Process.start, module_name);
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
        self.logger.deinit();
        self.a.destroy(self);
    }

    fn start(self: *Process) tp.result {
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        self.receive_safe(from, m) catch |e| {
            if (std.mem.eql(u8, "normal", tp.error_text()))
                return e;
            self.logger.err("receive", tp.exit_error(e, @errorReturnTrace()));
        };
    }

    fn receive_safe(self: *Process, from: tp.pid_ref, m: tp.message) !void {
        var project_directory: []const u8 = undefined;
        var path: []const u8 = undefined;
        var query: []const u8 = undefined;
        var file_type: []const u8 = undefined;
        var language_server: []const u8 = undefined;
        var method: []const u8 = undefined;
        var id: i32 = 0;
        var params_cb: []const u8 = undefined;
        var high: i64 = 0;
        var low: i64 = 0;
        var max: usize = 0;
        var row: usize = 0;
        var col: usize = 0;
        var version: usize = 0;
        var text_ptr: usize = 0;
        var text_len: usize = 0;

        var root_dst: usize = 0;
        var root_src: usize = 0;

        if (try m.match(.{ "walk_tree_entry", tp.extract(&project_directory), tp.extract(&path), tp.extract(&high), tp.extract(&low) })) {
            const mtime = (@as(i128, @intCast(high)) << 64) | @as(i128, @intCast(low));
            if (self.projects.get(project_directory)) |project|
                project.add_pending_file(
                    path,
                    mtime,
                ) catch |e| self.logger.err("walk_tree_entry", e);
        } else if (try m.match(.{ "walk_tree_done", tp.extract(&project_directory) })) {
            if (self.walker) |pid| pid.deinit();
            self.walker = null;
            self.loaded(project_directory) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "update_mru", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.update_mru(project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "child", tp.extract(&project_directory), tp.extract(&language_server), "notify", tp.extract(&method), tp.extract_cbor(&params_cb) })) {
            self.dispatch_notify(project_directory, language_server, method, params_cb) catch |e| return self.logger.err("lsp-handling", e);
        } else if (try m.match(.{ "child", tp.extract(&project_directory), tp.extract(&language_server), "request", tp.extract(&method), tp.extract(&id), tp.extract_cbor(&params_cb) })) {
            self.dispatch_request(project_directory, language_server, method, id, params_cb) catch |e| return self.logger.err("lsp-handling", e);
        } else if (try m.match(.{ "child", tp.extract(&path), "done" })) {
            self.logger.print_err("lsp-handling", "child '{s}' terminated", .{path});
        } else if (try m.match(.{ "open", tp.extract(&project_directory) })) {
            self.open(project_directory) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "request_most_recent_file", tp.extract(&project_directory) })) {
            self.request_most_recent_file(from, project_directory) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "request_recent_files", tp.extract(&project_directory), tp.extract(&max) })) {
            self.request_recent_files(from, project_directory, max) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "request_recent_projects", tp.extract(&project_directory) })) {
            self.request_recent_projects(from, project_directory) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "query_recent_files", tp.extract(&project_directory), tp.extract(&max), tp.extract(&query) })) {
            self.query_recent_files(from, project_directory, max, query) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "did_open", tp.extract(&project_directory), tp.extract(&path), tp.extract(&file_type), tp.extract_cbor(&language_server), tp.extract(&version), tp.extract(&text_ptr), tp.extract(&text_len) })) {
            const text = if (text_len > 0) @as([*]const u8, @ptrFromInt(text_ptr))[0..text_len] else "";
            self.did_open(project_directory, path, file_type, language_server, version, text) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "did_change", tp.extract(&project_directory), tp.extract(&path), tp.extract(&version), tp.extract(&root_dst), tp.extract(&root_src) })) {
            self.did_change(project_directory, path, version, root_dst, root_src) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "did_save", tp.extract(&project_directory), tp.extract(&path) })) {
            self.did_save(project_directory, path) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "did_close", tp.extract(&project_directory), tp.extract(&path) })) {
            self.did_close(project_directory, path) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "goto_definition", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_definition(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "goto_declaration", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_declaration(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "goto_implementation", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_implementation(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "goto_type_definition", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_type_definition(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "references", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.references(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "completion", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.completion(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "get_mru_position", tp.extract(&project_directory), tp.extract(&path) })) {
            self.get_mru_position(from, project_directory, path) catch |e| return from.forward_error(e, @errorReturnTrace());
        } else if (try m.match(.{"shutdown"})) {
            if (self.walker) |pid| pid.send(.{"stop"}) catch {};
            self.persist_projects();
            try from.send(.{ "project_manager", "shutdown" });
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", "normal" })) {
            return;
        } else if (try m.match(.{ "exit", "DEADSEND", tp.more })) {
            return;
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }

    fn open(self: *Process, project_directory: []const u8) !void {
        if (self.projects.get(project_directory) == null) {
            self.logger.print("opening: {s}", .{project_directory});
            const project = try self.a.create(Project);
            project.* = try Project.init(self.a, project_directory);
            try self.projects.put(try self.a.dupe(u8, project_directory), project);
            self.walker = try walk_tree_async(self.a, project_directory);
            self.restore_project(project) catch |e| self.logger.err("restore_project", e);
            project.sort_files_by_mtime();
        } else {
            self.logger.print("switched to: {s}", .{project_directory});
        }
    }

    fn loaded(self: *Process, project_directory: []const u8) error{ OutOfMemory, Exit }!void {
        const project = self.projects.get(project_directory) orelse return;
        try project.merge_pending_files();
        self.logger.print("opened: {s} with {d} files in {d} ms", .{
            project_directory,
            project.files.items.len,
            std.time.milliTimestamp() - project.open_time,
        });
    }

    fn request_most_recent_file(self: *Process, from: tp.pid_ref, project_directory: []const u8) error{ OutOfMemory, Exit }!void {
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        project.sort_files_by_mtime();
        return project.request_most_recent_file(from);
    }

    fn request_recent_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize) error{ OutOfMemory, Exit }!void {
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        project.sort_files_by_mtime();
        return project.request_recent_files(from, max);
    }

    fn request_recent_projects(self: *Process, from: tp.pid_ref, project_directory: []const u8) error{ OutOfMemory, Exit }!void {
        var recent_projects = std.ArrayList(RecentProject).init(self.a);
        defer recent_projects.deinit();
        self.load_recent_projects(&recent_projects, project_directory) catch {};
        self.sort_projects_by_last_used(&recent_projects);
        var message = std.ArrayList(u8).init(self.a);
        const writer = message.writer();
        try cbor.writeArrayHeader(writer, recent_projects.items.len);
        for (recent_projects.items) |project|
            try cbor.writeValue(writer, project.name);
        try from.send_raw(.{ .buf = message.items });
    }

    fn query_recent_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize, query: []const u8) error{ OutOfMemory, Exit }!void {
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        const start_time = std.time.milliTimestamp();
        const matched = try project.query_recent_files(from, max, query);
        const query_time = std.time.milliTimestamp() - start_time;
        if (query_time > 250)
            self.logger.print("query \"{s}\" matched {d}/{d} in {d} ms", .{ query, matched, project.files.items.len, query_time });
    }

    fn did_open(self: *Process, project_directory: []const u8, file_path: []const u8, file_type: []const u8, language_server: []const u8, version: usize, text: []const u8) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_open" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.did_open(file_path, file_type, language_server, version, text);
    }

    fn did_change(self: *Process, project_directory: []const u8, file_path: []const u8, version: usize, root_dst: usize, root_src: usize) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_change" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.did_change(file_path, version, root_dst, root_src);
    }

    fn did_save(self: *Process, project_directory: []const u8, file_path: []const u8) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_save" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.did_save(file_path);
    }

    fn did_close(self: *Process, project_directory: []const u8, file_path: []const u8) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_close" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.did_close(file_path);
    }

    fn goto_definition(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_definition" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.goto_definition(from, file_path, row, col);
    }

    fn goto_declaration(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_declaration" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.goto_declaration(from, file_path, row, col);
    }

    fn goto_implementation(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_implementation" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.goto_implementation(from, file_path, row, col);
    }

    fn goto_type_definition(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_type_definition" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.goto_type_definition(from, file_path, row, col);
    }

    fn references(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".references" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.references(from, file_path, row, col);
    }

    fn completion(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".completion" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.completion(from, file_path, row, col);
    }

    fn get_mru_position(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8) !void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".get_mru_position" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.get_mru_position(from, file_path);
    }

    fn update_mru(self: *Process, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) !void {
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return project.update_mru(file_path, row, col);
    }

    fn dispatch_notify(self: *Process, project_directory: []const u8, language_server: []const u8, method: []const u8, params_cb: []const u8) !void {
        _ = language_server;
        const project = self.projects.get(project_directory) orelse return tp.exit("No project");
        return if (std.mem.eql(u8, method, "textDocument/publishDiagnostics"))
            project.publish_diagnostics(self.parent.ref(), params_cb)
        else if (std.mem.eql(u8, method, "window/showMessage"))
            project.show_message(self.parent.ref(), params_cb)
        else if (std.mem.eql(u8, method, "window/logMessage"))
            project.show_message(self.parent.ref(), params_cb)
        else
            tp.exit_fmt("unsupported LSP notification: {s}", .{method});
    }

    fn dispatch_request(self: *Process, project_directory: []const u8, language_server: []const u8, method: []const u8, id: i32, params_cb: []const u8) !void {
        _ = self;
        _ = project_directory;
        _ = language_server;
        _ = id;
        _ = params_cb;
        return tp.exit_fmt("unsupported LSP request: {s}", .{method});
    }

    fn persist_projects(self: *Process) void {
        var i = self.projects.iterator();
        while (i.next()) |p| self.persist_project(p.value_ptr.*) catch {};
    }

    fn persist_project(self: *Process, project: *Project) !void {
        self.logger.print("saving: {s}", .{project.name});
        const file_name = try get_project_state_file_path(self.a, project);
        defer self.a.free(file_name);
        var file = try std.fs.createFileAbsolute(file_name, .{ .truncate = true });
        defer file.close();
        var buffer = std.io.bufferedWriter(file.writer());
        defer buffer.flush() catch {};
        try project.write_state(buffer.writer());
    }

    fn restore_project(self: *Process, project: *Project) !void {
        const file_name = try get_project_state_file_path(self.a, project);
        defer self.a.free(file_name);
        var file = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        const stat = try file.stat();
        var buffer = try self.a.alloc(u8, @intCast(stat.size));
        defer self.a.free(buffer);
        const size = try file.readAll(buffer);
        try project.restore_state(buffer[0..size]);
    }

    fn get_project_state_file_path(a: std.mem.Allocator, project: *Project) ![]const u8 {
        const path = project.name;
        var stream = std.ArrayList(u8).init(a);
        const writer = stream.writer();
        _ = try writer.write(try root.get_state_dir());
        _ = try writer.writeByte(std.fs.path.sep);
        _ = try writer.write("projects");
        _ = try writer.writeByte(std.fs.path.sep);
        std.fs.makeDirAbsolute(stream.items) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        for (path) |c| {
            _ = if (std.fs.path.isSep(c))
                try writer.write("__")
            else if (c == ':')
                try writer.write("___")
            else
                try writer.writeByte(c);
        }
        return stream.toOwnedSlice();
    }

    fn load_recent_projects(self: *Process, recent_projects: *std.ArrayList(RecentProject), project_directory: []const u8) !void {
        var path = std.ArrayList(u8).init(self.a);
        defer path.deinit();
        const writer = path.writer();
        _ = try writer.write(try root.get_state_dir());
        _ = try writer.writeByte(std.fs.path.sep);
        _ = try writer.write("projects");

        var dir = try std.fs.cwd().openDir(path.items, .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            try self.read_project_name(path.items, entry.name, recent_projects, project_directory);
        }
    }

    fn read_project_name(
        self: *Process,
        state_dir: []const u8,
        file_path: []const u8,
        recent_projects: *std.ArrayList(RecentProject),
        project_directory: []const u8,
    ) !void {
        var path = std.ArrayList(u8).init(self.a);
        defer path.deinit();
        const writer = path.writer();
        _ = try writer.write(state_dir);
        _ = try writer.writeByte(std.fs.path.sep);
        _ = try writer.write(file_path);

        var file = try std.fs.openFileAbsolute(path.items, .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();
        const buffer = try self.a.alloc(u8, @intCast(stat.size));
        defer self.a.free(buffer);
        _ = try file.readAll(buffer);

        var iter: []const u8 = buffer;
        var name: []const u8 = undefined;
        if (cbor.matchValue(&iter, tp.extract(&name)) catch return) {
            const last_used = if (std.mem.eql(u8, project_directory, name)) std.math.maxInt(@TypeOf(stat.mtime)) else stat.mtime;
            (try recent_projects.addOne()).* = .{ .name = try self.a.dupe(u8, name), .last_used = last_used };
        }
    }

    fn sort_projects_by_last_used(_: *Process, recent_projects: *std.ArrayList(RecentProject)) void {
        const less_fn = struct {
            fn less_fn(_: void, lhs: RecentProject, rhs: RecentProject) bool {
                return lhs.last_used > rhs.last_used;
            }
        }.less_fn;
        std.mem.sort(RecentProject, recent_projects.items, {}, less_fn);
    }
};

fn walk_tree_async(a_: std.mem.Allocator, root_path_: []const u8) !tp.pid {
    return struct {
        a: std.mem.Allocator,
        root_path: []const u8,
        parent: tp.pid,
        receiver: Receiver,
        dir: std.fs.Dir,
        walker: FilteredWalker,

        const tree_walker = @This();
        const Receiver = tp.Receiver(*tree_walker);

        fn spawn_link(a: std.mem.Allocator, root_path: []const u8) !tp.pid {
            const self = try a.create(tree_walker);
            self.* = .{
                .a = a,
                .root_path = try a.dupe(u8, root_path),
                .parent = tp.self_pid().clone(),
                .receiver = Receiver.init(tree_walker.receive, self),
                .dir = try std.fs.cwd().openDir(self.root_path, .{ .iterate = true }),
                .walker = try walk_filtered(self.dir, self.a),
            };
            return tp.spawn_link(a, self, tree_walker.start, module_name ++ ".tree_walker");
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
            self.a.free(self.root_path);
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
    ".zig-cache",
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

pub fn normalize_file_path(file_path: []const u8) []const u8 {
    const project = tp.env.get().str("project");
    if (project.len == 0) return file_path;
    if (project.len >= file_path.len) return file_path;
    if (std.mem.eql(u8, project, file_path[0..project.len]) and file_path[project.len] == std.fs.path.sep)
        return file_path[project.len + 1 ..];
    return file_path;
}
