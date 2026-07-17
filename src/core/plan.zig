const std = @import("std");

/// One step of a static plan produced by the Plan-and-Execute orchestrator
/// (design doc §3, "Plan-and-Execute"). Plain runtime struct — unlike
/// `tool.zig`'s `Args`, this is parsed from LLM output at runtime, not
/// reflected at comptime into an outbound JSON schema.
pub const PlanStep = struct {
    description: []const u8,
};

pub const Plan = struct {
    steps: []const PlanStep,
};

/// Instructs the LLM to respond with only a plan, no tool calls. Sent as an
/// ephemeral system message during planning — never persisted to memory.
pub const schema_prompt =
    \\Break the user's most recent request into the smallest possible number of
    \\concrete, sequential steps needed to fully satisfy it. Respond with ONLY a
    \\single JSON object of the exact shape {"steps":[{"description":"..."}]} and
    \\nothing else — no markdown code fences, no commentary before or after the
    \\JSON. Do not call any tools in this response.
;

/// Strips a leading/trailing ``` (optionally ```json) code fence some
/// providers wrap "JSON-only" responses in despite instructions not to.
/// Returns a re-scoped slice into `s` — no allocation.
pub fn stripCodeFence(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.startsWith(u8, t, "```")) {
        if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = t[nl + 1 ..];
        if (std.mem.endsWith(u8, t, "```")) t = t[0 .. t.len - 3];
        t = std.mem.trim(u8, t, " \t\r\n");
    }
    return t;
}

const testing = std.testing;

test "stripCodeFence: passthrough on plain JSON" {
    try testing.expectEqualStrings("{\"steps\":[]}", stripCodeFence("{\"steps\":[]}"));
}

test "stripCodeFence: strips ```json fence" {
    try testing.expectEqualStrings(
        "{\"steps\":[]}",
        stripCodeFence("```json\n{\"steps\":[]}\n```"),
    );
}

test "stripCodeFence: strips bare ``` fence" {
    try testing.expectEqualStrings(
        "{\"steps\":[]}",
        stripCodeFence("```\n{\"steps\":[]}\n```"),
    );
}
