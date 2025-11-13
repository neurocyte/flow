const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const tracy = @import("tracy");
const file_type_config = @import("file_type_config");
const root = @import("soft_root").root;
const Buffer = @import("Buffer");
const builtin = @import("builtin");

const Project = @import("Project.zig");

pid: tp.pid_ref,

const Self = @This();
const module_name = @typeName(Self);
const request_timeout = std.time.ns_per_s * 5;

pub const FilePos = Project.FilePos;

pub const Error = ProjectError || ProjectManagerError;

pub const ProjectError = error{NoProject};

const SpawnError = (OutOfMemoryError || error{ThespianSpawnFailed});
const OutOfMemoryError = error{OutOfMemory};
const FileSystemError = error{FileSystem};
const SetCwdError = if (builtin.os.tag == .windows) error{UnrecognizedVolume} else error{};
const CallError = tp.CallError;
const ProjectManagerError = (SpawnError || error{ ProjectManagerFailed, InvalidProjectDirectory });

pub fn get() SpawnError!Self {
    const pid = tp.env.get().proc(module_name);
    return if (pid.expired()) create() else .{ .pid = pid };
}

fn send(message: anytype) ProjectManagerError!void {
    return (try get()).pid.send(message) catch error.ProjectManagerFailed;
}

fn create() SpawnError!Self {
    const pid = try Process.create();
    defer pid.deinit();
    tp.env.get().proc_set(module_name, pid.ref());
    return .{ .pid = tp.env.get().proc(module_name) };
}

pub fn start() SpawnError!void {
    _ = try get();
}

pub fn shutdown() void {
    const pid = tp.env.get().proc(module_name);
    if (pid.expired()) {
        tp.self_pid().send(.{ "project_manager", "shutdown" }) catch {};
        return;
    }
    pid.send(.{"shutdown"}) catch {};
}

pub fn open(rel_project_directory: []const u8) (ProjectManagerError || FileSystemError || std.fs.File.OpenError || SetCwdError)!void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_directory = std.fs.cwd().realpath(rel_project_directory, &path_buf) catch "(none)";
    const current_project = tp.env.get().str("project");
    if (std.mem.eql(u8, current_project, project_directory)) return;
    if (!root.is_directory(project_directory)) return error.InvalidProjectDirectory;
    var dir = try std.fs.openDirAbsolute(project_directory, .{});
    try dir.setAsCwd();
    dir.close();
    tp.env.get().str_set("project", project_directory);
    return send(.{ "open", project_directory });
}

pub fn close(project_directory: []const u8) (ProjectManagerError || error{CloseCurrentProject})!void {
    const current_project = tp.env.get().str("project");
    if (std.mem.eql(u8, current_project, project_directory)) return error.CloseCurrentProject;
    return send(.{ "close", project_directory });
}

pub fn request_n_most_recent_file(allocator: std.mem.Allocator, n: usize) (CallError || ProjectError || cbor.Error)!?[]const u8 {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    const rsp = try (try get()).pid.call(allocator, request_timeout, .{ "request_n_most_recent_file", project, n });
    defer allocator.free(rsp.buf);
    var file_path: []const u8 = undefined;
    return if (try cbor.match(rsp.buf, .{tp.extract(&file_path)})) try allocator.dupe(u8, file_path) else null;
}

pub fn request_most_recent_file(allocator: std.mem.Allocator) (CallError || ProjectError || cbor.Error)!?[]const u8 {
    return request_n_most_recent_file(allocator, 0);
}

pub fn request_recent_files(max: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "request_recent_files", project, max });
}

pub fn request_new_or_modified_files(max: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "request_new_or_modified_files", project, max });
}

pub fn request_sync_with_vcs() (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "sync_with_vcs", project });
}

pub fn request_recent_projects() (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    return send(.{ "request_recent_projects", project });
}

pub fn query_recent_files(max: usize, query: []const u8) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "query_recent_files", project, max, query });
}

pub fn query_new_or_modified_files(max: usize, query: []const u8) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "query_new_or_modified_files", project, max, query });
}

pub fn request_path_files(max: usize, path: []const u8) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "request_path_files", project, max, path });
}

pub fn request_tasks(allocator: std.mem.Allocator) (ProjectError || CallError)!tp.message {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return (try get()).pid.call(allocator, request_timeout, .{ "request_tasks", project });
}

pub fn request_vcs_status() (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "request_vcs_status", project });
}

pub fn add_task(task: []const u8) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "add_task", project, task });
}

pub fn delete_task(task: []const u8) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "delete_task", project, task });
}

pub fn did_open(file_path: []const u8, file_type: file_type_config, version: usize, text: []const u8, ephemeral: bool) (ProjectManagerError || ProjectError)!void {
    if (ephemeral) return;
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    const text_ptr: usize = if (text.len > 0) @intFromPtr(text.ptr) else 0;
    const language_server = file_type.language_server orelse return;
    return send(.{ "did_open", project, file_path, file_type.name, language_server, version, text_ptr, text.len });
}

pub fn did_change(file_path: []const u8, version: usize, text_dst: []const u8, text_src: []const u8, eol_mode: Buffer.EolMode) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    const text_dst_ptr: usize = if (text_dst.len > 0) @intFromPtr(text_dst.ptr) else 0;
    const text_src_ptr: usize = if (text_src.len > 0) @intFromPtr(text_src.ptr) else 0;
    return send(.{ "did_change", project, file_path, version, text_dst_ptr, text_dst.len, text_src_ptr, text_src.len, @intFromEnum(eol_mode) });
}

pub fn did_save(file_path: []const u8) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "did_save", project, file_path });
}

pub fn did_close(file_path: []const u8) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "did_close", project, file_path });
}

pub fn goto_definition(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "goto_definition", project, file_path, row, col });
}

pub fn goto_declaration(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "goto_declaration", project, file_path, row, col });
}

pub fn goto_implementation(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "goto_implementation", project, file_path, row, col });
}

pub fn goto_type_definition(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "goto_type_definition", project, file_path, row, col });
}

pub fn references(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "references", project, file_path, row, col });
}

pub fn highlight_references(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "highlight_references", project, file_path, row, col });
}

pub fn completion(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "completion", project, file_path, row, col });
}

pub fn symbols(file_path: []const u8) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "symbols", project, file_path });
}

pub fn rename_symbol(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "rename_symbol", project, file_path, row, col });
}

pub fn hover(file_path: []const u8, row: usize, col: usize) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "hover", project, file_path, row, col });
}

pub fn update_mru(file_path: []const u8, row: usize, col: usize, ephemeral: bool) (ProjectManagerError || ProjectError)!void {
    if (ephemeral) return;
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;
    return send(.{ "update_mru", project, file_path, row, col });
}

pub fn get_mru_position(allocator: std.mem.Allocator, file_path: []const u8, ctx: anytype) (ProjectManagerError || ProjectError)!void {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return error.NoProject;

    const cp = @import("completion.zig");
    return cp.send(allocator, (try get()).pid, .{ "get_mru_position", project, file_path }, ctx);
}

const Process = struct {
    allocator: std.mem.Allocator,
    parent: tp.pid,
    logger: log.Logger,
    receiver: Receiver,
    projects: ProjectsMap,

    const InvalidArgumentError = error{InvalidArgument};
    const UnsupportedError = error{Unsupported};

    const Receiver = tp.Receiver(*Process);
    const ProjectsMap = std.StringHashMapUnmanaged(*Project);
    const RecentProject = struct {
        name: []const u8,
        last_used: i128,
    };

    fn create() SpawnError!tp.pid {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(Process);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .parent = tp.self_pid().clone(),
            .logger = log.logger(module_name),
            .receiver = Receiver.init(Process.receive, self),
            .projects = .empty,
        };
        return tp.spawn_link(self.allocator, self, Process.start, module_name);
    }

    fn deinit(self: *Process) void {
        var i = self.projects.iterator();
        while (i.next()) |p| {
            self.allocator.free(p.key_ptr.*);
            p.value_ptr.*.deinit();
            self.allocator.destroy(p.value_ptr.*);
        }
        self.projects.deinit(self.allocator);
        self.parent.deinit();
        self.logger.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *Process) tp.result {
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        return self.receive_safe(from, m) catch |e| switch (e) {
            error.ExitNormal => tp.exit_normal(),
            error.ClientFailed => {
                const err = tp.exit_error(e, @errorReturnTrace());
                self.logger.err("receive", err);
                return err;
            },
            else => {
                const err = tp.exit_error(e, @errorReturnTrace());
                self.logger.err("receive", err);
            },
        };
    }

    fn receive_safe(self: *Process, from: tp.pid_ref, m: tp.message) (error{ ExitNormal, ClientFailed } || cbor.Error)!void {
        var project_directory: []const u8 = undefined;
        var path: []const u8 = undefined;
        var query: []const u8 = undefined;
        var file_type: []const u8 = undefined;
        var language_server: []const u8 = undefined;
        var method: []const u8 = undefined;
        var cbor_id: []const u8 = undefined;
        var params_cb: []const u8 = undefined;
        var max: usize = 0;
        var row: usize = 0;
        var col: usize = 0;
        var version: usize = 0;
        var text_ptr: usize = 0;
        var text_len: usize = 0;
        var text_dst_ptr: usize = 0;
        var text_dst_len: usize = 0;
        var text_src_ptr: usize = 0;
        var text_src_len: usize = 0;
        var n: usize = 0;
        var task: []const u8 = undefined;
        var context: usize = undefined;
        var tag: []const u8 = undefined;
        var message: []const u8 = undefined;

        var eol_mode: Buffer.EolModeTag = @intFromEnum(Buffer.EolMode.lf);

        if (try cbor.match(m.buf, .{ "walk_tree_entry", tp.extract(&project_directory), tp.more })) {
            if (self.projects.get(project_directory)) |project|
                project.walk_tree_entry(m) catch |e| self.logger.err("walk_tree_entry", e);
        } else if (try cbor.match(m.buf, .{ "walk_tree_done", tp.extract(&project_directory) })) {
            if (self.projects.get(project_directory)) |project|
                project.walk_tree_done(self.parent.ref()) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "git", tp.extract(&context), tp.more })) {
            const project: *Project = @ptrFromInt(context);
            project.process_git(self.parent.ref(), m) catch {};
        } else if (try cbor.match(m.buf, .{ "update_mru", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.update_mru(project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "child", tp.extract(&project_directory), tp.extract(&language_server), "notify", tp.extract(&method), tp.extract_cbor(&params_cb) })) {
            self.dispatch_notify(project_directory, language_server, method, params_cb) catch |e| return self.logger.err("lsp-handling", e);
        } else if (try cbor.match(m.buf, .{ "child", tp.extract(&project_directory), tp.extract(&language_server), "request", tp.extract(&method), tp.extract_cbor(&cbor_id), tp.extract_cbor(&params_cb) })) {
            self.dispatch_request(from, project_directory, language_server, method, cbor_id, params_cb) catch |e| return self.logger.err("lsp-handling", e);
        } else if (try cbor.match(m.buf, .{ "child", tp.extract(&path), "not found" })) {
            self.logger.print("executable '{s}' not found", .{path});
        } else if (try cbor.match(m.buf, .{ "child", tp.extract(&path), "done" })) {
            self.logger.print_err("lsp-handling", "child '{s}' terminated", .{path});
        } else if (try cbor.match(m.buf, .{ "open", tp.extract(&project_directory) })) {
            self.open(project_directory) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "close", tp.extract(&project_directory) })) {
            self.close(project_directory) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "request_n_most_recent_file", tp.extract(&project_directory), tp.extract(&n) })) {
            self.request_n_most_recent_file(from, project_directory, n) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "request_recent_files", tp.extract(&project_directory), tp.extract(&max) })) {
            self.request_recent_files(from, project_directory, max) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "request_new_or_modified_files", tp.extract(&project_directory), tp.extract(&max) })) {
            self.request_new_or_modified_files(from, project_directory, max) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "sync_with_vcs", tp.extract(&project_directory) })) {
            self.request_sync_with_vcs(from, project_directory) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "request_recent_projects", tp.extract(&project_directory) })) {
            self.request_recent_projects(from, project_directory) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "query_recent_files", tp.extract(&project_directory), tp.extract(&max), tp.extract(&query) })) {
            self.query_recent_files(from, project_directory, max, query) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "query_new_or_modified_files", tp.extract(&project_directory), tp.extract(&max), tp.extract(&query) })) {
            self.query_new_or_modified_files(from, project_directory, max, query) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "request_path_files", tp.extract(&project_directory), tp.extract(&max), tp.extract(&path) })) {
            self.request_path_files(from, project_directory, max, path) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "request_tasks", tp.extract(&project_directory) })) {
            self.request_tasks(from, project_directory) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "request_vcs_status", tp.extract(&project_directory) })) {
            self.request_vcs_status(from, project_directory) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "add_task", tp.extract(&project_directory), tp.extract(&task) })) {
            self.add_task(project_directory, task) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "delete_task", tp.extract(&project_directory), tp.extract(&task) })) {
            self.delete_task(project_directory, task) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "did_open", tp.extract(&project_directory), tp.extract(&path), tp.extract(&file_type), tp.extract_cbor(&language_server), tp.extract(&version), tp.extract(&text_ptr), tp.extract(&text_len) })) {
            const text = if (text_len > 0) @as([*]const u8, @ptrFromInt(text_ptr))[0..text_len] else "";
            self.did_open(project_directory, path, file_type, language_server, version, text) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "did_change", tp.extract(&project_directory), tp.extract(&path), tp.extract(&version), tp.extract(&text_dst_ptr), tp.extract(&text_dst_len), tp.extract(&text_src_ptr), tp.extract(&text_src_len), tp.extract(&eol_mode) })) {
            const text_dst = if (text_dst_len > 0) @as([*]const u8, @ptrFromInt(text_dst_ptr))[0..text_dst_len] else "";
            const text_src = if (text_src_len > 0) @as([*]const u8, @ptrFromInt(text_src_ptr))[0..text_src_len] else "";
            self.did_change(project_directory, path, version, text_dst, text_src, @enumFromInt(eol_mode)) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "did_save", tp.extract(&project_directory), tp.extract(&path) })) {
            self.did_save(project_directory, path) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "did_close", tp.extract(&project_directory), tp.extract(&path) })) {
            self.did_close(project_directory, path) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "goto_definition", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_definition(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "goto_declaration", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_declaration(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "goto_implementation", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_implementation(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "goto_type_definition", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_type_definition(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "references", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.references(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "highlight_references", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.highlight_references(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "symbols", tp.extract(&project_directory), tp.extract(&path) })) {
            self.logger.print("received to continue symbols", .{});
            self.symbols(from, project_directory, path) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "completion", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.completion(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "rename_symbol", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.rename_symbol(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "hover", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.hover(from, project_directory, path, row, col) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "get_mru_position", tp.extract(&project_directory), tp.extract(&path) })) {
            self.get_mru_position(from, project_directory, path) catch |e| return from.forward_error(e, @errorReturnTrace()) catch error.ClientFailed;
        } else if (try cbor.match(m.buf, .{ "lsp", "msg", tp.extract(&tag), tp.extract(&message) })) {
            if (tp.env.get().is("lsp_verbose"))
                self.logger.print("{s}: {s}", .{ tag, message });
        } else if (try cbor.match(m.buf, .{ "lsp", "err", tp.extract(&tag), tp.extract(&message) })) {
            self.logger.print("{s} error: {s}", .{ tag, message });
        } else if (try cbor.match(m.buf, .{"shutdown"})) {
            self.persist_projects();
            from.send(.{ "project_manager", "shutdown" }) catch return error.ClientFailed;
            return error.ExitNormal;
        } else if (try cbor.match(m.buf, .{ "exit", "normal" })) {
            return;
        } else if (try cbor.match(m.buf, .{ "exit", "DEADSEND", tp.more })) {
            return;
        } else if (try cbor.match(m.buf, .{ "exit", "error.FileNotFound", tp.more })) {
            return;
        } else if (try cbor.match(m.buf, .{ "exit", "error.LspFailed", tp.more })) {
            return;
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }

    fn open(self: *Process, project_directory: []const u8) (SpawnError || std.fs.Dir.OpenError)!void {
        if (self.projects.get(project_directory)) |project| {
            project.last_used = std.time.nanoTimestamp();
            self.logger.print("switched to: {s}", .{project_directory});
        } else {
            self.logger.print("opening: {s}", .{project_directory});
            const project = try self.allocator.create(Project);
            project.* = try Project.init(self.allocator, project_directory);
            try self.projects.put(self.allocator, try self.allocator.dupe(u8, project_directory), project);
            self.restore_project(project) catch |e| self.logger.err("restore_project", e);
            project.query_git();
        }
    }

    fn close(self: *Process, project_directory: []const u8) error{}!void {
        if (self.projects.fetchRemove(project_directory)) |kv| {
            self.allocator.free(kv.key);
            self.persist_project(kv.value) catch {};
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.logger.print("closed: {s}", .{project_directory});
        }
    }

    fn request_n_most_recent_file(self: *Process, from: tp.pid_ref, project_directory: []const u8, n: usize) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.request_n_most_recent_file(from, n);
    }

    fn request_recent_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.request_recent_files(from, max);
    }

    fn request_sync_with_vcs(self: *Process, _: tp.pid_ref, project_directory: []const u8) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.query_git();
    }

    fn request_new_or_modified_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.request_new_or_modified_files(from, max);
    }

    fn request_recent_projects(self: *Process, from: tp.pid_ref, active_project: []const u8) (ProjectError || Project.ClientError)!void {
        var recent_projects: std.ArrayList(RecentProject) = .empty;
        defer recent_projects.deinit(self.allocator);
        self.load_recent_projects(&recent_projects) catch {};
        for (recent_projects.items) |*recent_project| {
            if (std.mem.eql(u8, active_project, recent_project.name)) {
                recent_project.last_used = std.math.maxInt(i128);
                break;
            }
        } else {
            (try recent_projects.addOne(self.allocator)).* = .{
                .name = try self.allocator.dupe(u8, active_project),
                .last_used = std.math.maxInt(i128),
            };
        }
        var iter = self.projects.iterator();
        while (iter.next()) |item| {
            for (recent_projects.items) |*recent_project| {
                if (std.mem.eql(u8, item.value_ptr.*.name, recent_project.name)) {
                    recent_project.last_used = item.value_ptr.*.last_used;
                    break;
                }
            } else {
                (try recent_projects.addOne(self.allocator)).* = .{
                    .name = try self.allocator.dupe(u8, item.value_ptr.*.name),
                    .last_used = item.value_ptr.*.last_used,
                };
            }
        }
        self.sort_projects_by_last_used(&recent_projects);
        var message: std.Io.Writer.Allocating = .init(self.allocator);
        defer message.deinit();
        const writer = &message.writer;
        try cbor.writeArrayHeader(writer, 3);
        try cbor.writeValue(writer, "PRJ");
        try cbor.writeValue(writer, "recent_projects");
        try cbor.writeArrayHeader(writer, recent_projects.items.len);
        for (recent_projects.items) |project| {
            try cbor.writeArrayHeader(writer, 2);
            try cbor.writeValue(writer, project.name);
            try cbor.writeValue(writer, if (self.projects.get(project.name)) |_| true else false);
            self.allocator.free(project.name);
        }
        from.send_raw(.{ .buf = message.written() }) catch return error.ClientFailed;
        self.logger.print("{d} projects found", .{recent_projects.items.len});
    }

    fn query_recent_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize, query: []const u8) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        const start_time = std.time.milliTimestamp();
        const matched = try project.query_recent_files(from, max, query);
        const query_time = std.time.milliTimestamp() - start_time;
        if (query_time > 250)
            self.logger.print("query \"{s}\" matched {d}/{d} in {d} ms", .{ query, matched, project.files.items.len, query_time });
    }

    fn query_new_or_modified_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize, query: []const u8) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        const start_time = std.time.milliTimestamp();
        const matched = try project.query_new_or_modified_files(from, max, query);
        const query_time = std.time.milliTimestamp() - start_time;
        if (query_time > 250)
            self.logger.print("query \"{s}\" matched {d}/{d} in {d} ms", .{ query, matched, project.files.items.len, query_time });
    }

    fn request_path_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize, path: []const u8) (ProjectError || SpawnError || std.fs.Dir.OpenError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try request_path_files_async(self.allocator, from, project, max, expand_home(self.allocator, &buf, path));
    }

    fn request_tasks(self: *Process, from: tp.pid_ref, project_directory: []const u8) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        try project.request_tasks(from);
    }

    fn add_task(self: *Process, project_directory: []const u8, task: []const u8) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        try project.add_task(task);
    }

    fn delete_task(self: *Process, project_directory: []const u8, task: []const u8) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        try project.delete_task(task);
    }

    fn request_vcs_status(self: *Process, from: tp.pid_ref, project_directory: []const u8) (ProjectError || Project.ClientError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        try project.request_vcs_status(from);
    }

    fn did_open(self: *Process, project_directory: []const u8, file_path: []const u8, file_type: []const u8, language_server: []const u8, version: usize, text: []const u8) (ProjectError || Project.StartLspError || CallError || cbor.Error)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_open" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.did_open(file_path, file_type, language_server, version, text);
    }

    fn did_change(self: *Process, project_directory: []const u8, file_path: []const u8, version: usize, text_dst: []const u8, text_src: []const u8, eol_mode: Buffer.EolMode) (ProjectError || Project.LspError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_change" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.did_change(file_path, version, text_dst, text_src, eol_mode);
    }

    fn did_save(self: *Process, project_directory: []const u8, file_path: []const u8) (ProjectError || Project.LspError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_save" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.did_save(file_path);
    }

    fn did_close(self: *Process, project_directory: []const u8, file_path: []const u8) (ProjectError || Project.LspError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_close" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.did_close(file_path);
    }

    fn goto_definition(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.SendGotoRequestError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_definition" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.goto_definition(from, file_path, row, col);
    }

    fn goto_declaration(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.SendGotoRequestError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_declaration" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.goto_declaration(from, file_path, row, col);
    }

    fn goto_implementation(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.SendGotoRequestError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_implementation" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.goto_implementation(from, file_path, row, col);
    }

    fn goto_type_definition(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.SendGotoRequestError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_type_definition" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.goto_type_definition(from, file_path, row, col);
    }

    fn references(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.SendGotoRequestError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".references" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.references(from, file_path, row, col);
    }

    fn highlight_references(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.SendGotoRequestError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".highlight_references" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.highlight_references(from, file_path, row, col);
    }

    fn symbols(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8) (ProjectError || Project.InvalidMessageError || Project.LspOrClientError || cbor.Error)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".symbols" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.symbols(from, file_path);
    }

    fn completion(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.InvalidMessageError || Project.LspOrClientError || cbor.Error)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".completion" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.completion(from, file_path, row, col);
    }

    fn rename_symbol(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.InvalidMessageError || Project.LspOrClientError || Project.GetLineOfFileError || cbor.Error)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".rename_symbol" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.rename_symbol(from, file_path, row, col);
    }

    fn hover(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || Project.InvalidMessageError || Project.LspOrClientError || cbor.Error)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".hover" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.hover(from, file_path, row, col);
    }

    fn get_mru_position(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8) (ProjectError || Project.ClientError)!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".get_mru_position" });
        defer frame.deinit();
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.get_mru_position(from, file_path);
    }

    fn update_mru(self: *Process, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) (ProjectError || OutOfMemoryError)!void {
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return project.update_mru(file_path, row, col);
    }

    fn dispatch_notify(self: *Process, project_directory: []const u8, language_server: []const u8, method: []const u8, params_cb: []const u8) (ProjectError || Project.ClientError || Project.InvalidMessageError || cbor.Error || cbor.JsonEncodeError)!void {
        _ = language_server;
        const project = self.projects.get(project_directory) orelse return error.NoProject;
        return if (std.mem.eql(u8, method, "textDocument/publishDiagnostics"))
            project.publish_diagnostics(self.parent.ref(), params_cb)
        else if (std.mem.eql(u8, method, "window/showMessage"))
            project.show_message(params_cb)
        else if (std.mem.eql(u8, method, "window/logMessage"))
            project.log_message(params_cb)
        else
            project.show_notification(method, params_cb);
    }

    fn dispatch_request(self: *Process, from: tp.pid_ref, project_directory: []const u8, language_server: []const u8, method: []const u8, cbor_id: []const u8, params_cb: []const u8) (ProjectError || Project.ClientError || cbor.Error || cbor.JsonEncodeError || UnsupportedError)!void {
        _ = language_server;
        const project = if (self.projects.get(project_directory)) |p| p else return error.NoProject;
        return if (std.mem.eql(u8, method, "client/registerCapability"))
            project.register_capability(from, cbor_id, params_cb)
        else if (std.mem.eql(u8, method, "window/workDoneProgress/create"))
            project.workDoneProgress_create(from, cbor_id, params_cb)
        else {
            const params = try cbor.toJsonAlloc(self.allocator, params_cb);
            defer self.allocator.free(params);
            self.logger.print("unsupported LSP request: {s} -> {s}", .{ method, params });
            project.unsupported_lsp_request(from, cbor_id, method) catch {};
        };
    }

    fn persist_projects(self: *Process) void {
        var i = self.projects.iterator();
        while (i.next()) |p| self.persist_project(p.value_ptr.*) catch {};
    }

    fn persist_project(self: *Process, project: *Project) !void {
        const no_persist = tp.env.get().is("no-persist");
        if (no_persist and !project.persistent) return;
        tp.trace(tp.channel.debug, .{ "persist_project", project.name });
        self.logger.print("saving: {s}", .{project.name});
        const file_name = try get_project_state_file_path(self.allocator, project);
        defer self.allocator.free(file_name);
        var file = try std.fs.createFileAbsolute(file_name, .{ .truncate = true });
        defer file.close();
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        defer writer.interface.flush() catch {};
        try project.write_state(&writer.interface);
    }

    fn restore_project(self: *Process, project: *Project) !void {
        tp.trace(tp.channel.debug, .{ "restore_project", project.name });
        const file_name = try get_project_state_file_path(self.allocator, project);
        defer self.allocator.free(file_name);
        var file = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        const stat = try file.stat();
        var buffer = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(buffer);
        const size = try file.readAll(buffer);
        try project.restore_state(buffer[0..size]);
    }

    fn get_project_state_file_path(allocator: std.mem.Allocator, project: *Project) ![]const u8 {
        const path = project.name;
        var stream: std.Io.Writer.Allocating = .init(allocator);
        defer stream.deinit();
        const writer = &stream.writer;
        _ = try writer.write(try root.get_state_dir());
        _ = try writer.writeByte(std.fs.path.sep);
        _ = try writer.write("projects");
        _ = try writer.writeByte(std.fs.path.sep);
        std.fs.makeDirAbsolute(stream.written()) catch |e| switch (e) {
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

    fn load_recent_projects(self: *Process, recent_projects: *std.ArrayList(RecentProject)) !void {
        var path: std.Io.Writer.Allocating = .init(self.allocator);
        defer path.deinit();
        const writer = &path.writer;
        _ = try writer.write(try root.get_state_dir());
        _ = try writer.writeByte(std.fs.path.sep);
        _ = try writer.write("projects");

        var dir = try std.fs.cwd().openDir(path.written(), .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            try self.read_project_name(path.written(), entry.name, recent_projects);
        }
    }

    fn read_project_name(
        self: *Process,
        state_dir: []const u8,
        file_path: []const u8,
        recent_projects: *std.ArrayList(RecentProject),
    ) !void {
        var path: std.Io.Writer.Allocating = .init(self.allocator);
        defer path.deinit();
        const writer = &path.writer;
        _ = try writer.write(state_dir);
        _ = try writer.writeByte(std.fs.path.sep);
        _ = try writer.write(file_path);

        var file = try std.fs.openFileAbsolute(path.written(), .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();
        const buffer = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(buffer);
        _ = try file.readAll(buffer);

        var iter: []const u8 = buffer;
        var name: []const u8 = undefined;
        if (cbor.matchValue(&iter, tp.extract(&name)) catch return)
            (try recent_projects.addOne(self.allocator)).* = .{ .name = try self.allocator.dupe(u8, name), .last_used = stat.mtime };
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

fn request_path_files_async(a_: std.mem.Allocator, parent_: tp.pid_ref, project_: *Project, max_: usize, path_: []const u8) (SpawnError || std.fs.Dir.OpenError)!void {
    return struct {
        allocator: std.mem.Allocator,
        project_name: []const u8,
        path: []const u8,
        parent: tp.pid,
        max: usize,
        dir: std.fs.Dir,

        const path_files = @This();
        const Receiver = tp.Receiver(*path_files);

        fn spawn_link(allocator: std.mem.Allocator, parent: tp.pid_ref, project: *Project, max: usize, path: []const u8) (SpawnError || std.fs.Dir.OpenError)!void {
            const self = try allocator.create(path_files);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .project_name = try allocator.dupe(u8, project.name),
                .path = try if (std.fs.path.isAbsolute(path))
                    allocator.dupe(u8, path)
                else
                    std.fs.path.join(allocator, &[_][]const u8{ project.name, path }),
                .parent = parent.clone(),
                .max = max,
                .dir = try std.fs.cwd().openDir(self.path, .{ .iterate = true }),
            };
            const pid = try tp.spawn_link(allocator, self, path_files.start, module_name ++ ".path_files");
            pid.deinit();
        }

        fn start(self: *path_files) tp.result {
            errdefer self.deinit();
            const frame = tracy.initZone(@src(), .{ .name = "path_files scan" });
            defer frame.deinit();
            try self.parent.link();
            self.iterate() catch |e| return tp.exit_error(e, @errorReturnTrace());
            return tp.exit_normal();
        }

        fn deinit(self: *path_files) void {
            self.dir.close();
            self.allocator.free(self.path);
            self.allocator.free(self.project_name);
            self.parent.deinit();
        }

        fn iterate(self: *path_files) !void {
            var count: usize = 0;
            var iter = self.dir.iterateAssumeFirstIteration();
            errdefer |e| self.parent.send(.{ "PRJ", "path_error", self.project_name, self.path, e }) catch {};
            while (try iter.next()) |entry| {
                const event_type = switch (entry.kind) {
                    .directory => "DIR",
                    .sym_link => "LINK",
                    .file => "FILE",
                    else => continue,
                };
                const default = file_type_config.default;
                const file_type, const icon, const color = switch (entry.kind) {
                    .directory => .{ "directory", file_type_config.folder_icon, default.color },
                    .sym_link, .file => Project.guess_path_file_type(self.path, entry.name),
                    else => .{ default.name, default.icon, default.color },
                };
                try self.parent.send(.{ "PRJ", "path_entry", self.project_name, self.path, event_type, entry.name, file_type, icon, color });
                count += 1;
                if (count >= self.max) break;
            }
            self.parent.send(.{ "PRJ", "path_done", self.project_name, self.path, count }) catch {};
        }
    }.spawn_link(a_, parent_, project_, max_, path_);
}

pub fn normalize_file_path(file_path: []const u8) []const u8 {
    const project = tp.env.get().str("project");
    const file_path_ = if (project.len == 0)
        file_path
    else if (project.len >= file_path.len)
        file_path
    else if (std.mem.eql(u8, project, file_path[0..project.len]) and file_path[project.len] == std.fs.path.sep)
        file_path[project.len + 1 ..]
    else
        file_path;
    return normalize_file_path_dot_prefix(file_path_);
}

pub fn normalize_file_path_dot_prefix(file_path: []const u8) []const u8 {
    if (file_path.len == 2 and file_path[0] == '.' and file_path[1] == std.fs.path.sep)
        return file_path;
    if (file_path.len >= 2 and file_path[0] == '.' and file_path[1] == std.fs.path.sep) {
        const file_path_ = file_path[2..];
        return if (file_path_.len > 1 and file_path_[0] == std.fs.path.sep)
            normalize_file_path_dot_prefix(file_path_[1..])
        else if (file_path_.len > 1)
            normalize_file_path_dot_prefix(file_path_)
        else
            file_path_;
    }
    return file_path;
}

pub fn abbreviate_home(buf: []u8, path: []const u8) []const u8 {
    const a = std.heap.c_allocator;
    if (builtin.os.tag == .windows) return path;
    if (!std.fs.path.isAbsolute(path)) return path;
    const homedir = std.posix.getenv("HOME") orelse return path;
    const homerelpath = std.fs.path.relative(a, homedir, path) catch return path;
    defer a.free(homerelpath);
    if (homerelpath.len == 0) {
        return "~";
    } else if (homerelpath.len > 3 and std.mem.eql(u8, homerelpath[0..3], "../")) {
        return path;
    } else {
        buf[0] = '~';
        buf[1] = '/';
        @memcpy(buf[2 .. homerelpath.len + 2], homerelpath);
        return buf[0 .. homerelpath.len + 2];
    }
}

pub fn expand_home(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), file_path: []const u8) []const u8 {
    if (builtin.os.tag == .windows) return file_path;
    if (file_path.len > 0 and file_path[0] == '~') {
        if (file_path.len > 1 and file_path[1] != std.fs.path.sep) return file_path;
        const homedir = std.posix.getenv("HOME") orelse return file_path;
        buf.appendSlice(allocator, homedir) catch return file_path;
        buf.append(allocator, std.fs.path.sep) catch return file_path;
        buf.appendSlice(allocator, file_path[2..]) catch return file_path;
        return buf.items;
    } else return file_path;
}
