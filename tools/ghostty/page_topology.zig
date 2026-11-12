//! Optional diagnostic only; built in a separate copy of the pinned SDK.
const std = @import("std");
const vt = @import("ghostty-vt");
const inputs = @import("bmux_page_cases.zig");
const alloc = std.heap.page_allocator;

const Row = struct { wrapped: bool, head: bool };
const Page = struct {
    serial: u64,
    capacity: vt.page.Capacity,
    columns: u16,
    layout_bytes: usize,
    metadata_bytes: usize,
    rows: []Row,
};

fn snapshot(t: *vt.Terminal, name: []const u8, step: usize) !void {
    var pages: std.ArrayList(Page) = .empty;
    defer {
        for (pages.items) |p| alloc.free(p.rows);
        pages.deinit(alloc);
    }
    var node = t.screens.active.pages.pages.first;
    while (node) |n| : (node = n.next) {
        const p = n.page();
        const rows = try alloc.alloc(Row, p.size.rows);
        errdefer alloc.free(rows);
        const src = p.rows.ptr(p.memory)[0..p.size.rows];
        for (rows, src) |*dst, *r| {
            const cells = p.getCells(r);
            dst.* = .{ .wrapped = r.wrap, .head = cells[p.size.cols - 1].wide == .spacer_head };
        }
        try pages.append(alloc, .{ .serial = n.serial, .capacity = p.capacity, .columns = p.size.cols,
            .layout_bytes = vt.Page.layout(p.capacity).total_size,
            .metadata_bytes = vt.Page.MetaLayout.init(p.capacity).total_size, .rows = rows });
    }
    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .name = name, .step = step, .screen = @tagName(t.screens.active_key),
        .columns = t.cols, .rows = t.rows, .pages = pages.items,
        .sdk_geometry = .{ .cell_bytes = @sizeOf(vt.Cell), .row_bytes = @sizeOf(vt.page.Row),
            .allocation_alignment = std.heap.page_size_min },
    }, .{});
    defer alloc.free(json);
    // Build/run logs go to stderr too. The driver accepts only these JSON lines.
    std.debug.print("{s}\n", .{json});
}

pub fn main() !void {
    for (inputs.cases) |c| {
        var t = try vt.Terminal.init(vt.TinyIo.init.io(), alloc, .{
            .cols = c.columns, .rows = c.rows,
            .max_scrollback_bytes = null, .max_scrollback_lines = 2000,
        });
        defer t.deinit(alloc);
        t.modes.set(.grapheme_cluster, true);
        var stream: vt.TerminalStream = .init(.{ .handler = .{ .terminal = &t }, .allocator = alloc });
        defer stream.deinit();
        try snapshot(&t, c.name, 0);
        for (c.operations, 1..) |op, step| {
            switch (op) {
                .feed => |bytes| stream.nextSlice(bytes),
                .resize => |r| try stream.handler.resize(.{ .cols = r.columns, .rows = r.rows }),
            }
            if (stream.handler.semantic_failure) return error.SemanticFailure;
            try snapshot(&t, c.name, step);
        }
    }
}
