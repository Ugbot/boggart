//! Optional independent SDK allocator capture; never linked into Boggart.
const std = @import("std");
const bitmap = @import("terminal/bitmap_allocator.zig");
const size = @import("terminal/size.zig");
const inputs = @import("bmux_bitmap_cases.zig");
const allocator = std.heap.page_allocator;
fn capture(c: inputs.Case, comptime chunk: usize) !void {
    const Arena = bitmap.BitmapAllocator(chunk);
    const layout = Arena.layout(c.capacity);
    const memory = try allocator.alignedAlloc(u8, .@"8", layout.total_size);
    defer allocator.free(memory);
    var arena = Arena.init(size.OffsetBuf.init(memory), layout);
    var slots: [256]?[]u8 = @splat(null);
    for (c.operations, 0..) |operation, step| {
        var offset: ?usize = null;
        switch (operation) {
            .allocate => |a| {
                std.debug.assert(slots[a.slot] == null);
                const slice = arena.alloc(u8, memory, a.bytes) catch null;
                if (slice) |s| {
                    slots[a.slot] = s;
                    offset = @intFromPtr(s.ptr) - @intFromPtr(arena.chunks.ptr(memory));
                }
            },
            .free => |slot| {
                arena.free(memory, slots[slot].?);
                slots[slot] = null;
            },
            .move => |move| {
                std.debug.assert(slots[move.to] == null);
                slots[move.to] = slots[move.from].?;
                slots[move.from] = null;
            },
            .forget => |slot| slots[slot] = null,
        }
        const words = arena.bitmap.ptr(memory)[0..arena.bitmap_count];
        const masks = try allocator.alloc([]const u8, words.len);
        defer allocator.free(masks);
        for (words, masks) |word, *mask| mask.* = try std.fmt.allocPrint(allocator, "{x:0>16}", .{word});
        defer for (masks) |mask| allocator.free(mask);
        const result = try std.json.Stringify.valueAlloc(allocator, .{
            .name = c.name, .step = step, .offset = offset, .bitmaps = masks,
            .capacity = arena.capacityBytes(), .used = arena.usedBytes(memory), .search_start = arena.search_start,
        }, .{});
        defer allocator.free(result);
        std.debug.print("{s}\n", .{result});
    }
}
pub fn main() !void {
    for (inputs.cases) |c| switch (c.chunk) {
        16 => try capture(c, 16),
        32 => try capture(c, 32),
        else => unreachable,
    };
}
