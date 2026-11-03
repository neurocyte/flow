//! Fetch and extract archives over HTTPS.
const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Entry = struct {
    archive_path: []const u8,
    dest_filename: []const u8,
};

/// Fetch and extract `entries` to `dest` from a zip file URL.
pub fn fetch_zip(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    sha256: [Sha256.digest_length]u8,
    dest: std.Io.Dir,
    entries: []const Entry,
) !void {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const name = try archive_name(&name_buf, url);
    defer dest.deleteFile(io, name) catch {};
    const digest = try download(io, allocator, url, dest, name);
    if (!std.mem.eql(u8, &digest, &sha256)) return error.HashMismatch;
    try extract(io, allocator, dest, name, entries);
}

fn archive_name(buf: *[std.fs.max_path_bytes]u8, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    const path = switch (uri.path) {
        .raw, .percent_encoded => |path| path,
    };
    const base = std.fs.path.basenamePosix(path);
    if (base.len == 0 or std.mem.findAny(u8, base, "\\:") != null) return error.InvalidUrl;
    return std.fmt.bufPrint(buf, ".{s}.download", .{base}) catch error.NameTooLong;
}

fn download(io: std.Io, allocator: std.mem.Allocator, url: []const u8, dest: std.Io.Dir, name: []const u8) ![Sha256.digest_length]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const file = try dest.createFile(io, name, .{});
    defer file.close(io);
    const file_buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(file_buf);
    var file_writer = file.writer(io, file_buf);
    const hash_buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(hash_buf);
    var hashed = file_writer.interface.hashed(Sha256.init(.{}), hash_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &hashed.writer,
    });
    if (result.status != .ok) return error.HttpStatus;
    try hashed.writer.flush();
    try file_writer.end();
    return hashed.hasher.finalResult();
}

fn extract(io: std.Io, allocator: std.mem.Allocator, dest: std.Io.Dir, name: []const u8, entries: []const Entry) !void {
    std.debug.assert(entries.len < 64);
    const file = try dest.openFile(io, name, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    var temp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var written: u64 = 0;
    errdefer for (entries, 0..) |entry, i| if (written & (@as(u64, 1) << @intCast(i)) != 0) {
        const temp = temp_name(&temp_buf, entry.dest_filename) catch continue;
        dest.deleteFile(io, temp) catch {};
    };

    var iter = try std.zip.Iterator.init(&reader);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |zip_entry| {
        const entry_name = try zip_entry.getFilename(&reader, &name_buf, .{});
        for (entries, 0..) |entry, i| {
            if (!std.mem.eql(u8, entry_name, entry.archive_path)) continue;
            const bit = @as(u64, 1) << @intCast(i);
            if (written & bit != 0) return error.DuplicateEntry;
            written |= bit;
            try extract_entry(io, allocator, &reader, zip_entry, dest, try temp_name(&temp_buf, entry.dest_filename));
        }
    }
    if (written != (@as(u64, 1) << @intCast(entries.len)) - 1) return error.EntryNotFound;

    for (entries) |entry|
        try dest.rename(try temp_name(&temp_buf, entry.dest_filename), dest, entry.dest_filename, io);
}

fn temp_name(buf: []u8, dest_name: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.download", .{dest_name}) catch error.NameTooLong;
}

fn extract_entry(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.File.Reader,
    zip_entry: std.zip.Iterator.Entry,
    dest: std.Io.Dir,
    name: []const u8,
) !void {
    const file = try dest.createFile(io, name, .{});
    defer file.close(io);
    const write_buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(write_buf);
    var writer = file.writer(io, write_buf);
    zip_entry.extractTo(reader, &writer.interface) catch |e| switch (e) {
        error.WriteFailed => return writer.err orelse e,
        else => return e,
    };
    try writer.end();
}

test archive_name {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(".pkg.1.0.nupkg.download", try archive_name(&buf, "https://example.com/a/b/pkg.1.0.nupkg?x=1#y"));
    try std.testing.expectEqualStrings(".a%5Cb.zip.download", try archive_name(&buf, "https://example.com/dir/a%5Cb.zip"));
    try std.testing.expectError(error.InvalidUrl, archive_name(&buf, "https://example.com/"));
    try std.testing.expectError(error.InvalidUrl, archive_name(&buf, "https://example.com"));
}
