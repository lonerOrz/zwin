const std = @import("std");

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    string: []const u8,
    array: std.ArrayListUnmanaged(Value),

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |*arr| {
                for (arr.items) |*item| item.deinit(allocator);
                arr.deinit(allocator);
            },
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .boolean => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| blk: {
                var new_arr = std.ArrayListUnmanaged(Value).empty;
                errdefer new_arr.deinit(allocator);
                for (arr.items) |item| {
                    try new_arr.append(allocator, try item.clone(allocator));
                }
                break :blk .{ .array = new_arr };
            },
        };
    }
};

pub const CstNode = union(enum) {
    raw: []const u8,
    table_header: struct {
        name: []const u8,
        raw_line: []const u8,
    },
    key_value: struct {
        indent: []const u8,
        key: []const u8,
        value: Value,
        trailing: []const u8,
    },

    pub fn deinit(self: *CstNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .raw => |r| allocator.free(r),
            .table_header => |*th| {
                allocator.free(th.name);
                allocator.free(th.raw_line);
            },
            .key_value => |*kv| {
                allocator.free(kv.indent);
                allocator.free(kv.key);
                kv.value.deinit(allocator);
                allocator.free(kv.trailing);
            },
        }
    }
};

pub const CstDocument = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(CstNode),

    pub fn init(allocator: std.mem.Allocator) CstDocument {
        return .{ .allocator = allocator, .nodes = .empty };
    }

    pub fn deinit(self: *CstDocument) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !CstDocument {
        var doc = CstDocument.init(allocator);
        errdefer doc.deinit();

        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, line, " \t");

            if (trimmed.len == 0 or trimmed[0] == '#') {
                try doc.nodes.append(allocator, .{ .raw = try allocator.dupe(u8, line) });
                continue;
            }

            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']' and trimmed[1] != '[') {
                const name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
                try doc.nodes.append(allocator, .{
                    .table_header = .{
                        .name = try allocator.dupe(u8, name),
                        .raw_line = try allocator.dupe(u8, line),
                    },
                });
                continue;
            }

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |_| {
                if (try parseKeyValue(allocator, line)) |kv| {
                    try doc.nodes.append(allocator, kv);
                    continue;
                }
            }

            try doc.nodes.append(allocator, .{ .raw = try allocator.dupe(u8, line) });
        }
        return doc;
    }

    pub fn setRootKeyValue(self: *CstDocument, key: []const u8, value: Value) !void {
        var in_root = true;
        for (self.nodes.items) |*node| {
            switch (node.*) {
                .table_header => in_root = false,
                .key_value => |*kv| {
                    if (in_root and std.ascii.eqlIgnoreCase(kv.key, key)) {
                        kv.value.deinit(self.allocator);
                        kv.value = try value.clone(self.allocator);
                        return;
                    }
                },
                else => {},
            }
        }

        var insert_idx: usize = self.nodes.items.len;
        for (self.nodes.items, 0..) |node, i| {
            if (node == .table_header) {
                insert_idx = i;
                break;
            }
        }

        const new_kv = CstNode{
            .key_value = .{
                .indent = try self.allocator.dupe(u8, ""),
                .key = try self.allocator.dupe(u8, key),
                .value = try value.clone(self.allocator),
                .trailing = try self.allocator.dupe(u8, ""),
            },
        };
        try self.nodes.insert(self.allocator, insert_idx, new_kv);
    }

    pub fn emit(self: *const CstDocument, writer: anytype) !void {
        for (self.nodes.items, 0..) |node, i| {
            switch (node) {
                .raw => |r| try writer.writeAll(r),
                .table_header => |th| try writer.writeAll(th.raw_line),
                .key_value => |kv| {
                    try writer.writeAll(kv.indent);
                    if (std.mem.indexOfScalar(u8, kv.key, '+') != null) {
                        try writer.print("\"{s}\"", .{kv.key});
                    } else {
                        try writer.writeAll(kv.key);
                    }
                    try writer.writeAll(" = ");
                    try emitValue(kv.value, writer);
                    if (kv.trailing.len > 0) {
                        try writer.writeAll(" ");
                        try writer.writeAll(kv.trailing);
                    }
                },
            }
            if (i + 1 < self.nodes.items.len) {
                try writer.writeByte('\n');
            }
        }
    }
};

fn parseKeyValue(allocator: std.mem.Allocator, line: []const u8) !?CstNode {
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const raw_key = line[0..eq_pos];
    var raw_val_and_trail = line[eq_pos + 1 ..];

    var key_trimmed = std.mem.trim(u8, raw_key, " \t\r");
    if (key_trimmed.len >= 2 and key_trimmed[0] == '"' and key_trimmed[key_trimmed.len - 1] == '"') {
        key_trimmed = key_trimmed[1 .. key_trimmed.len - 1];
    }
    if (key_trimmed.len == 0) return null;

    const indent_len = std.mem.indexOfNone(u8, raw_key, " \t") orelse 0;
    const indent = raw_key[0..indent_len];

    var trailing_comment: []const u8 = "";
    var in_quotes = false;
    for (raw_val_and_trail, 0..) |c, idx| {
        if (c == '"') in_quotes = !in_quotes;
        if (c == '#' and !in_quotes) {
            trailing_comment = std.mem.trimEnd(u8, raw_val_and_trail[idx..], "\r");
            raw_val_and_trail = raw_val_and_trail[0..idx];
            break;
        }
    }

    const val_trimmed = std.mem.trim(u8, raw_val_and_trail, " \t\r");
    const parsed_val = parseValue(allocator, val_trimmed) catch return null;

    return CstNode{
        .key_value = .{
            .indent = try allocator.dupe(u8, indent),
            .key = try allocator.dupe(u8, key_trimmed),
            .value = parsed_val,
            .trailing = try allocator.dupe(u8, trailing_comment),
        },
    };
}

fn parseValue(allocator: std.mem.Allocator, text: []const u8) !Value {
    if (std.ascii.eqlIgnoreCase(text, "true")) return .{ .boolean = true };
    if (std.ascii.eqlIgnoreCase(text, "false")) return .{ .boolean = false };

    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return .{ .string = try allocator.dupe(u8, text[1 .. text.len - 1]) };
    }

    if (std.fmt.parseInt(i64, text, 10)) |num| return .{ .integer = num } else |_| {}

    if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') {
        var list = std.ArrayListUnmanaged(Value).empty;
        errdefer {
            for (list.items) |*item| item.deinit(allocator);
            list.deinit(allocator);
        }
        var tokens = std.mem.splitScalar(u8, text[1 .. text.len - 1], ',');
        while (tokens.next()) |tok| {
            const item_trimmed = std.mem.trim(u8, tok, " \t\r");
            if (item_trimmed.len > 0) {
                try list.append(allocator, try parseValue(allocator, item_trimmed));
            }
        }
        return .{ .array = list };
    }

    return .{ .string = try allocator.dupe(u8, text) };
}

fn emitValue(val: Value, writer: anytype) !void {
    switch (val) {
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .string => |s| try writer.print("\"{s}\"", .{s}),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                try emitValue(item, writer);
                if (i + 1 < arr.items.len) try writer.writeAll(", ");
            }
            try writer.writeByte(']');
        },
    }
}
