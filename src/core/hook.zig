const std = @import("std");

/// Runtime-selectable orchestration mode (CLI flag `-m react|todo`, or the
/// TUI's Ctrl+P toggle). Defined here rather than in `engine.zig` — this
/// module has no dependency on anything but `std`, so a hook can read
/// `Ctx.style` without `engine.zig` needing to hand it anything special;
/// `engine.zig` re-exports this type as `engine.Style` so existing
/// references to it elsewhere are unaffected. `enum(u8)`, not a bare
/// `enum`: `engine.zig`'s `style` field is `std.atomic.Value(Style)`, and
/// `std.atomic.Value(T)` is an `extern struct { raw: T }`, which rejects an
/// inferred-tag enum at compile time.
///
/// Nothing in the orchestrator branches on this — there is only one loop
/// (ReAct). Its sole effect today is `Ctx.style` below, which
/// `plugins/hooks/todo_tracker.zig`'s `preLlm` reads to decide whether to
/// nudge the model toward creating a todo list (design doc §3.5/§3.8): a
/// hook-visible mode flag, not an orchestrator selector.
pub const Style = enum(u8) { react, todo };

/// The Comptime Interface Contract for interceptor hook plugins — the
/// second plugin category alongside tools (design doc §3.7 / §9, and
/// docs/feat/hooks.MD). Unlike `tool.zig`, where the whole contract
/// (`Args`, `name`, `description`, `execute`) is mandatory, this interface
/// is **sparse**: only `name()` is required. Every other method is
/// optional and checked at its call site in `engine.zig` via
/// `if (@hasDecl(H, "methodName"))` — a hook implements only the points it
/// cares about. This is a deliberate, precedent-setting pattern for the
/// codebase; `tool.zig` remains all-mandatory.
///
///     pub const MyHook = struct {
///         pub fn name() []const u8 { return "my_hook"; }
///
///         // Everything below is optional. `Message` is
///         // `core/message.zig`'s type and `Outcome` is
///         // `core/engine.zig`'s — shown here for illustration only;
///         // nothing in this file compiles against them.
///
///         pub fn onTurnStart(ctx: Ctx, user_text: *?[]const u8) anyerror!void
///         pub fn preLlm(ctx: Ctx, messages: *std.ArrayList(Message)) anyerror!void
///         pub fn postLlm(ctx: Ctx, reply: *const Message, content_override: *?[]const u8) anyerror!void
///         pub fn preTool(ctx: Ctx, tool_name: []const u8, args_json: *[]const u8) anyerror!PreToolAction
///         pub fn postTool(ctx: Ctx, tool_name: []const u8, result: *[]const u8) anyerror!void
///         pub fn onEscalate(ctx: Ctx, tool_name: []const u8, diagnostic: []const u8, raw_args_json: []const u8, report: *[]const u8) anyerror!void
///         pub fn onTurnEnd(ctx: Ctx, outcome: *const Outcome) anyerror!void
///     };
///
/// Ownership: a hook allocates any replacement/veto string from
/// `ctx.scratch` and never frees anything itself; the engine re-normalizes
/// ownership at every boundary (docs/feat/hooks.MD, "Ownership
/// invariant"). The `messages` list handed to `preLlm` is allocated from
/// `ctx.scratch`, so hooks append to it with `ctx.scratch` too.
/// `onTurnEnd` is observe-only by design — `Outcome`'s payloads have two
/// different owners (memory arena vs. caller-freed gpa), so an override
/// there would dangle or double-free.
pub const Ctx = struct {
    /// The engine's general-purpose allocator. Hooks normally have no
    /// business allocating from it — replacement strings come from
    /// `scratch` — but it is exposed for hooks that must hand memory to
    /// something outliving the turn.
    gpa: std.mem.Allocator,
    /// Arena scoped to the surrounding engine phase (the tool loop, the
    /// planning exchange, or the turn). Everything a hook allocates to
    /// mutate engine state comes from here; the engine frees it wholesale.
    scratch: std.mem.Allocator,
    /// The live streaming output (TUI channel or stdout), when present.
    /// Hook output written here appears alongside the engine's own
    /// progress markers.
    writer: ?*std.Io.Writer,
    /// The turn's current orchestration mode (see `Style` above), so a
    /// hook can vary its behavior without the engine needing a dedicated
    /// hook point per mode. Defaults to `.react` so the 4 existing `Ctx{...}`
    /// literal call sites (as of this field's introduction) keep compiling
    /// unchanged.
    style: Style = .react,
};

/// What `preTool` tells the engine to do with a pending tool call.
pub const PreToolAction = union(enum) {
    /// Dispatch the call, with whatever `args_json` now points at.
    proceed,
    /// Skip dispatch entirely; this scratch-owned message becomes the
    /// tool-role result the LLM sees. Not a self-healing failure: it never
    /// increments the retry counter, but its status dot resolves red
    /// because the tool did not run.
    veto: []const u8,
};

/// Comptime validation of the sparse contract — `engine.zig` runs this
/// over every registered hook type, mirroring how tool shape errors
/// surface at compile time rather than at dispatch.
pub fn assertContract(comptime H: type) void {
    comptime {
        std.debug.assert(@hasDecl(H, "name"));
        std.debug.assert(H.name().len > 0);
    }
}

test "assertContract accepts a minimal (name-only) hook" {
    const Minimal = struct {
        pub fn name() []const u8 {
            return "minimal";
        }
    };
    comptime assertContract(Minimal);
    try std.testing.expectEqualStrings("minimal", Minimal.name());
}
