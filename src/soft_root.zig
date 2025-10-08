const std = @import("std");
pub const hard_root = @import("root");

pub const root = struct {
    pub const version = if (@hasDecl(hard_root, "version")) hard_root.version else dummy.version;
    pub const version_info = if (@hasDecl(hard_root, "version_info")) hard_root.version_info else dummy.version_info;
    pub const application_name = if (@hasDecl(hard_root, "application_name")) hard_root.application_name else dummy.application_name;
    pub const application_title = if (@hasDecl(hard_root, "application_title")) hard_root.application_title else dummy.application_title;
    pub const application_subtext = if (@hasDecl(hard_root, "application_subtext")) hard_root.application_subtext else dummy.application_subtext;

    pub const get_state_dir = if (@hasDecl(hard_root, "get_state_dir")) hard_root.get_state_dir else dummy.get_state_dir;
    pub const get_config_dir = if (@hasDecl(hard_root, "get_config_dir")) hard_root.get_config_dir else dummy.get_config_dir;
    pub const write_config_to_writer = if (@hasDecl(hard_root, "write_config_to_writer")) hard_root.write_config_to_writer else dummy.write_config_to_writer;
    pub const parse_text_config_file = if (@hasDecl(hard_root, "parse_text_config_file")) hard_root.parse_text_config_file else dummy.parse_text_config_file;
    pub const list_keybind_namespaces = if (@hasDecl(hard_root, "list_keybind_namespaces")) hard_root.list_keybind_namespaces else dummy.list_keybind_namespaces;
    pub const read_keybind_namespace = if (@hasDecl(hard_root, "read_keybind_namespace")) hard_root.read_keybind_namespace else dummy.read_keybind_namespace;
    pub const write_keybind_namespace = if (@hasDecl(hard_root, "write_keybind_namespace")) hard_root.write_keybind_namespace else dummy.write_keybind_namespace;
    pub const get_keybind_namespace_file_name = if (@hasDecl(hard_root, "get_keybind_namespace_file_name")) hard_root.get_keybind_namespace_file_name else dummy.get_keybind_namespace_file_name;

    pub const ConfigDirError = if (@hasDecl(hard_root, "ConfigDirError")) hard_root.ConfigDirError else dummy.ConfigDirError;
    pub const ConfigWriteError = if (@hasDecl(hard_root, "ConfigWriteError")) hard_root.ConfigWriteError else dummy.ConfigWriteError;

    pub const free_config = if (@hasDecl(hard_root, "free_config")) hard_root.free_config else dummy.free_config;
    pub const read_config = if (@hasDecl(hard_root, "read_config")) hard_root.read_config else dummy.read_config;
    pub const write_config = if (@hasDecl(hard_root, "write_config")) hard_root.write_config else dummy.write_config;
    pub const exists_config = if (@hasDecl(hard_root, "exists_config")) hard_root.exists_config else dummy.exists_config;
    pub const get_config_file_name = if (@hasDecl(hard_root, "get_config_file_name")) hard_root.get_config_file_name else dummy.get_config_file_name;
    pub const get_restore_file_name = if (@hasDecl(hard_root, "get_restore_file_name")) hard_root.get_restore_file_name else dummy.get_restore_file_name;

    pub const read_theme = if (@hasDecl(hard_root, "read_theme")) hard_root.read_theme else dummy.read_theme;
    pub const write_theme = if (@hasDecl(hard_root, "write_theme")) hard_root.write_theme else dummy.write_theme;
    pub const get_theme_file_name = if (@hasDecl(hard_root, "get_theme_file_name")) hard_root.get_theme_file_name else dummy.get_theme_file_name;

    pub const exit = if (@hasDecl(hard_root, "exit")) hard_root.exit else dummy.exit;
    pub const print_exit_status = if (@hasDecl(hard_root, "print_exit_status")) hard_root.print_exit_status else dummy.print_exit_status;

    pub const is_directory = if (@hasDecl(hard_root, "is_directory")) hard_root.is_directory else dummy.is_directory;
    pub const is_file = if (@hasDecl(hard_root, "is_file")) hard_root.is_file else dummy.is_file;

    pub const shorten_path = if (@hasDecl(hard_root, "shorten_path")) hard_root.shorten_path else dummy.shorten_path;

    pub const max_diff_lines = if (@hasDecl(hard_root, "max_diff_lines")) hard_root.max_diff_lines else dummy.max_diff_lines;
    pub const max_syntax_lines = if (@hasDecl(hard_root, "max_syntax_lines")) hard_root.max_syntax_lines else dummy.max_syntax_lines;
};

const dummy = struct {
    pub const version = "dummy-version";
    pub const version_info = "dummy-version_info";
    pub const application_name = "dummy-application_name";
    pub const application_title = "dummy-application_title";
    pub const application_subtext = "dummy-application_subtext";

    pub const max_diff_lines: usize = 50000;
    pub const max_syntax_lines: usize = 50000;

    pub const ConfigDirError = error{};
    pub const ConfigWriteError = error{};

    pub fn get_state_dir() ![]const u8 {
        @panic("dummy get_state_dir call");
    }

    pub fn get_config_dir() ConfigDirError![]const u8 {
        @panic("dummy get_state_dir call");
    }

    pub fn write_config_to_writer(comptime T: type, _: T, _: *std.Io.Writer) std.Io.Writer.Error!void {
        @panic("dummy write_config_to_writer call");
    }
    pub fn parse_text_config_file(T: type, _: std.mem.Allocator, _: *T, _: *[][]const u8, _: []const u8, _: []const u8) !void {
        @panic("dummy parse_text_config_file call");
    }
    pub fn list_keybind_namespaces(_: std.mem.Allocator) ![]const []const u8 {
        @panic("dummy list_keybind_namespaces call");
    }
    pub fn read_keybind_namespace(_: std.mem.Allocator, _: []const u8) ?[]const u8 {
        @panic("dummy read_keybind_namespace call");
    }
    pub fn write_keybind_namespace(_: []const u8, _: []const u8) !void {
        @panic("dummy write_keybind_namespace call");
    }
    pub fn get_keybind_namespace_file_name(_: []const u8) ![]const u8 {
        @panic("dummy get_keybind_namespace_file_name call");
    }

    pub fn free_config(_: std.mem.Allocator, _: [][]const u8) void {
        @panic("dummy free_config call");
    }
    pub fn read_config(T: type, _: std.mem.Allocator) struct { T, [][]const u8 } {
        @panic("dummy read_config call");
    }
    pub fn write_config(_: anytype, _: std.mem.Allocator) (ConfigDirError || ConfigWriteError)!void {
        @panic("dummy write_config call");
    }
    pub fn exists_config(_: type) bool {
        @panic("dummy exists_config call");
    }
    pub fn get_config_file_name(_: type) ![]const u8 {
        @panic("dummy get_config_file_name call");
    }
    pub fn get_restore_file_name() ![]const u8 {
        @panic("dummy get_restore_file_name call");
    }

    pub fn read_theme(_: std.mem.Allocator, _: []const u8) ?[]const u8 {
        @panic("dummy read_theme call");
    }
    pub fn write_theme(_: []const u8, _: []const u8) !void {
        @panic("dummy write_theme call");
    }
    pub fn get_theme_file_name(_: []const u8) ![]const u8 {
        @panic("dummy get_theme_file_name call");
    }

    pub fn exit(_: u8) noreturn {
        @panic("dummy exit call");
    }
    pub fn print_exit_status(_: void, _: []const u8) void {
        @panic("dummy print_exit_status call");
    }

    pub fn is_directory(_: []const u8) bool {
        @panic("dummy is_directory call");
    }
    pub fn is_file(_: []const u8) bool {
        @panic("dummy is_file call");
    }

    pub fn shorten_path(_: []u8, _: []const u8, _: *usize, _: usize) []const u8 {
        @panic("dummy shorten_path call");
    }
};
