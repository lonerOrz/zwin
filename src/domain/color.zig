const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    // Windows COLORREF layout: 0x00BBGGRR
    pub fn toColorRef(self: Color) u32 {
        return @as(u32, self.r) | (@as(u32, self.g) << 8) | (@as(u32, self.b) << 16);
    }

    pub fn fromColorRef(cref: u32) Color {
        return .{
            .r = @truncate(cref & 0xFF),
            .g = @truncate((cref >> 8) & 0xFF),
            .b = @truncate((cref >> 16) & 0xFF),
        };
    }

    // Format as #RRGGBB into a 7-byte buffer
    pub fn toHex(self: Color, buf: *[7]u8) []const u8 {
        return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
    }

    // Parse #RRGGBB or RRGGBB string
    pub fn fromHex(hex: []const u8) ?Color {
        var str = hex;
        if (std.mem.startsWith(u8, str, "#")) str = str[1..];
        if (str.len != 6) return null;
        const rgb_val = std.fmt.parseInt(u24, str, 16) catch return null;
        return .{
            .r = @truncate((rgb_val >> 16) & 0xFF),
            .g = @truncate((rgb_val >> 8) & 0xFF),
            .b = @truncate(rgb_val & 0xFF),
        };
    }
};

test "Color conversions" {
    const c = Color.fromHex("#FF8800").?;
    try std.testing.expectEqual(@as(u8, 0xFF), c.r);
    try std.testing.expectEqual(@as(u8, 0x88), c.g);
    try std.testing.expectEqual(@as(u8, 0x00), c.b);
    try std.testing.expectEqual(@as(u32, 0x000088FF), c.toColorRef());
    try std.testing.expectEqual(Color.fromColorRef(0x000088FF), c);

    var buf: [7]u8 = undefined;
    try std.testing.expectEqualStrings("#FF8800", c.toHex(&buf));

    try std.testing.expectEqual(Color.rgb(1, 2, 3), Color.fromHex("010203").?);
    try std.testing.expectEqual(@as(?Color, null), Color.fromHex("#XYZ"));
    try std.testing.expectEqual(@as(?Color, null), Color.fromHex("#12345"));
}
