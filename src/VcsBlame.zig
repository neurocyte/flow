commits: std.ArrayList(Commit) = .empty,
lines: std.ArrayList(?u16) = .empty,
content: std.ArrayList(u8) = .empty,

pub const Commit = struct {
    // {sha1} {src_line_no} {dst_line_no} {line_count}
    id: []const u8 = &.{},

    // author {text}
    author: []const u8 = &.{},

    // author-mail {email}
    @"author-mail": []const u8 = &.{},

    // author-time {timestamp}
    @"author-time": i64 = 0,

    // author-tz {TZ}
    @"author-tz": i16 = 0,

    // committer {text}
    // committer-mail {email}
    // committer-time {timestamp}
    // committer-tz {TZ}

    // summary {text}
    summary: []const u8 = &.{},

    // previous {sha1} {filename}
    // filename {filename}
};

pub fn getLine(self: *const @This(), line: usize) ?*const Commit {
    if (line >= self.lines.items.len) return null;
    const commit_no = self.lines.items[line] orelse return null;
    return &self.commits.items[commit_no];
}

pub fn addContent(self: *@This(), allocator: std.mem.Allocator, content: []const u8) error{OutOfMemory}!void {
    return self.content.appendSlice(allocator, content);
}

pub const Error = error{
    OutOfMemory,
    InvalidBlameCommitHash,
    InvalidBlameCommitSrcLine,
    InvalidBlameCommitLine,
    InvalidBlameCommitLines,
    InvalidBlameHeaderName,
    InvalidBlameHeaderValue,
    InvalidBlameLineNo,
    InvalidBlameLines,
    InvalidAuthorTime,
    InvalidAuthorTz,
};

pub fn parse(self: *@This(), allocator: std.mem.Allocator) Error!void {
    self.commits.deinit(allocator);
    self.lines.deinit(allocator);
    self.commits = .empty;
    self.lines = .empty;

    var existing: std.StringHashMapUnmanaged(usize) = .empty;
    defer existing.deinit(allocator);

    const headers = enum { author, @"author-mail", @"author-time", @"author-tz", summary, filename };

    var state: enum { root, commit, headers } = .root;
    var commit: Commit = .{};
    var line_no: usize = 0;
    var lines: usize = 1;

    var it = std.mem.splitScalar(u8, self.content.items, '\n');
    while (it.next()) |line| {
        top: switch (state) {
            .root => {
                commit = .{};
                line_no = 0;
                lines = 0;
                state = .commit;
                continue :top .commit;
            },
            .commit => { // 35be98f95ca999a112ad3aff0932be766f702e13 141 141 1
                var arg = std.mem.splitScalar(u8, line, ' ');
                commit.id = arg.next() orelse return error.InvalidBlameCommitHash;
                _ = arg.next() orelse return error.InvalidBlameCommitSrcLine;
                line_no = std.fmt.parseInt(usize, arg.next() orelse return error.InvalidBlameCommitLine, 10) catch return error.InvalidBlameLineNo;
                lines = std.fmt.parseInt(usize, arg.next() orelse return error.InvalidBlameCommitLines, 10) catch return error.InvalidBlameLines;
                state = .headers;
            },
            .headers => {
                var arg = std.mem.splitScalar(u8, line, ' ');
                const name = arg.next() orelse return error.InvalidBlameHeaderName;
                if (name.len == line.len) return error.InvalidBlameHeaderValue;
                const value = line[name.len + 1 ..];
                if (std.meta.stringToEnum(headers, name)) |header| switch (header) {
                    .author => {
                        commit.author = value;
                    },
                    .@"author-mail" => {
                        commit.@"author-mail" = value;
                    },
                    .@"author-time" => {
                        commit.@"author-time" = std.fmt.parseInt(@TypeOf(commit.@"author-time"), value, 10) catch return error.InvalidAuthorTime;
                    },
                    .@"author-tz" => {
                        commit.@"author-tz" = std.fmt.parseInt(@TypeOf(commit.@"author-tz"), value, 10) catch return error.InvalidAuthorTz;
                    },
                    .summary => {
                        commit.summary = value;
                    },
                    .filename => {
                        line_no -|= 1;
                        const to_line_no = line_no + lines;
                        const commit_no: usize = if (existing.get(commit.id)) |n| n else blk: {
                            const n = self.commits.items.len;
                            try existing.put(allocator, commit.id, self.commits.items.len);
                            (try self.commits.addOne(allocator)).* = commit;
                            break :blk n;
                        };
                        if (self.lines.items.len < to_line_no) {
                            try self.lines.ensureTotalCapacity(allocator, to_line_no);
                            while (self.lines.items.len < to_line_no)
                                (try self.lines.addOne(allocator)).* = null;
                        }
                        for (line_no..to_line_no) |ln|
                            self.lines.items[ln] = @intCast(commit_no);

                        state = .root;
                    },
                };
            },
        }
    }
}

pub fn reset(self: *@This(), allocator: std.mem.Allocator) void {
    self.commits.deinit(allocator);
    self.lines.deinit(allocator);
    self.content.deinit(allocator);
    self.commits = .empty;
    self.lines = .empty;
    self.content = .empty;
}

const std = @import("std");
