const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const tool = @import("tool.zig");
const Message = message.Message;
const ToolCall = message.ToolCall;

/// The LLM Provider Comptime Contract: any struct exposing
///
///     pub fn chat(
///         self: *Self,
///         gpa: std.mem.Allocator,
///         io: std.Io,
///         messages: []const Message,
///         tools: []const tool.Descriptor,
///     ) anyerror!Message
///
/// is a valid provider. `chat` returns the assistant's reply as a `Message`
/// (with `.content` and/or `.tool_calls` populated). No vtable: the engine
/// is generic over the provider type and calls this method directly.
/// Writes a pre-serialized JSON blob verbatim as a field's value, so
/// comptime-generated tool schemas can be spliced into a request without
/// being treated as opaque strings.
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
};

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
        try out.append(scratch, .{
            .role = roleName(m.role),
            .content = if (m.content.len != 0 or m.tool_calls.len == 0) m.content else null,
            .tool_calls = wire_calls,
            .tool_call_id = if (m.role == .tool) m.tool_call_id else null,
            .name = if (m.role == .tool) m.name else null,
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

fn toAgentMessage(gpa: std.mem.Allocator, resp: RespMessage) !Message {
    var calls: []const ToolCall = &.{};
    if (resp.tool_calls) |tcs| {
        var list: std.ArrayList(ToolCall) = .empty;
        for (tcs) |tc| {
            try list.append(gpa, .{
                .id = try gpa.dupe(u8, tc.id),
                .name = try gpa.dupe(u8, tc.function.name),
                .arguments_json = try gpa.dupe(u8, tc.function.arguments),
            });
        }
        calls = list.items;
    }
    return .{
        .role = .assistant,
        .content = if (resp.content) |c| try gpa.dupe(u8, c) else "",
        .tool_calls = calls,
    };
}

/// Errors returned by a chat-completion HTTP call to an OpenAI-compatible
/// endpoint (used by `Glm` and any similar provider).
pub const ChatError = error{
    MissingApiKey,
    ApiError,
    UnexpectedStatus,
} || std.mem.Allocator.Error || std.Uri.ParseError;

/// GLM (Zhipu / z.ai) provider. Talks to an OpenAI-compatible
/// `/chat/completions` endpoint: https://docs.z.ai.
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
    ) anyerror!Message {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const scratch = arena_state.allocator();

        const wire_messages = try buildWireMessages(scratch, messages);
        const wire_tools = if (tools.len != 0) try buildWireTools(scratch, tools) else null;
        const req: WireRequest = .{ .model = self.model, .messages = wire_messages, .tools = wire_tools };
        const body = try std.json.Stringify.valueAlloc(scratch, req, .{});

        var client: std.http.Client = .{ .allocator = scratch, .io = io };
        defer client.deinit();

        const auth_header = try std.fmt.allocPrint(scratch, "Bearer {s}", .{self.api_key});

        var response_buf: std.Io.Writer.Allocating = .init(scratch);
        defer response_buf.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = self.base_url },
            .method = .POST,
            .payload = body,
            .response_writer = &response_buf.writer,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .content_type = .{ .override = "application/json" },
            },
        });

        const response_bytes = response_buf.written();
        if (result.status != .ok) {
            std.log.err("GLM API returned {d}: {s}", .{ @intFromEnum(result.status), response_bytes });
            return error.UnexpectedStatus;
        }

        var parsed = try std.json.parseFromSlice(RespBody, scratch, response_bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        if (parsed.value.@"error") |e| {
            std.log.err("GLM API error: {s}", .{e.message});
            return error.ApiError;
        }
        if (parsed.value.choices.len == 0) return error.ApiError;

        return toAgentMessage(gpa, parsed.value.choices[0].message);
    }
};

/// Offline provider for testing the orchestrator without network access: it
/// plays back a fixed script of assistant messages, one per call to `chat`.
pub const Mock = struct {
    script: []const Message,
    next: usize = 0,

    pub fn chat(
        self: *Mock,
        gpa: std.mem.Allocator,
        io: Io,
        messages: []const Message,
        tools: []const tool.Descriptor,
    ) anyerror!Message {
        _ = io;
        _ = messages;
        _ = tools;
        if (self.next >= self.script.len) return error.MockScriptExhausted;
        const m = self.script[self.next];
        self.next += 1;
        return dupeMessage(gpa, m);
    }
};

fn dupeMessage(gpa: std.mem.Allocator, m: Message) !Message {
    var calls: std.ArrayList(ToolCall) = .empty;
    for (m.tool_calls) |tc| try calls.append(gpa, tc);
    return .{
        .role = m.role,
        .content = m.content,
        .tool_calls = calls.items,
        .tool_call_id = m.tool_call_id,
        .name = m.name,
    };
}
