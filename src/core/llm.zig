const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const tool = @import("tool.zig");
const Message = message.Message;
const ToolCall = message.ToolCall;

/// Provider contract: any struct with
///
///     pub fn chat(self: *Self, gpa, io, messages, tools, token_writer: ?*std.Io.Writer) anyerror!Message
///
/// No vtable — Engine is generic over Provider and calls this directly.
/// `token_writer`, if non-null, receives content tokens as they stream in.

const RawJson = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: RawJson, jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeAll(self.bytes);
        jw.endWriteRaw();
    }
};

const WireToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: RawJson,
};

const WireTool = struct {
    type: []const u8 = "function",
    function: WireToolFunction,
};

const WireToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

const WireToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: WireToolCallFunction,
};

const WireMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const WireToolCall = null,
    tool_call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

const WireRequest = struct {
    model: []const u8,
    messages: []const WireMessage,
    tools: ?[]const WireTool = null,
    stream: bool = true,
};

// SSE delta types — OpenAI-compatible streaming format
const SseFunctionDelta = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};
const SseToolCallDelta = struct {
    index: u32 = 0,
    id: ?[]const u8 = null,
    function: ?SseFunctionDelta = null,
};
const SseDelta = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]const SseToolCallDelta = null,
};
const SseChoice = struct {
    delta: SseDelta = .{},
    finish_reason: ?[]const u8 = null,
};
const SseChunk = struct {
    choices: []const SseChoice = &.{},
};

// Non-streaming response types (used for error bodies)
const RespFunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};
const RespToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: RespFunctionCall,
};
const RespMessage = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    tool_calls: ?[]const RespToolCall = null,
};
const RespChoice = struct {
    message: RespMessage,
    finish_reason: ?[]const u8 = null,
};
const RespError = struct {
    message: []const u8 = "",
    code: ?[]const u8 = null,
};
const RespBody = struct {
    choices: []const RespChoice = &.{},
    @"error": ?RespError = null,
};

fn roleName(role: message.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn buildWireMessages(scratch: std.mem.Allocator, messages: []const Message) ![]const WireMessage {
    var out: std.ArrayList(WireMessage) = .empty;
    for (messages) |m| {
        var wire_calls: ?[]const WireToolCall = null;
        if (m.tool_calls.len != 0) {
            var calls: std.ArrayList(WireToolCall) = .empty;
            for (m.tool_calls) |tc| {
                try calls.append(scratch, .{
                    .id = tc.id,
                    .function = .{ .name = tc.name, .arguments = tc.arguments_json },
                });
            }
            wire_calls = calls.items;
        }
        // Never send empty-string content; GLM rejects it.
        // Tool-call assistant messages have no content — omit the field entirely.
        const wire_content: ?[]const u8 = if (m.content.len == 0 or m.tool_calls.len != 0)
            null
        else
            m.content;
        try out.append(scratch, .{
            .role = roleName(m.role),
            .content = wire_content,
            .tool_calls = wire_calls,
            .tool_call_id = if (m.role == .tool and m.tool_call_id.len > 0) m.tool_call_id else null,
            .name = if (m.role == .tool and m.name.len > 0) m.name else null,
        });
    }
    return out.items;
}

fn buildWireTools(scratch: std.mem.Allocator, tools: []const tool.Descriptor) ![]const WireTool {
    var out: std.ArrayList(WireTool) = .empty;
    for (tools) |d| {
        try out.append(scratch, .{ .function = .{
            .name = d.name,
            .description = d.description,
            .parameters = .{ .bytes = d.parameters_schema },
        } });
    }
    return out.items;
}

pub const ChatError = error{
    MissingApiKey,
    ApiError,
    UnexpectedStatus,
} || std.mem.Allocator.Error || std.Uri.ParseError;

/// Accumulates one tool call's streaming fragments.
const ToolCallAccum = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),
};

pub const Glm = struct {
    api_key: []const u8,
    model: []const u8 = "glm-5.2",
    base_url: []const u8 = "https://api.z.ai/api/coding/paas/v4/chat/completions",

    pub fn fromEnv(env: *const std.process.Environ.Map) !Glm {
        const api_key = env.get("GLM_API_KEY") orelse env.get("ZAI_API_KEY") orelse
            return error.MissingApiKey;
        var self: Glm = .{ .api_key = api_key };
        if (env.get("GLM_MODEL")) |m| self.model = m;
        if (env.get("GLM_BASE_URL")) |u| self.base_url = u;
        return self;
    }

    pub fn chat(
        self: *Glm,
        gpa: std.mem.Allocator,
        io: Io,
        messages: []const Message,
        tools: []const tool.Descriptor,
        token_writer: ?*std.Io.Writer,
    ) anyerror!Message {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const scratch = arena_state.allocator();

        const wire_messages = try buildWireMessages(scratch, messages);
        const wire_tools = if (tools.len != 0) try buildWireTools(scratch, tools) else null;
        const body = try std.json.Stringify.valueAlloc(scratch, WireRequest{
            .model = self.model,
            .messages = wire_messages,
            .tools = wire_tools,
        }, .{ .emit_null_optional_fields = false });

        const auth_header = try std.fmt.allocPrint(scratch, "Bearer {s}", .{self.api_key});
        const uri = try std.Uri.parse(self.base_url);

        var client: std.http.Client = .{ .allocator = scratch, .io = io };
        defer client.deinit();

        var http_req = try client.request(.POST, uri, .{
            .headers = .{
                .authorization = .{ .override = auth_header },
                .content_type = .{ .override = "application/json" },
                // Force plain-text response — gzip-encoded SSE would arrive as
                // binary and break our line-by-line parser silently.
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer http_req.deinit();

        try http_req.sendBodyComplete(body);

        var redirect_buf: [4096]u8 = undefined;
        var response = try http_req.receiveHead(&redirect_buf);
        const status = response.head.status;

        var transfer_buf: [16 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);

        if (status != .ok) {
            // Drain error body for logging.
            var err_buf: std.ArrayList(u8) = .empty;
            drain: while (true) {
                const chunk = body_reader.takeDelimiter('\n') catch break :drain;
                const line = chunk orelse break :drain;
                try err_buf.appendSlice(scratch, line);
            }
            std.log.err("GLM API returned {d}: {s}", .{ @intFromEnum(status), err_buf.items });
            return error.UnexpectedStatus;
        }

        // SSE accumulation
        var content_buf: std.ArrayList(u8) = .empty;
        var reasoning_buf: std.ArrayList(u8) = .empty;
        var tc_accum: std.ArrayList(ToolCallAccum) = .empty;
        var in_thinking = false;

        sse_loop: while (true) {
            const maybe_line = body_reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => continue :sse_loop, // oversized line, skip
                error.ReadFailed => return error.ReadFailed,
            };
            const raw_line = maybe_line orelse break :sse_loop;
            const line = std.mem.trimEnd(u8, raw_line, "\r");

            if (!std.mem.startsWith(u8, line, "data: ")) continue;
            const data = line["data: ".len..];
            if (std.mem.eql(u8, data, "[DONE]")) break;

            const chunk = std.json.parseFromSliceLeaky(SseChunk, scratch, data, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.debug("SSE parse error: {s} | raw: {s}", .{ @errorName(err), data[0..@min(data.len, 80)] });
                continue;
            };
            if (chunk.choices.len == 0) continue;

            const delta = chunk.choices[0].delta;
            std.log.debug("SSE delta: content={?s} reasoning={?s} tool_calls={}", .{
                delta.content,
                delta.reasoning_content,
                delta.tool_calls != null,
            });

            // Reasoning/thinking content (GLM chain-of-thought). The provider
            // only marks the span with a dim+italic SGR toggle; the TUI is
            // responsible for recognizing that marker and drawing whatever
            // gutter/decoration it wants around it (see wrapLogicalLine in
            // tui/app.zig) — presentation stays out of the provider layer.
            if (delta.reasoning_content) |rc| {
                if (rc.len > 0) {
                    if (!in_thinking) {
                        if (token_writer) |w| {
                            try w.writeAll("\x1b[2;3m"); // dim + italic for thinking
                            try w.flush(); // flush style change immediately
                        }
                        in_thinking = true;
                    }
                    try reasoning_buf.appendSlice(scratch, rc);
                    if (token_writer) |w| try w.writeAll(rc);
                }
            }

            // Regular content tokens
            if (delta.content) |c| {
                if (c.len > 0) {
                    if (in_thinking) {
                        if (token_writer) |w| {
                            try w.writeAll("\x1b[0m\n\n"); // reset style, blank line before the response
                            try w.flush(); // flush style change immediately
                        }
                        in_thinking = false;
                    }
                    try content_buf.appendSlice(scratch, c);
                    if (token_writer) |w| try w.writeAll(c);
                }
            }

            // Tool call fragments — accumulate by index
            if (delta.tool_calls) |tcs| {
                for (tcs) |tc| {
                    while (tc_accum.items.len <= tc.index) {
                        try tc_accum.append(scratch, .{
                            .id = .empty,
                            .name = .empty,
                            .arguments = .empty,
                        });
                    }
                    const a = &tc_accum.items[tc.index];
                    if (tc.id) |id| try a.id.appendSlice(scratch, id);
                    if (tc.function) |f| {
                        if (f.name) |n| try a.name.appendSlice(scratch, n);
                        if (f.arguments) |args| try a.arguments.appendSlice(scratch, args);
                    }
                }
            }

            // One flush per SSE chunk — batches all token writes above into
            // a single syscall instead of one per fragment.
            if (token_writer) |w| try w.flush();
        }

        if (in_thinking) {
            if (token_writer) |w| {
                try w.writeAll("\x1b[0m\n");
                try w.flush();
            }
        }

        // Build result with all strings owned by gpa (arena freed after this).
        var calls: std.ArrayList(ToolCall) = .empty;
        for (tc_accum.items) |a| {
            try calls.append(gpa, .{
                .id = try gpa.dupe(u8, a.id.items),
                .name = try gpa.dupe(u8, a.name.items),
                .arguments_json = try gpa.dupe(u8, a.arguments.items),
            });
        }

        return .{
            .role = .assistant,
            .content = try gpa.dupe(u8, content_buf.items),
            // toOwnedSlice (not `.items`) so the returned slice's allocation
            // is exactly `len` long — callers free it with a plain
            // `gpa.free()`, which would panic ("Invalid free") against an
            // ArrayList's possibly-larger-than-`len` backing capacity.
            .tool_calls = try calls.toOwnedSlice(gpa),
        };
    }
};

/// Offline provider for orchestrator tests — plays back a fixed script.
/// Ignores `token_writer` since there's nothing to stream.
pub const Mock = struct {
    script: []const Message,
    next: usize = 0,
    /// Optional: if set, records `messages.len` seen on each `chat()` call
    /// (in call order), for tests that need to verify what context a
    /// caller actually sent — e.g. that a curated per-step view stayed
    /// bounded instead of growing with every prior step's raw transcript.
    call_message_counts: ?*std.ArrayList(usize) = null,

    pub fn chat(
        self: *Mock,
        gpa: std.mem.Allocator,
        io: Io,
        messages: []const Message,
        tools: []const tool.Descriptor,
        token_writer: ?*std.Io.Writer,
    ) anyerror!Message {
        _ = io;
        _ = tools;
        _ = token_writer;
        if (self.call_message_counts) |counts| try counts.append(gpa, messages.len);
        if (self.next >= self.script.len) return error.MockScriptExhausted;
        const m = self.script[self.next];
        self.next += 1;
        return dupeMessage(gpa, m);
    }
};

/// Mirrors `Glm.chat`'s ownership contract: content and every tool call
/// field come back freshly gpa-allocated, never aliased to the script's own
/// (often literal) strings, so callers can free a reply the same way
/// regardless of which provider produced it.
fn dupeMessage(gpa: std.mem.Allocator, m: Message) !Message {
    var calls: std.ArrayList(ToolCall) = .empty;
    for (m.tool_calls) |tc| {
        try calls.append(gpa, .{
            .id = try gpa.dupe(u8, tc.id),
            .name = try gpa.dupe(u8, tc.name),
            .arguments_json = try gpa.dupe(u8, tc.arguments_json),
        });
    }
    return .{
        .role = m.role,
        .content = try gpa.dupe(u8, m.content),
        .tool_calls = try calls.toOwnedSlice(gpa),
        .tool_call_id = m.tool_call_id,
        .name = m.name,
    };
}
