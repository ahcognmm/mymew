# Design: Interceptor Hooks

Status: **implemented.** This document captured the design before implementation and was amended after review; it now describes the shipped behavior (`src/core/hook.zig`, hook wiring in `src/core/engine.zig`, sample hook in `src/plugins/hooks/`).

## Motivation

`mymew`'s plugin model currently has one category: `Tools` (`src/core/tool.zig`), comptime duck-typed and registered as a tuple. This doc proposes a second category, **hooks**, that run at the main orchestration steps and can observe, mutate, or veto what happens — not just log. Scope, as confirmed with the user: full **interceptor** power (mutate/veto, not observe-only), across seven hook points: `pre_llm`, `post_llm`, `pre_tool`, `post_tool`, `turn_start`, `turn_end`, `on_escalate`.

## Hook contract

Would live in a new `src/core/hook.zig`, mirroring `tool.zig`'s doc-comment-as-contract style, but as a **sparse** interface: only `name() []const u8` is mandatory. Every method below is optional, checked at its call site via `if (@hasDecl(H, "methodName"))` — unlike `tool.zig`, where the whole contract (`Args`, `name`, `description`, `execute`) is mandatory. This is a new, precedent-setting pattern for the codebase and should be called out explicitly wherever it's documented.

```zig
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    writer: ?*std.Io.Writer,
};

pub const PreToolAction = union(enum) {
    proceed,
    veto: []const u8,
};

pub fn onTurnStart(ctx: Ctx, user_text: *?[]const u8) anyerror!void
pub fn preLlm(ctx: Ctx, messages: *std.ArrayList(Message)) anyerror!void
pub fn postLlm(ctx: Ctx, reply: *const Message, content_override: *?[]const u8) anyerror!void
pub fn preTool(ctx: Ctx, tool_name: []const u8, args_json: *[]const u8) anyerror!PreToolAction
pub fn postTool(ctx: Ctx, tool_name: []const u8, result: *[]const u8) anyerror!void
pub fn onEscalate(ctx: Ctx, tool_name: []const u8, diagnostic: []const u8, raw_args_json: []const u8, report: *[]const u8) anyerror!void
pub fn onTurnEnd(ctx: Ctx, outcome: *const Outcome) anyerror!void
```

`onTurnEnd` is **observe-only** (`*const Outcome`), deliberately: `Outcome.final` points into `Memory`'s arena (callers never free it) and `Outcome.escalated` is gpa-owned (callers unconditionally free it), so a hook swapping either for a scratch-allocated string would produce a dangle or a bad free — and an override here would silently diverge from what was already persisted to memory. Content override is `postLlm`'s job, which is persistence-aware.

`hook.zig` itself would import only `std` — no dependency on `engine.zig` or `message.zig`, avoiding a circular import. `Message`/`Outcome` appear only in the illustrative doc-comment example, not in compiled signatures declared in that file.

## Where each hook fires (mapped to the current `src/core/engine.zig`)

- **`onTurnStart` / `onTurnEnd`**: in `step()` (`engine.zig:160`) — the single entry point both `stepReact` and `stepPlanExecute` funnel through, so lifecycle hooks fire exactly once per user-facing turn regardless of orchestration style. `stepPlanExecute`'s multiple internal `runToolLoop` calls all share one `turn_start` already, so they are not separate turns and don't need their own turn_start/turn_end firing. **`step()` gains its own turn-scoped arena** to serve as `Ctx.scratch` for these two hooks: `runToolLoop`'s `loop_arena` doesn't exist yet at `onTurnStart` time and is already deinitialized by `onTurnEnd` time, so turn-level hooks cannot borrow it.
- **`preLlm`**: inside `runToolLoop`'s `while (true)` loop (`engine.zig:396`), right before `self.provider.chat(self.gpa, self.io, view.items, &descriptors, writer)` (`engine.zig:397`). Hooks into the `view: std.ArrayList(Message)` that already exists there (seeded from `base_view`, grown each iteration) rather than building a separate copy — `runToolLoop` already does the "mutable outbound view distinct from `self.mem`" bookkeeping hooks need. Also wired into `buildPlan`'s one `self.provider.chat(...)` call (`engine.zig:331`), reusing its existing `arena` parameter as scratch.
- **`postLlm`**: right after each `runToolLoop` provider call returns (`engine.zig:397`), before the `reply.tool_calls.len == 0` check. **Not** wired into `buildPlan` (see limitations).
- **`preTool` / `postTool`**: inside the `for (reply.tool_calls) |tc|` loop (`engine.zig:416`), wrapping `self.dispatch(tc.name, tc.arguments_json)` (`engine.zig:435`). Ordering matters for the §3.6 single-line marker invariant: the pending marker line is written with no trailing newline, and its done-signal only arrives after dispatch — any hook bytes written between the two would land *inside* the marker's logical line. So **`preTool` fires before the marker write** (hook `ctx.writer` output lands on its own line above the marker, and the marker's `describeToolCall` text reflects the possibly-mutated args actually being dispatched), and **`postTool` fires after the done-signal + newline** have been written. A `preTool` veto skips `dispatch` entirely; the veto message flows through the same `.ok` append path a real result would (it is *not* a self-healing failure and never increments the retry counter), but its status dot resolves **red** (`tool_done_fail_sgr`) — the tool did not run, and a green dot would misreport that.
- **`postTool` firing scope**: fires only for results that flow back as successful tool output — real `.ok` results and `preTool` veto messages. It does **not** fire for `.invalid_args` diagnostics: those belong to the self-healing loop (§3.2–3.3), and letting a hook rewrite a diagnostic would corrupt the retry/escalation feedback the LLM depends on. A hook that wants failure visibility gets it from `onEscalate`.
- **`onEscalate`**: inside `escalate()` (`engine.zig:516`) — needs a new `writer: ?*Io.Writer` parameter (it currently has none), threaded from its one call site in `runToolLoop` (`engine.zig:488`).
- **Scratch arena reuse**: `runToolLoop` already owns `loop_arena` (`engine.zig:390`) for the whole call (not reset per iteration, since `view` accumulates across iterations) — hooks firing inside `runToolLoop` (`preLlm`, `postLlm`, `preTool`, `postTool`, and `onEscalate`, whose `escalate()` call site is within the loop) reuse `loop_arena.allocator()` as `Ctx.scratch`. `buildPlan`'s `preLlm` reuses its `arena` parameter. `onTurnStart`/`onTurnEnd` use `step()`'s new turn-scoped arena (above).

## Composition (multiple hooks)

`Hooks` is a tuple, exactly like `Tools`, and composition rules mirror tool dispatch's tuple-order determinism:

- **Order**: hooks fire in tuple order, at every hook point. The tuple order in `main.zig` is the one and only ordering knob.
- **Mutations chain**: each hook sees the previous hook's output — hook N's rewritten `args_json`/`result`/`content_override` is what hook N+1 receives.
- **First veto wins**: the first `preTool` veto short-circuits — later hooks' `preTool` methods do not fire for that call, and `postTool` then fires (tuple order) on the veto message.
- **Errors propagate**: a hook returning an error aborts the turn like any other engine error (`step()` callers already surface `anyerror`). Hooks that merely observe should swallow their own non-fatal errors.

## Ownership invariant

Hooks allocate any replacement/veto string from `Ctx.scratch` and never free anything themselves. The engine normalizes back to a fresh `gpa`-owned value at every boundary that already assumed `gpa` ownership before hooks existed — mirroring the `freeReply`/`Memory.append` dupe-then-free conventions already in the file:

- **`postTool`**: always `self.gpa.free(s)` — the original gpa tool result — regardless of whether a hook reassigned the working copy to scratch memory. Skip the free entirely when the result came from a `preTool` veto (no real gpa buffer exists in that case).
- **`postLlm`**: `reply.content` is never overwritten in place; a separate `content_override` is tracked and substituted only when choosing what to persist/return. `freeReply` always frees the untouched original `reply`.
- **`onEscalate`**: if a hook replaces the report, `gpa.dupe` the final value and free the original `allocPrint` buffer before returning `Outcome.escalated` (callers unconditionally `gpa.free` it).
- **`preLlm` / `onTurnStart`**: purely scratch-owned or caller-owned already — no hazard.
- **`onTurnEnd`**: observe-only (`*const Outcome`, see the contract section) — no ownership hazard by construction.

## Scoping decision: `postLlm` is content-only

`postLlm` may only override text `content`, never `tool_calls`. Tool-call interception is exclusively `preTool`/`postTool`'s job. This avoids desyncing `freeReply`'s iteration over `reply.tool_calls` with a hook that added/removed/rewrote calls.

## Documented limitations

- `postLlm` changes what's persisted to memory and the final `Outcome.final` text, but cannot un-stream tokens the provider already wrote live to `writer` mid-response (`llm.zig`'s `Glm.chat` streams as it parses SSE).
- `postLlm` is not honored inside `buildPlan`'s ephemeral planning exchange — a plan reply is parsed as JSON immediately, and a hook silently corrupting a plan degrades ungracefully (harder to detect than corrupting a final answer). Only `preLlm` runs during planning.
- **`preTool` arg mutation diverges from the persisted transcript.** The assistant message carrying the *original* `arguments_json` is appended to memory before `preTool` fires (the whole reply is persisted in one `Memory.append`), so the `.jsonl` audit log records the args the LLM wrote, while the tool executed the hook-mutated args (which the marker line and the tool-result message do reflect). Corollary: if the *mutated* args fail to parse, the self-heal diagnostic quotes JSON the LLM never wrote — a mutating hook, not the LLM, owns that confusion. Mutating hooks should rewrite conservatively.
- **`preLlm` re-fires on every `runToolLoop` iteration** against the same accumulating `view`. A hook that unconditionally appends (e.g. injects a system reminder) will duplicate its injection each iteration; hooks must be idempotent with respect to the view (check before appending, or mutate rather than append).

## Generic-signature impact

Zig has no default values for comptime generic parameters. Implementing this means `Engine`/`Agent` gain a required third `comptime Hooks: anytype` parameter, with an explicit `.{}` at every existing call site that doesn't need hooks (each `Engine(TestTools, llm.Mock)` test instantiation in `engine.zig`). `agent.zig` does not hardcode `.{}` — `Agent(Tools, Provider, Hooks)` *forwards* the tuple to its inner `Engine`, otherwise the TUI path could never use hooks; `main.zig` names the concrete tuple once (as it already does for `Tools`) and passes it to `Agent(...)`.

## Sample hook (for validating the design once implemented)

A `tool_audit_log` hook under a new `src/plugins/hooks/` directory (mirroring `src/plugins/tools/`), implementing `preTool`/`postTool` only: writes `[hook] calling X with ...` / `[hook] X returned ...` lines via `ctx.writer` alongside the existing `[● name: action]` marker.

## Docs to update when this lands

- `Architecture_Design.md`: new **§3.7 "Interceptor Hooks"** (§3.6 is now taken by "Tool-Call Status Markers"), plus a new **§8 "The Hook Plugin Contract"** mirroring §7's tool-contract code sample (the doc has no other §8, so the contract section takes that number), and a §6 project-structure update adding `core/hook.zig` / `plugins/hooks/`.
- `CLAUDE.md`: Architecture section update describing `Hooks`/`hook.zig`/`src/plugins/hooks/`, symmetric to the existing tool-contract bullet — per the project's own "update the doc in the same change" rule.
- `src/main.zig`'s `test { refAllDecls(...) }` block: add lines for `core/hook.zig` and any `src/plugins/hooks/*` module that carries its own `test` blocks — Zig 0.16 silently runs zero of a new file's tests otherwise (see the existing gotcha note in CLAUDE.md).

## Implementation notes

The design above was implemented after review (same change as these amendments): `src/core/hook.zig`, hook wiring in `src/core/engine.zig`, `Hooks` forwarding in `src/core/agent.zig`/`src/main.zig`, the `tool_audit_log` sample hook in `src/plugins/hooks/`, and inline tests in `engine.zig` covering veto, mutation, override, injection, and escalation-report paths.
