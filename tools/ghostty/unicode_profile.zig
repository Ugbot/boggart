//! Optional export of the pinned SDK's actual terminal Unicode tables.
const std = @import("std");
const unicode = @import("unicode/main.zig");
const uu = @import("uucode");
fn properties(cp: u21) u16 {
    const p = unicode.table.get(cp);
    return @as(u16, p.width) | (@as(u16, @intFromBool(p.width_zero_in_grapheme)) << 2) |
        (@as(u16, @intFromEnum(p.grapheme_break)) << 3) | (@as(u16, @intFromBool(p.emoji_vs_base)) << 8);
}
pub fn main() !void {
    const classes = @typeInfo(uu.types.GraphemeBreakNoControl).@"enum".fields.len;
    inline for (@typeInfo(uu.types.GraphemeBreakNoControl).@"enum".fields) |field| {
        std.debug.print("{{\"class\":[{d},\"{s}\"]}}\n", .{ field.value, field.name });
    }
    std.debug.print("{{\"states\":{d}}}\n", .{uu.grapheme.BreakState.table_len});
    var representatives: [classes]?u21 = @splat(null);
    var start: u21 = 0;
    var value = properties(0);
    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const next = properties(cp);
        const gb = @intFromEnum(unicode.table.get(cp).grapheme_break);
        if (representatives[gb] == null) representatives[gb] = cp;
        if (next != value) {
            std.debug.print("{{\"range\":[{d},{d},{d}]}}\n", .{ start, cp - 1, value });
            start = cp; value = next;
        }
    }
    std.debug.print("{{\"range\":[{d},1114111,{d}]}}\n", .{ start, value });
    for (0..uu.grapheme.BreakState.table_len) |s| {
        for (representatives, 0..) |a, i| {
            for (representatives, 0..) |b, j| {
                var state = uu.grapheme.BreakState.fromTableIndex(s);
                const boundary = unicode.graphemeBreak(a.?, b.?, &state);
                const result = @as(u8, @intFromBool(boundary)) | (@as(u8, @intCast(state.tableIndex())) << 1);
                std.debug.print("{{\"transition\":[{d},{d}]}}\n", .{ s | (i << 3) | (j << 8), result });
            }
        }
    }
}
