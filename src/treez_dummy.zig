pub const InputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};
pub const Range = extern struct {
    start_point: Point = .{},
    end_point: Point = .{},
    start_byte: u32 = 0,
    end_byte: u32 = 0,
};

pub const Point = extern struct {
    row: u32 = 0,
    column: u32 = 0,
};
pub const InputEncoding = enum(c_uint) {
    utf_8,
    utf_16,
};
pub const Input = extern struct {
    payload: ?*anyopaque,
    read: ?*const fn (payload: ?*anyopaque, byte_index: u32, position: Point, bytes_read: *u32) callconv(.C) [*:0]const u8,
    encoding: InputEncoding,
};
pub const Language = struct {
    var dummy: @This() = .{};
    pub fn LangFn() callconv(.C) ?*const Language {
        return &dummy;
    }
};
pub const Parser = struct {
    var dummy: @This() = .{};
    pub fn create() !*@This() {
        return &dummy;
    }
    pub fn parse(_: *Parser, _: ?*Tree, _: Input) !*Tree {
        return &Tree.dummy;
    }
    pub fn parseString(_: *@This(), _: ?[]const u8, _: []const u8) !?*Tree {
        return null;
    }
    pub fn destroy(_: *@This()) void {}
    pub fn setLanguage(_: *Parser, _: *const Language) !void {}
};
pub const Query = struct {
    var dummy: @This() = .{};
    pub fn create(_: *const Language, _: []const u8) !*Query {
        return &dummy;
    }
    pub const Cursor = struct {
        var dummy_: @This() = .{};
        pub fn create() !*@This() {
            return &dummy_;
        }
        pub fn execute(_: *@This(), _: *Query, _: *Node) void {}
        pub fn setPointRange(_: *@This(), _: Point, _: Point) void {}
        pub fn nextMatch(_: *@This()) ?*Match {
            return null;
        }
        pub fn destroy(_: *@This()) void {}

        pub const Match = struct {
            pub fn captures(_: *@This()) []Capture {
                return &[_]Capture{};
            }
        };
        pub const Capture = struct {
            id: u32,
            node: Node,
        };
    };
    pub fn getCaptureNameForId(_: *@This(), _: u32) []const u8 {
        return "";
    }
    pub fn destroy(_: *@This()) void {}
};
pub const Tree = struct {
    var dummy: @This() = .{};
    pub fn getRootNode(_: *@This()) *Node {
        return &Node.dummy;
    }
    pub fn destroy(_: *@This()) void {}
    pub fn edit(_: *Tree, _: *const InputEdit) void {}
};
pub const Node = struct {
    var dummy: @This() = .{};
    pub fn getRange(_: *const @This()) Range {
        return .{};
    }
    pub fn asSExpressionString(_: *const @This()) []const u8 {
        return "";
    }
    pub fn freeSExpressionString(_: []const u8) void {}
    pub fn getParent(_: *const @This()) Node {
        return dummy;
    }
    pub fn getChild(_: *const @This(), _: usize) Node {
        return dummy;
    }
    pub fn getChildCount(_: *const @This()) usize {
        return 0;
    }
    pub fn getNamedChild(_: *const @This(), _: usize) Node {
        return dummy;
    }
    pub fn getNamedChildCount(_: *const @This()) usize {
        return 0;
    }
    pub fn isNull(_: *const @This()) bool {
        return true;
    }
    pub const externs = struct {
        pub fn ts_node_next_sibling(_: Node) Node {
            return Node.dummy;
        }
        pub fn ts_node_prev_sibling(_: Node) Node {
            return Node.dummy;
        }
        pub fn ts_node_next_named_sibling(_: Node) Node {
            return Node.dummy;
        }
        pub fn ts_node_prev_named_sibling(_: Node) Node {
            return Node.dummy;
        }
        pub fn ts_node_descendant_for_point_range(_: *const Node, _: Point, _: Point) Node {
            return Node.dummy;
        }
    };
};
