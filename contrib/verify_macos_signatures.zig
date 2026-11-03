const std = @import("std");
const macho = std.macho;

const max_reported_pages = 10;

const Result = union(enum) {
    not_macho,
    unsigned,
    ok,
    missing_signature,
    malformed: []const u8,
    invalid: Invalid,
};

const Invalid = struct {
    bad_pages: usize = 0,
    code_pages: usize = 0,
    offsets: [max_reported_pages]u64 = undefined,

    fn add(self: *Invalid, offset: u64) void {
        if (self.bad_pages < max_reported_pages) self.offsets[self.bad_pages] = offset;
        self.bad_pages += 1;
    }
};

const Summary = struct {
    checked: usize = 0,
    failed: usize = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    if (args.len < 2) {
        try stderr.print("usage: {s} PATH...\n", .{args[0]});
        return 2;
    }

    var summary: Summary = .{};
    const cwd = std.Io.Dir.cwd();
    for (args[1..]) |path| {
        const stat = cwd.statFile(io, path, .{}) catch |e| {
            try stderr.print("{s}: {t}\n", .{ path, e });
            summary.failed += 1;
            continue;
        };
        switch (stat.kind) {
            .directory => {
                var dir = try cwd.openDir(io, path, .{ .iterate = true });
                defer dir.close(io);
                var walker = try dir.walk(init.gpa);
                defer walker.deinit();
                while (try walker.next(io)) |entry| {
                    if (entry.kind != .file) continue;
                    const full_path = try std.fs.path.join(init.gpa, &.{ path, entry.path });
                    defer init.gpa.free(full_path);
                    try check(init.gpa, io, cwd, full_path, &summary, stdout, stderr);
                }
            },
            .file => try check(init.gpa, io, cwd, path, &summary, stdout, stderr),
            else => {},
        }
    }

    if (summary.checked == 0 and summary.failed == 0) {
        try stderr.writeAll("no Mach-O binaries found\n");
        return 1;
    }
    return if (summary.failed > 0) 1 else 0;
}

fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    summary: *Summary,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const data = try dir.readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);
    const result = verify(data);
    switch (result) {
        .not_macho => return,
        .unsigned => try stdout.print("{s}: unsigned (skipped)\n", .{path}),
        .ok => try stdout.print("{s}: code signature ok\n", .{path}),
        .missing_signature => try stderr.print("{s}: INVALID: no code signature\n", .{path}),
        .malformed => |reason| try stderr.print("{s}: INVALID: cannot parse code signature: {s}\n", .{ path, reason }),
        .invalid => |invalid| {
            try stderr.print("{s}: INVALID: {d} of {d} code pages do not match their hash (file offsets", .{
                path,
                invalid.bad_pages,
                invalid.code_pages,
            });
            for (invalid.offsets[0..@min(invalid.bad_pages, max_reported_pages)]) |offset|
                try stderr.print(" 0x{x}", .{offset});
            try stderr.writeAll(")\n");
        },
    }
    summary.checked += 1;
    switch (result) {
        .not_macho, .unsigned, .ok => {},
        .missing_signature, .malformed, .invalid => summary.failed += 1,
    }
}

fn verify(data: []const u8) Result {
    if (data.len < @sizeOf(macho.mach_header_64)) return .not_macho;
    if (readLe(u32, data, 0) != macho.MH_MAGIC_64) return .not_macho;
    const cputype = readLe(u32, data, @offsetOf(macho.mach_header_64, "cputype"));
    const ncmds = readLe(u32, data, @offsetOf(macho.mach_header_64, "ncmds"));

    var off: usize = @sizeOf(macho.mach_header_64);
    const sigoff: usize = for (0..ncmds) |_| {
        if (off + @sizeOf(macho.load_command) > data.len) return .{ .malformed = "load commands out of bounds" };
        const cmd = readLe(u32, data, off);
        const cmdsize = readLe(u32, data, off + 4);
        if (cmdsize == 0) return .{ .malformed = "zero sized load command" };
        if (cmd == @backingInt(macho.LC.CODE_SIGNATURE)) {
            if (off + @sizeOf(macho.linkedit_data_command) > data.len) return .{ .malformed = "code signature command out of bounds" };
            break readLe(u32, data, off + @offsetOf(macho.linkedit_data_command, "dataoff"));
        }
        off += cmdsize;
    } else return if (cputype == @as(u32, @bitCast(macho.CPU_TYPE_ARM64))) .missing_signature else .unsigned;

    if (sigoff + @sizeOf(macho.SuperBlob) > data.len) return .{ .malformed = "superblob out of bounds" };
    if (readBe(u32, data, sigoff) != macho.CSMAGIC_EMBEDDED_SIGNATURE) return .{ .malformed = "bad superblob magic" };
    const count = readBe(u32, data, sigoff + @offsetOf(macho.SuperBlob, "count"));

    var invalid: Invalid = .{};
    var code_directories: usize = 0;
    for (0..count) |i| {
        const index = sigoff + @sizeOf(macho.SuperBlob) + i * @sizeOf(macho.BlobIndex);
        if (index + @sizeOf(macho.BlobIndex) > data.len) return .{ .malformed = "blob index out of bounds" };
        const slot = readBe(u32, data, index);
        if (slot != macho.CSSLOT_CODEDIRECTORY and
            (slot < macho.CSSLOT_ALTERNATE_CODEDIRECTORIES or slot >= macho.CSSLOT_ALTERNATE_CODEDIRECTORY_LIMIT))
            continue;
        const cd = sigoff + readBe(u32, data, index + 4);
        if (verifyCodeDirectory(data, cd, &invalid)) |reason| return .{ .malformed = reason };
        code_directories += 1;
    }
    if (code_directories == 0) return .{ .malformed = "no code directory" };
    return if (invalid.bad_pages > 0) .{ .invalid = invalid } else .ok;
}

fn verifyCodeDirectory(data: []const u8, cd: usize, invalid: *Invalid) ?[]const u8 {
    const CD = macho.CodeDirectory;
    if (cd + @offsetOf(CD, "scatterOffset") > data.len) return "code directory out of bounds";
    if (readBe(u32, data, cd) != macho.CSMAGIC_CODEDIRECTORY) return "bad code directory magic";
    const version = readBe(u32, data, cd + @offsetOf(CD, "version"));
    const hash_offset = readBe(u32, data, cd + @offsetOf(CD, "hashOffset"));
    const code_slots = readBe(u32, data, cd + @offsetOf(CD, "nCodeSlots"));
    var code_limit: u64 = readBe(u32, data, cd + @offsetOf(CD, "codeLimit"));
    const hash_size = data[cd + @offsetOf(CD, "hashSize")];
    const hash_type = data[cd + @offsetOf(CD, "hashType")];
    const page_size_log2 = data[cd + @offsetOf(CD, "pageSize")];
    if (version >= 0x20300) {
        if (cd + @offsetOf(CD, "execSegBase") > data.len) return "code directory out of bounds";
        const code_limit64 = readBe(u64, data, cd + @offsetOf(CD, "codeLimit64"));
        if (code_limit64 != 0) code_limit = code_limit64;
    }
    if (code_limit > data.len) return "code limit beyond end of file";
    if (page_size_log2 >= 64) return "bad page size";
    const page_size: u64 = if (page_size_log2 != 0) @as(u64, 1) << @intCast(page_size_log2) else code_limit;
    const hashes = cd + hash_offset;
    if (hashes + @as(usize, code_slots) * hash_size > data.len) return "hash slots out of bounds";

    invalid.code_pages += code_slots;
    for (0..code_slots) |i| {
        const start: usize = @intCast(@min(i * page_size, code_limit));
        const end: usize = @intCast(@min(start + page_size, code_limit));
        const stored = data[hashes + i * hash_size ..][0..hash_size];
        const matches = switch (hash_type) {
            macho.CS_HASHTYPE_SHA1 => hashMatches(std.crypto.hash.Sha1, data[start..end], stored),
            macho.CS_HASHTYPE_SHA256, macho.CS_HASHTYPE_SHA256_TRUNCATED => hashMatches(std.crypto.hash.sha2.Sha256, data[start..end], stored),
            macho.CS_HASHTYPE_SHA384 => hashMatches(std.crypto.hash.sha2.Sha384, data[start..end], stored),
            else => return "unknown hash type",
        } orelse return "bad hash size";
        if (!matches) invalid.add(start);
    }
    return null;
}

fn hashMatches(comptime Hash: type, page: []const u8, stored: []const u8) ?bool {
    if (stored.len > Hash.digest_length) return null;
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(page, &digest, .{});
    return std.mem.eql(u8, digest[0..stored.len], stored);
}

fn readLe(comptime T: type, data: []const u8, off: usize) T {
    return std.mem.readInt(T, data[off..][0..@sizeOf(T)], .little);
}

fn readBe(comptime T: type, data: []const u8, off: usize) T {
    return std.mem.readInt(T, data[off..][0..@sizeOf(T)], .big);
}
