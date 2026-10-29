const std = @import("std");
const root = @import("soft_root").root;

test "get_init: tests get the test allocator, an arena and an environment map" {
    const init = root.get_init();

    const buf = try init.gpa.alloc(u8, 16);
    init.gpa.free(buf);

    _ = try init.arena.allocator().dupe(u8, "kept until the end of the test run");

    try init.environ_map.put("FLOW_TEST_SOFT_ROOT", "1");
    defer _ = init.environ_map.swapRemove("FLOW_TEST_SOFT_ROOT");
    try std.testing.expectEqualStrings("1", root.get_init().environ_map.get("FLOW_TEST_SOFT_ROOT").?);
}
