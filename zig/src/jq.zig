const std = @import("std");

const c = @cImport({
    @cInclude("jq.h");
});

pub const Value = c.jv;

pub const Error = error{
    CompileError,
    InvalidJson,
    OutOfMemory,
};

pub const Query = struct {
    state: *c.jq_state,

    pub fn compile(allocator: std.mem.Allocator, program: []const u8) Error!Query {
        const state = c.jq_init() orelse return error.OutOfMemory;
        var owned: ?*c.jq_state = state;
        errdefer c.jq_teardown(&owned);

        const programz = try allocator.dupeZ(u8, program);
        defer allocator.free(programz);

        if (c.jq_compile(state, programz) == 0) return error.CompileError;
        return .{ .state = state };
    }

    pub fn deinit(self: *Query) void {
        var state: ?*c.jq_state = self.state;
        c.jq_teardown(&state);
        self.* = undefined;
    }

    /// Returns every value the program emits for `input`. The caller keeps
    /// ownership of `input` and owns each returned jv plus the slice.
    pub fn exec(self: *Query, allocator: std.mem.Allocator, input: Value) ![]Value {
        var results: std.ArrayList(Value) = .empty;
        errdefer {
            for (results.items) |v| c.jv_free(v);
            results.deinit(allocator);
        }

        c.jq_start(self.state, c.jv_copy(input), 0);
        while (true) {
            const v = c.jq_next(self.state);
            if (c.jv_is_valid(v) == 0) {
                c.jv_free(v);
                break;
            }
            try results.append(allocator, v);
        }
        return results.toOwnedSlice(allocator);
    }
};

pub fn free(v: Value) void {
    c.jv_free(v);
}

pub fn freeResults(allocator: std.mem.Allocator, results: []Value) void {
    for (results) |v| c.jv_free(v);
    allocator.free(results);
}

pub fn parseJson(input: []const u8) Error!Value {
    const v = c.jv_parse_sized(input.ptr, @intCast(input.len));
    if (c.jv_is_valid(v) == 0) {
        c.jv_free(v);
        return error.InvalidJson;
    }
    return v;
}

/// Numbers as-is, booleans as 1/0, anything else null (caller skips the item).
pub fn toNumber(v: Value) ?f64 {
    return switch (c.jv_get_kind(v)) {
        c.JV_KIND_NUMBER => c.jv_number_value(v),
        c.JV_KIND_TRUE => 1,
        c.JV_KIND_FALSE => 0,
        else => null,
    };
}

/// Strings raw (no quotes), other kinds as their JSON text. Caller owns result.
pub fn toLabelString(allocator: std.mem.Allocator, v: Value) ![]u8 {
    if (c.jv_get_kind(v) == c.JV_KIND_STRING) {
        const len: usize = @intCast(c.jv_string_length_bytes(c.jv_copy(v)));
        return allocator.dupe(u8, c.jv_string_value(v)[0..len]);
    }
    const dumped = c.jv_dump_string(c.jv_copy(v), 0);
    defer c.jv_free(dumped);
    return allocator.dupe(u8, std.mem.span(c.jv_string_value(dumped)));
}

pub fn kindName(v: Value) []const u8 {
    return std.mem.span(c.jv_kind_name(c.jv_get_kind(v)));
}

test "compile error fails fast" {
    try std.testing.expectError(error.CompileError, Query.compile(std.testing.allocator, ".["));
}

test "single result" {
    var q = try Query.compile(std.testing.allocator, ".value");
    defer q.deinit();

    const root = try parseJson(
        \\{"name": "test", "value": 42}
    );
    defer c.jv_free(root);

    const results = try q.exec(std.testing.allocator, root);
    defer freeResults(std.testing.allocator, results);

    try std.testing.expectEqual(1, results.len);
    try std.testing.expectEqual(42, toNumber(results[0]).?);
}

test "multiple results from stream" {
    var q = try Query.compile(std.testing.allocator, ".payload[]");
    defer q.deinit();

    const root = try parseJson(
        \\{"payload": [{"val": 1}, {"val": 2}, {"val": 3}]}
    );
    defer c.jv_free(root);

    const results = try q.exec(std.testing.allocator, root);
    defer freeResults(std.testing.allocator, results);

    try std.testing.expectEqual(3, results.len);
    for (results, 1..) |item, i| {
        var vq = try Query.compile(std.testing.allocator, ".val");
        defer vq.deinit();
        const vals = try vq.exec(std.testing.allocator, item);
        defer freeResults(std.testing.allocator, vals);
        try std.testing.expectEqual(@as(f64, @floatFromInt(i)), toNumber(vals[0]).?);
    }
}

test "no result" {
    var q = try Query.compile(std.testing.allocator, ".[] | select(.x > 100)");
    defer q.deinit();

    const root = try parseJson("[{\"x\": 1}]");
    defer c.jv_free(root);

    const results = try q.exec(std.testing.allocator, root);
    defer freeResults(std.testing.allocator, results);
    try std.testing.expectEqual(0, results.len);
}

test "value conversion rules" {
    const cases = [_]struct { json: []const u8, expected: ?f64 }{
        .{ .json = "42.5", .expected = 42.5 },
        .{ .json = "true", .expected = 1 },
        .{ .json = "false", .expected = 0 },
        .{ .json = "null", .expected = null },
        .{ .json = "\"str\"", .expected = null },
        .{ .json = "[1]", .expected = null },
        .{ .json = "{\"a\": 1}", .expected = null },
    };
    for (cases) |case| {
        const v = try parseJson(case.json);
        defer c.jv_free(v);
        try std.testing.expectEqual(case.expected, toNumber(v));
    }
}

test "label string conversion" {
    const cases = [_]struct { json: []const u8, expected: []const u8 }{
        .{ .json = "\"Limmat\"", .expected = "Limmat" },
        .{ .json = "42", .expected = "42" },
        .{ .json = "42.5", .expected = "42.5" },
        .{ .json = "true", .expected = "true" },
        .{ .json = "null", .expected = "null" },
        .{ .json = "[1,2]", .expected = "[1,2]" },
    };
    for (cases) |case| {
        const v = try parseJson(case.json);
        defer c.jv_free(v);
        const s = try toLabelString(std.testing.allocator, v);
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings(case.expected, s);
    }
}

test "invalid JSON" {
    try std.testing.expectError(error.InvalidJson, parseJson("{invalid json}"));
}

test "query is reusable across inputs" {
    var q = try Query.compile(std.testing.allocator, ".n");
    defer q.deinit();

    for ([_][]const u8{ "{\"n\": 1}", "{\"n\": 2}" }, 1..) |json, i| {
        const root = try parseJson(json);
        defer c.jv_free(root);
        const results = try q.exec(std.testing.allocator, root);
        defer freeResults(std.testing.allocator, results);
        try std.testing.expectEqual(@as(f64, @floatFromInt(i)), toNumber(results[0]).?);
    }
}
