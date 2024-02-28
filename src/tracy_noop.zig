pub fn initZone(_: anytype, _: anytype) Zone {
    return .{};
}

pub const Zone = struct {
    pub fn deinit(_: @This()) void {}
};

pub fn frameMark() void {}
