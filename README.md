# anthropic.zig

A generated Zig SDK for the full Anthropic API in the pinned official specification. Requires Zig 0.17.0.

## Install

```sh
zig fetch --save=anthropic git+https://github.com/h0rv/anthropic.zig.git
```

Pin a release or commit in your project. Add the module in `build.zig`.

```zig
const dep = b.dependency("anthropic", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("anthropic", dep.module("anthropic"));
```

## Use

```zig
const std = @import("std");
const anthropic = @import("anthropic");

pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get("ANTHROPIC_API_KEY") orelse return error.MissingApiKey;
    var client = anthropic.Client.init(init.gpa, init.io, "");
    defer client.deinit();
    client.default_headers = &.{
        .{ .name = "x-api-key", .value = key },
        .{ .name = "anthropic-version", .value = "2026-10-21" },
    };
    const messages = [_]anthropic.InputMessageUnion{
        .{ .user_input_message = .{ .role = "user", .content = .{ .string = "Say hello." } } },
    };
    var response = try anthropic.resources.messages.create(&client, .{}, .{
        .model = "claude-sonnet-4-6",
        .max_tokens = 256,
        .messages = &messages,
    });
    defer response.deinit();
    // Read response.value().content.
}
```

API keys go in `x-api-key`. The `Client.init` key argument is a bearer token. The default URL is `https://api.anthropic.com`. Generated paths include `/v1`. You can also pass `@"anthropic-version"` in each operation's named options.

The SDK includes Messages, models, message batches, files, and the other operations in the spec. See [`examples/smoke.zig`](examples/smoke.zig) for list calls and native streaming with JSON events. Callback values are borrowed and valid only during the call. Responses own their data and need `deinit()`. Use `createResult` to keep HTTP errors and bodies that fail to decode.

## Generate and test

```sh
zig build generate -Dregenerate=true
zig build test
zig build test -Doptimize=ReleaseSafe
```

[`spec.lock.json`](spec.lock.json) pins the official spec commit and checksum. Update them together. Generation uses the pinned `openapi2zig` dependency. Never edit `src/api.zig` by hand. Generation needs `curl`, `sh`, and `shasum`. Normal builds do not download the spec or build the generator. Tests are offline and compile the example without running it.

Multipart and form uploads are not supported. Responses are buffered without a size limit when not streaming.
