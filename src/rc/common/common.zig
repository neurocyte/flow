pub const service_name = "flow";
pub const build_version = @embedFile("version");

pub const Track = enum { none, full };
