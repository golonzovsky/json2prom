const std = @import("std");
const c = @cImport({
    @cInclude("jq.h");
});

pub const JqError = error{
    CompileError,
    ExecuteError,
    InvalidJson,
};

pub const JqProcessor = struct {
    state: ?*c.jq_state,

    pub fn init() !JqProcessor {
        const state = c.jq_init() orelse return error.OutOfMemory;
        return JqProcessor{ .state = state };
    }

    pub fn deinit(self: *JqProcessor) void {
        c.jq_teardown(&self.state);
        self.state = null;
    }

    pub fn compile(self: *JqProcessor, program: []const u8) !void {
        const c_program = try std.fmt.allocPrintZ(std.heap.c_allocator, "{s}", .{program});
        defer std.heap.c_allocator.free(c_program);

        if (c.jq_compile(self.state.?, c_program) == 0) {
            return JqError.CompileError;
        }
    }

    pub fn execute(self: *JqProcessor, allocator: std.mem.Allocator, json_input: []const u8) ![]const u8 {
        const c_input = try std.fmt.allocPrintZ(std.heap.c_allocator, "{s}", .{json_input});
        defer std.heap.c_allocator.free(c_input);

        const parsed = c.jv_parse(c_input);
        if (c.jv_get_kind(parsed) == c.JV_KIND_INVALID) {
            c.jv_free(parsed);
            return JqError.InvalidJson;
        }
        defer c.jv_free(parsed);

        c.jq_start(self.state.?, parsed, 0);

        var results = std.ArrayList(u8).init(allocator);
        defer results.deinit();

        while (true) {
            const result = c.jq_next(self.state.?);
            if (c.jv_get_kind(result) == c.JV_KIND_INVALID) {
                c.jv_free(result);
                break;
            }

            const dumped = c.jv_dump_string(result, 0);
            const str = c.jv_string_value(dumped);
            try results.appendSlice(std.mem.span(str));

            c.jv_free(result);
            c.jv_free(dumped);
        }

        return results.toOwnedSlice();
    }
};

test "JqProcessor - simple value extraction" {
    var processor = try JqProcessor.init();
    defer processor.deinit();

    try processor.compile(".name");
    
    const json = 
        \\{"name": "test", "value": 42}
    ;
    
    const result = try processor.execute(std.testing.allocator, json);
    defer std.testing.allocator.free(result);
    
    try std.testing.expectEqualStrings("\"test\"", result);
}

test "JqProcessor - number extraction" {
    var processor = try JqProcessor.init();
    defer processor.deinit();

    try processor.compile(".value");
    
    const json = 
        \\{"name": "test", "value": 42}
    ;
    
    const result = try processor.execute(std.testing.allocator, json);
    defer std.testing.allocator.free(result);
    
    try std.testing.expectEqualStrings("42", result);
}

test "JqProcessor - nested value extraction" {
    var processor = try JqProcessor.init();
    defer processor.deinit();

    try processor.compile(".data.nested.value");
    
    const json = 
        \\{"data": {"nested": {"value": "deep"}}}
    ;
    
    const result = try processor.execute(std.testing.allocator, json);
    defer std.testing.allocator.free(result);
    
    try std.testing.expectEqualStrings("\"deep\"", result);
}

test "JqProcessor - array access" {
    var processor = try JqProcessor.init();
    defer processor.deinit();

    try processor.compile(".[1]");
    
    const json = 
        \\[10, 20, 30]
    ;
    
    const result = try processor.execute(std.testing.allocator, json);
    defer std.testing.allocator.free(result);
    
    try std.testing.expectEqualStrings("20", result);
}

test "JqProcessor - invalid JSON" {
    var processor = try JqProcessor.init();
    defer processor.deinit();

    try processor.compile(".value");
    
    const invalid_json = 
        \\{invalid json}
    ;
    
    const result = processor.execute(std.testing.allocator, invalid_json);
    try std.testing.expectError(JqError.InvalidJson, result);
}

test "JqProcessor - compile error" {
    var processor = try JqProcessor.init();
    defer processor.deinit();

    const result = processor.compile(".[");
    try std.testing.expectError(JqError.CompileError, result);
}

test "JqProcessor - empty result" {
    var processor = try JqProcessor.init();
    defer processor.deinit();

    try processor.compile(".nonexistent");
    
    const json = 
        \\{"name": "test"}
    ;
    
    const result = try processor.execute(std.testing.allocator, json);
    defer std.testing.allocator.free(result);
    
    try std.testing.expectEqualStrings("null", result);
}
