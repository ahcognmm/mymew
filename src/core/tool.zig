const std = @import("std");

/// The Comptime Interface Contract every tool plugin must satisfy:
///
///     pub const MyTool = struct {
///         pub const Args = struct {
///             foo: []const u8,
///             bar: ?i64 = null,
///         };
///         pub fn name() []const u8 { return "my_tool"; }
///         pub fn description() []const u8 { return "Does a thing."; }
///         pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 { ... }
///         // Optional — see `describeArgs`:
///         pub fn describe(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 { ... }
///     };
///
/// No vtable, no registration call: any struct exposing this shape is a
/// valid tool. The engine reflects over `Args` to auto-generate the JSON
/// schema handed to the LLM provider (see `parametersSchema`).
/// A descriptor of a tool, suitable for sending to an LLM provider as part
/// of a "tools" list in a chat completion request.
pub const Descriptor = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: []const u8,
};

pub fn descriptorOf(comptime Tool: type) Descriptor {
    return .{
        .name = Tool.name(),
        .description = Tool.description(),
        .parameters_schema = comptime parametersSchema(Tool.Args),
    };
}

fn jsonTypeFor(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "\"boolean\"",
        .int => "\"integer\"",
        .float => "\"number\"",
        .optional => |o| jsonTypeFor(o.child),
        .pointer => |p| if (p.size == .slice and p.child == u8)
            "\"string\""
        else
            @compileError("tool Args: unsupported pointer type " ++ @typeName(T)),
        .@"enum" => "\"string\"",
        else => @compileError("tool Args: unsupported field type " ++ @typeName(T)),
    };
}

/// Reflects over a tool's `Args` struct at comptime and produces the JSON
/// Schema `parameters` object required by OpenAI/Anthropic/GLM-style
/// function calling. Fields without a default value and not `?T` are
/// marked required.
pub fn parametersSchema(comptime Args: type) []const u8 {
    const info = @typeInfo(Args).@"struct";
    comptime var properties: []const u8 = "";
    comptime var required: []const u8 = "";
    comptime var first = true;
    inline for (info.fields) |field| {
        if (!first) properties = properties ++ ",";
        properties = properties ++ "\"" ++ field.name ++ "\":{\"type\":" ++ jsonTypeFor(field.type) ++ "}";
        const is_optional = @typeInfo(field.type) == .optional;
        if (field.defaultValue() == null and !is_optional) {
            if (required.len != 0) required = required ++ ",";
            required = required ++ "\"" ++ field.name ++ "\"";
        }
        first = false;
    }
    return "{\"type\":\"object\",\"properties\":{" ++ properties ++ "},\"required\":[" ++ required ++ "]}";
}

/// Outcome of invoking a tool with raw (LLM-supplied) JSON arguments.
pub const InvokeResult = union(enum) {
    /// Tool ran; this is its string result, to be sent back as a `tool` message.
    ok: []const u8,
    /// `args_json` failed to parse against the tool's `Args` struct. Carries
    /// enough detail for the orchestrator's self-healing feedback loop.
    invalid_args: struct {
        tool_name: []const u8,
        raw_args_json: []const u8,
        diagnostic: []const u8,
    },
};

/// Parses `args_json` into `Tool.Args` and calls `Tool.execute`. Never
/// returns a Zig error: parse failures and execute failures both become
/// `InvokeResult` values the orchestrator can act on.
pub fn invoke(comptime Tool: type, alloc: std.mem.Allocator, args_json: []const u8) InvokeResult {
    var parsed = std.json.parseFromSlice(Tool.Args, alloc, args_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        return .{ .invalid_args = .{
            .tool_name = Tool.name(),
            .raw_args_json = args_json,
            .diagnostic = @errorName(err),
        } };
    };
    defer parsed.deinit();

    const result = Tool.execute(alloc, parsed.value) catch |err| {
        return .{ .ok = std.fmt.allocPrint(
            alloc,
            "tool \"{s}\" failed: {s}",
            .{ Tool.name(), @errorName(err) },
        ) catch "tool execution failed" };
    };
    return .{ .ok = result };
}

/// UTF-8-boundary-safe truncation to at most `max` bytes, backing up over
/// any partial multi-byte character at the cut point.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    return s[0..end];
}

/// Produces a short, human-readable description of what a tool call is
/// about to do, from its raw (LLM-supplied) JSON arguments — purely
/// cosmetic (single-line TUI/log marker), never fed back to the LLM or
/// persisted to memory (the full raw arguments already are, via the normal
/// `.tool` message `invoke` produces). Tools may implement `describe` to
/// customize this; tools that don't, or whose args fail to parse, or whose
/// `describe` itself errors, get a generic fallback — the raw args JSON,
/// truncated. Always returns an allocator-owned string the caller must
/// free: never borrows from `args_json`, and never returns a slice into
/// `parsed`'s own arena, which is freed before this returns.
pub fn describeArgs(comptime Tool: type, alloc: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    if (!@hasDecl(Tool, "describe")) return alloc.dupe(u8, truncateUtf8(args_json, 80));
    var parsed = std.json.parseFromSlice(Tool.Args, alloc, args_json, .{
        .ignore_unknown_fields = true,
    }) catch return alloc.dupe(u8, truncateUtf8(args_json, 80));
    defer parsed.deinit();
    return Tool.describe(alloc, parsed.value) catch alloc.dupe(u8, truncateUtf8(args_json, 80));
}
