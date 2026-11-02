const std = @import("std");
const api = @import("anthropic");
const allocator = std.testing.allocator;

test "all generated endpoint declarations compile" {
    @setEvalBranchQuota(100_000);
    std.testing.refAllDecls(api);
}

test "results retain HTTP errors and failed decoding bodies" {
    const gpa = std.testing.allocator;
    var failure = try api.parseRawResponse(std.json.Value, .{
        .allocator = gpa,
        .status = .too_many_requests,
        .body = try gpa.dupe(u8, "rate limited"),
    });
    defer failure.deinit();
    try std.testing.expect(failure == .api_error);
    try std.testing.expectEqualStrings("rate limited", failure.api_error.body);
    try std.testing.expectEqual(std.http.Status.too_many_requests, failure.api_error.status);

    var malformed = try api.parseRawResponse(std.json.Value, .{
        .allocator = gpa,
        .status = .ok,
        .body = try gpa.dupe(u8, "not json"),
    });
    defer malformed.deinit();
    try std.testing.expect(malformed == .parse_error);
    try std.testing.expectEqualStrings("not json", malformed.parse_error.raw.body);

    var success = try api.parseRawResponse(std.json.Value, .{
        .allocator = gpa,
        .status = .ok,
        .body = try gpa.dupe(u8, "{\"id\":\"response\"}"),
    });
    defer success.deinit();
    try std.testing.expect(success == .ok);
    try std.testing.expectEqualStrings("response", success.ok.value().object.get("id").?.string);
}

test "Messages request roundtrips open model names and omits absent fields" {
    var request = try std.json.parseFromSlice(api.CreateMessageParams, allocator,
        \\{"model":"future-model","max_tokens":256,"messages":[{"role":"user","content":"Hello"}]}
    , .{});
    defer request.deinit();
    const encoded = try std.json.Stringify.valueAlloc(allocator, request.value, .{ .emit_null_optional_fields = false });
    defer allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("future-model", parsed.value.object.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 256), parsed.value.object.get("max_tokens").?.integer);
    try std.testing.expect(parsed.value.object.get("output_config") == null);
}

test "tool schemas preserve arbitrary JSON Schema keywords" {
    const source =
        \\{"type":"object","properties":{"minimum":{"type":"integer","minimum":1}},"required":["minimum"],"additionalProperties":false,"$defs":{"name":{"type":"string"}}}
    ;
    var schema = try std.json.parseFromSlice(api.InputSchema, allocator, source, .{});
    defer schema.deinit();
    const encoded = try std.json.Stringify.valueAlloc(allocator, schema.value, .{});
    defer allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const value = parsed.value.object;
    try std.testing.expect(!value.get("additionalProperties").?.bool);
    try std.testing.expect(value.contains("$defs"));
    try std.testing.expectEqual(@as(i64, 1), value.get("properties").?.object.get("minimum").?.object.get("minimum").?.integer);
}

test "JSON output schemas remain objects rather than encoded strings" {
    var format = try std.json.parseFromSlice(api.JsonOutputFormat, allocator,
        \\{"type":"json_schema","schema":{"type":"object","properties":{},"additionalProperties":false}}
    , .{});
    defer format.deinit();
    const encoded = try std.json.Stringify.valueAlloc(allocator, format.value, .{});
    defer allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("schema").? == .object);
    try std.testing.expect(!parsed.value.object.get("schema").?.object.get("additionalProperties").?.bool);
}

test "stream parser delivers native event JSON without a DONE marker" {
    const Events = struct {
        count: usize = 0,
        pub fn event(self: *@This(), value: *std.json.Value) !void {
            const kind = value.object.get("type").?.string;
            try std.testing.expectEqualStrings(if (self.count == 0) "content_block_delta" else "message_stop", kind);
            self.count += 1;
        }
    };
    var events = Events{};
    try api.parseSseBytesTyped(
        std.json.Value,
        allocator,
        "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\r\n\r\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        &events,
        null,
    );
    try std.testing.expectEqual(@as(usize, 2), events.count);
}

test "generated SDK includes models batches and files operations" {
    comptime {
        for (.{ "models_list", "messages_post", "message_batches_post", "list_files_v1_files_get" }) |name| {
            if (!@hasDecl(api, name)) @compileError("missing generated operation: " ++ name);
        }
    }
}

test "SSE accepts comments multiline JSON and a final event at EOF" {
    const Events = struct {
        count: usize = 0,
        pub fn event(self: *@This(), value: *std.json.Value) !void {
            try std.testing.expectEqualStrings("message_stop", value.object.get("type").?.string);
            self.count += 1;
        }
    };
    var events = Events{};
    try api.parseSseBytesTyped(std.json.Value, allocator, ": keepalive\r\nevent: message_stop\r\ndata: {\r\ndata: \"type\": \"message_stop\"}\r\n", &events, null);
    try std.testing.expectEqual(@as(usize, 1), events.count);
}

test "SSE propagates bad JSON callback failures and cancellation" {
    const Events = struct {
        pub fn event(_: *@This(), _: *std.json.Value) !void {
            return error.StopConsumer;
        }
    };
    var events = Events{};
    try std.testing.expectError(error.SyntaxError, api.parseSseBytesTyped(std.json.Value, allocator, "data: not json\n\n", &events, null));
    try std.testing.expectError(error.StopConsumer, api.parseSseBytesTyped(std.json.Value, allocator, "data: {}\n\n", &events, null));
    var token = api.CancellationToken.init();
    token.cancel();
    try std.testing.expectError(error.Cancelled, api.parseSseBytesTyped(std.json.Value, allocator, "data: {}\n\n", &events, &token));
}

// Inspect requests before the unsupported URI scheme prevents any network I/O.
const RequestCheck = struct {
    path: []const u8,
    stream: ?bool = null,
    version: []const u8 = "2026-10-21",
    count: usize = 0,
    failure: ?anyerror = null,

    fn observe(ctx: ?*anyopaque, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        self.check(method, url, headers, body) catch |err| {
            self.failure = err;
        };
    }

    fn check(self: *@This(), method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) !void {
        try std.testing.expectEqualStrings("offline://anthropic", url[0.."offline://anthropic".len]);
        try std.testing.expectEqualStrings(self.path, url["offline://anthropic".len..]);
        try std.testing.expectEqual(if (self.stream != null) std.http.Method.POST else std.http.Method.GET, method);
        var versions: usize = 0;
        var keys: usize = 0;
        var accepts: usize = 0;
        for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "anthropic-version")) {
                versions += 1;
                try std.testing.expectEqualStrings(self.version, header.value);
            }
            if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                keys += 1;
                try std.testing.expectEqualStrings("offline-key", header.value);
            }
            if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
                accepts += 1;
                try std.testing.expectEqualStrings(if (self.stream orelse false) "text/event-stream" else "application/json", header.value);
            }
            try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, "authorization"));
        }
        try std.testing.expectEqual(@as(usize, 1), versions);
        try std.testing.expectEqual(@as(usize, 1), keys);
        try std.testing.expectEqual(@as(usize, 1), accepts);
        if (self.stream) |stream| {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.?, .{});
            defer parsed.deinit();
            const request = parsed.value.object;
            try std.testing.expectEqualStrings("future-model", request.get("model").?.string);
            try std.testing.expectEqual(@as(i64, 256), request.get("max_tokens").?.integer);
            try std.testing.expectEqual(stream, request.get("stream").?.bool);
            try std.testing.expect(request.get("output_config") == null);
        } else try std.testing.expect(body == null);
    }
};

test "generated requests preserve paths headers queries and native streaming bodies offline" {
    var client = api.Client.init(allocator, std.testing.io, "");
    defer client.deinit();
    try std.testing.expectEqualStrings("https://api.anthropic.com", client.base_url);
    client.withBaseUrl("offline://anthropic");
    client.default_headers = &.{
        .{ .name = "x-api-key", .value = "offline-key" },
        .{ .name = "Anthropic-Version", .value = "2026-10-21" },
    };
    var check: RequestCheck = .{ .path = "/v1/messages", .stream = false, .version = "override-version" };
    client.http_observer = .{ .ctx = &check, .onRequest = RequestCheck.observe, .onResponse = null, .onError = null };
    const messages = [_]api.InputMessageUnion{
        .{ .user_input_message = .{ .role = "user", .content = .{ .string = "Hello" } } },
    };
    const request: api.CreateMessageParams = .{ .model = "future-model", .max_tokens = 256, .messages = &messages, .stream = false };
    try std.testing.expectError(error.UnsupportedUriScheme, api.resources.messages.create(&client, .{ .@"anthropic-version" = "override-version" }, request));
    if (check.failure) |err| return err;

    check.stream = true;
    const Events = struct {
        pub fn event(_: *@This(), _: *std.json.Value) !void {
            return error.UnexpectedEvent;
        }
    };
    var events = Events{};
    try std.testing.expectError(error.UnsupportedUriScheme, api.messages_postStreamingEvents(std.json.Value, &client, .{ .@"anthropic-version" = "override-version" }, request, &events, null));
    if (check.failure) |err| return err;

    check.stream = null;
    check.version = "2026-10-21";
    check.path = "/v1/models?before_id=before%20id&limit=1";
    try std.testing.expectError(error.UnsupportedUriScheme, api.resources.models.list(&client, .{ .before_id = "before id", .limit = 1 }));
    if (check.failure) |err| return err;
    check.path = "/v1/messages/batches?limit=1";
    try std.testing.expectError(error.UnsupportedUriScheme, api.resources.messages.batches.list(&client, .{ .limit = 1 }));
    if (check.failure) |err| return err;
    check.path = "/v1/files?limit=1";
    try std.testing.expectError(error.UnsupportedUriScheme, api.list_files_v1_files_get(&client, .{ .limit = 1 }));
    if (check.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 5), check.count);
}
