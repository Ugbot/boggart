//! Optional arithmetic probe, compiled against the pristine SDK modules.
const std = @import("std");
const vt = @import("ghostty-vt");
const inputs = @import("bmux_page_cases.zig");
pub fn main() !void {
    for (inputs.cases) |c| {
        const adjusted: ?vt.page.Capacity = if (c.adjust == 0) null else c.cap.adjust(.{ .cols = c.adjust }) catch null;
        const initial: ?vt.page.Capacity = if (!c.initial) null else vt.page.std_capacity.adjust(.{ .cols = c.adjust }) catch blk: {
            var cap = vt.page.std_capacity; cap.cols = c.adjust; break :blk cap;
        };
        const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{
            .name = c.name, .cap = c.cap, .layout = vt.Page.layout(c.cap),
            .meta = vt.Page.MetaLayout.init(c.cap), .adjust = c.adjust,
            .adjusted = adjusted, .initial = initial,
            .shape = .{ .word_bytes = @sizeOf(usize), .page_align = std.heap.page_size_min,
                .cell_align = @max(@alignOf(vt.Cell), @min(std.atomic.cache_line, std.heap.page_size_min)) },
        }, .{});
        defer std.heap.page_allocator.free(json);
        std.debug.print("{s}\n", .{json});
    }
}
