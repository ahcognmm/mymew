const std = @import("std");

pub const Role = enum { system, user, assistant, tool };

pub const ToolCall = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    /// Raw JSON object string, exactly as returned by the LLM provider.
    arguments_json: []const u8 = "{}",
};

/// Wire-compatible chat message. Mirrors the OpenAI/Anthropic/GLM message
/// shape closely enough that providers only need to translate at the edges.
pub const Message = struct {
    role: Role,
    content: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    /// Set on role == .tool messages: which tool_call this is a result for.
    tool_call_id: []const u8 = "",
    /// Set on role == .tool messages: the tool's name (some providers want it).
    name: []const u8 = "",

    pub fn user(text: []const u8) Message {
        return .{ .role = .user, .content = text };
    }

    pub fn system(text: []const u8) Message {
        return .{ .role = .system, .content = text };
    }
};
