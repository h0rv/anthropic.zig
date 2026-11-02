const std = @import("std");
const anthropic = @import("anthropic");

// This executable is compiled by `zig build test`, never run by it.
pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get("ANTHROPIC_API_KEY") orelse return error.MissingApiKey;
    // The generated key argument is a bearer token. API keys use x-api-key.
    var client = anthropic.Client.init(init.gpa, init.io, "");
    defer client.deinit();
    client.default_headers = &.{
        .{ .name = "x-api-key", .value = key },
        .{ .name = "anthropic-version", .value = "2026-10-21" },
    };

    const messages = [_]anthropic.InputMessageUnion{
        .{ .user_input_message = .{ .role = "user", .content = .{ .string = "Say hello." } } },
    };
    const request: anthropic.CreateMessageParams = .{
        .model = "claude-sonnet-4-6",
        .max_tokens = 256,
        .messages = &messages,
    };
    var response = try anthropic.resources.messages.create(&client, .{}, request);
    defer response.deinit();

    var result = try anthropic.resources.messages.createResult(&client, .{}, request);
    defer result.deinit();
    switch (result) {
        .ok => |*message| std.debug.print("{s}\n", .{message.value().id}),
        .api_error => |failure| std.debug.print("HTTP {d}: {s}\n", .{ @backingInt(failure.status), failure.body }),
        .parse_error => |failure| std.debug.print("Invalid JSON response: {s}\n", .{failure.raw.body}),
    }

    var models = try anthropic.resources.models.list(&client, .{ .limit = 1 });
    defer models.deinit();
    var batches = try anthropic.resources.messages.batches.list(&client, .{ .limit = 1 });
    defer batches.deinit();
    var files = try anthropic.list_files_v1_files_get(&client, .{ .limit = 1 });
    defer files.deinit();

    var events = Events{};
    var streaming_request = request;
    streaming_request.stream = true;
    try anthropic.messages_postStreamingEvents(std.json.Value, &client, .{}, streaming_request, &events, null);
}

const Events = struct {
    // Event values are borrowed and are only valid during this call.
    pub fn event(_: *@This(), value: *std.json.Value) !void {
        if (value.object.get("type")) |kind| std.debug.print("{s}\n", .{kind.string});
    }
};
