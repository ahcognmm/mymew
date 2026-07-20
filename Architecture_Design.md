# **Comprehensive Architecture Design: DIY Zig AI Agent**

## **1\. Executive Summary**

This document outlines the architecture for a highly modular, high-performance AI Agent written in Zig. The system is designed to be completely pluggable, allowing developers to swap out Language Models (LLMs), Memory storage, Tools, and User Interfaces.  
To maximize performance and leverage Zig's strongest features, the plugin system utilizes **comptime polymorphism (duck-typing)** rather than dynamic shared libraries (.so/.dll). This results in a single, statically-linked binary with zero runtime overhead for tool routing, robust compiler safety, and auto-generated JSON schemas.

## **2\. Core Architecture: The comptime Registry**

The system relies on an "Engine" (The Orchestrator) that accepts a tuple of Types at compile time.

* **Duck-Typing Interface:** Plugins do not implement a rigid \*anyopaque VTable. Instead, they just need to match a structural contract defined by the engine. If a struct exposes the required public functions, the compiler accepts it.  
* **Static Routing:** Tool execution requests are routed using Zig's inline for unrolling. This compiles down to a static series of string comparisons, eliminating dynamic dispatch overhead.  
* **Schema Auto-Generation:** The engine parses the Zig structs of all registered tools during initialization to automatically generate the massive JSON tool schemas required by OpenAI, Anthropic, and GLM (Zhipu). Reflection is recursive, not just flat scalars: an `Args` field may itself be a nested struct or a slice of structs (`items: []const Item`), which `core/tool.zig`'s `jsonSchemaFor`/`objectSchemaFor` expand into proper JSON Schema `"object"`/`"array"` fragments — the `todo_write` tool (§3.8) is the reference case, with its `todos: []const TodoItem` field. Enum fields' schemas also enumerate their valid tag names (`"enum":["a","b",...]`), not just a bare `"string"` type.

## **3\. Orchestration Styles**

The Orchestrator is the central brain of the agent. It does not know *how* to call specific APIs; it routes a unified \[\]Message array between the IO, Memory, and LLM Provider plugins. There is a single orchestration loop — **ReAct** (§3.1–3.3) — used for every turn. A runtime-selectable `Style` (§3.5; CLI flag `-m react|todo`, or the TUI's Ctrl+P toggle) does **not** select a different loop — an earlier version of this design ran a structurally separate Plan-and-Execute orchestrator, but per-step re-planning caused more problems than it solved (over-execution within a step, redundant re-work across steps) and was removed. `Style` is now a plain hook-visible mode flag (`hook.Ctx.style`) that `todo_tracker` (§3.8) reads to decide whether to nudge the model toward self-managing a todo list — the replacement mechanism for "help the model stay organized across a multi-step turn."

### **3.1. ReAct: Native Function Calling**

The agent exclusively relies on native LLM function calling (tools) rather than raw prompt parsing. When the LLM provider returns a finish\_reason \== "tool\_calls", the Orchestrator intercepts it, executes the requested Zig tool, and appends the result to the context as a role: "tool" message before looping back to the LLM.

### **3.2. The Self-Healing Loop**

Because LLMs can hallucinate malformed JSON arguments (e.g., missing quotes or brackets), the Orchestrator implements a safety net:

1. **Trap & Intercept:** If std.json.parse fails inside a tool, the error is trapped by the Orchestrator.  
2. **Feedback Formulation:** The Orchestrator constructs a system message containing the intended tool, the exact malformed JSON string, and the specific Zig parser error, sending it back to the LLM to correct itself.

### **3.3. Graceful Escalation & Context Pruning**

To prevent infinite loops and token drain if the LLM refuses to fix its syntax:

1. **Circuit Breaker:** A MAX\_RETRIES counter (usually 3\) is strictly enforced.  
2. **Transparent Escalation:** If the limit is hit, the engine stops talking to the LLM and sends a "Failure Report" to the UI, displaying the exact diagnostic log and broken JSON.  
3. **Context Cleanup:** Crucially, the Orchestrator **prunes** the failed JSON payloads and error messages from the active memory array, replacing them with a single System Note: *"User was notified that the tool failed due to syntax errors."* This keeps the LLM's memory uncluttered for the next prompt.

### **3.4. Cancellation**

A user can abort a running turn (the TUI binds Esc to this; `Agent.requestCancel()` → `Engine.requestCancel()`, an atomic flag with the same cross-thread convention as `Engine.style`). Cancellation is **cooperative and boundary-checked**, never mid-stream:

1. **Checkpoints:** the flag is checked at the top of `runToolLoop`'s loop, before every provider call — the one long, uninterruptible pole. An in-flight HTTP request is not aborted; the cancel lands at the next boundary and the UI shows "cancelling…" until it does.
2. **Not a failure:** unlike escalation (§3.3), nothing is pruned. Partial work stays in memory, followed by one System Note — *"Turn cancelled by the user before completion."* — so the next turn's LLM knows the previous turn was cut short rather than silently truncated. The engine emits a `[cancelled]` stream marker and `step()` returns a distinct `Outcome.cancelled`.
3. **Fresh per turn:** the flag is cleared at the start of every `step()`, so a cancel that races past the end of one turn can't kill the next.

### **3.5. Style Toggle: ReAct vs. Todo-Nudge Mode**

**History:** the first version of this design had a second orchestration style, Plan-and-Execute — an upfront LLM-generated plan, executed one step at a time as separate, curated `runToolLoop` calls. In practice this didn't prevent over-execution (a single step could still make unbounded tool calls — nothing capped work *within* a step, only the boundary *between* steps was enforced) and caused redundant work across steps (each step's curated view hid earlier steps' raw tool transcripts, so steps re-did work like re-reading files a prior step had already read). It was removed rather than patched, in favor of the mechanism Claude Code and similar coding agents actually use: one continuous loop, with the model maintaining its own todo list as ordinary tool calls the model chooses to make, rather than the harness pre-committing to a step boundary the model can't see past or plan around.

**What's left:** `Style` (`core/hook.zig`, re-exported as `engine.Style`) is a two-value `enum(u8) { react, todo }`, selected the same way as before (CLI `-m react|todo`, TUI Ctrl+P). Nothing in `Engine.step()`/`stepReact`/`runToolLoop` branches on it — there is exactly one loop. Its only effect is `hook.Ctx.style`, which any hook may read to vary its own behavior; today `todo_tracker` (§3.8) is the sole consumer, injecting a system nudge to create a todo list when `style == .todo` and none exists yet for the turn, and staying silent (identical to plain ReAct) otherwise. This keeps the toggle meaningful without smuggling a second orchestrator back in through the side door.

### **3.6. Tool-Call Status Markers**

Every tool call renders as exactly **one line** in the streamed transcript: `[● name: action]`, where the status glyph reports the call's live state — a blinking yellow `●` while pending, settling to a green `✓` (ok) or red `✗` (failed/vetoed) — and `action` is a short, tool-specific, human-readable description of what's being done (e.g. `read_file` → `Reading file /etc/hosts`; `execute_command` → the command itself, verbatim). The finals are distinct *glyphs*, not just colors, so ok/fail stays legible in monochrome and for red-green color-blind users; `✓`/`✗` are 3-byte UTF-8 like `●`, so all four status units stay byte-length-identical (the in-place-patch invariant below). There is no separate result-preview line — full tool output is still recorded in `self.mem`/`.jsonl` for audit/synthesis, just not streamed live.

* **Per-tool descriptions:** A tool may implement an optional `pub fn describe(alloc, args: Args) anyerror![]const u8` (`core/tool.zig`'s `describeArgs`, comptime-dispatched the same way `dispatch()` routes `execute` calls). Tools that don't implement it — or whose args fail to parse, or whose `describe` itself errors — fall back to a truncated dump of the raw JSON arguments. The result is always sanitized (`Engine.oneLine`) so an argument containing embedded newlines (e.g. a multi-line shell command) never breaks the one-line-per-call guarantee.
* **In-place dot patching, not re-emitted lines:** Since a tool call is a single synchronous, blocking `execute()` and calls never overlap (`runToolLoop` dispatches one at a time even within a multi-tool-call reply), the Orchestrator writes the marker line *once*, at dispatch start, with a pending-yellow dot (`tool_dot_pending`) — then, once `dispatch()` returns, writes a tiny, invisible "done" signal (`tool_done_ok_sgr`/`tool_done_fail_sgr`, an unused/reserved SGR sub-code real terminals silently ignore if any of it ever leaks through unstripped) instead of a new line. `tui/app.zig`'s `wrapLogicalLine` — which already scans every token chunk for known SGR sequences to track the "thinking" reasoning-span gutter — recognizes `tool_pending_sgr` (the dot's 5-byte color-set prefix) and records its byte offset in the transcript buffer; on the matching done-signal, it overwrites that exact `tool_dot_len` (12-byte) span in place with the `✓`/`✗` final and clears the pending offset. All four status variants (pending-bright `●`, pending-dim `●`, ok `✓`, fail `✗`) are deliberately the same 12 bytes, which is what makes in-place overwriting safe without shifting or re-wrapping anything downstream.
* **Blinking is TUI-driven, not terminal-driven:** Rather than relying on the ANSI blink SGR attribute (widely disabled/ignored by modern terminal emulators), the TUI blinks the pending dot itself: `Tui.tickDots` — the same ~400ms timer that already animates the "thinking..." status line — toggles the pending dot's bytes between the bright and dim yellow variants and triggers a redraw whenever a dot is pending.

This is a from-scratch, TUI-specific mechanism, not a generic streaming-protocol change — `core/engine.zig` still only ever talks to an `Io.Writer`; `tui/app.zig` still has zero dependency on `core/*` (the dot/marker byte sequences are duplicated as matching literals in both files, same convention as `thinking_start_sgr`/`thinking_end_sgr`).

### **3.7. Interceptor Hooks**

A second plugin category alongside tools (full design and rationale: `docs/feat/hooks.MD`). `Engine`/`Agent` take a third comptime parameter, `Hooks` — a tuple of hook types, `.{}` for none — whose members can observe, **mutate, or veto** the main orchestration steps. Seven hook points, all optional per hook (the contract is *sparse*, §8): `onTurnStart`/`onTurnEnd` (fired once per turn in `step()`, which owns a turn-scoped scratch arena for them), `preLlm` (before every provider call; mutates the outbound *view*, never persisted memory), `postLlm` (content-only override of a reply — never `tool_calls`), `preTool`/`postTool` (wrapping dispatch: `preTool` may rewrite args or veto — a veto skips dispatch, renders a red status dot, and flows back to the LLM as the tool result without counting as a self-healing retry; `postTool` may rewrite successful results but never sees self-healing diagnostics), and `onEscalate` (may replace the escalation report; the engine re-normalizes it to a gpa-owned string).

Key invariants:

* **Ownership:** hooks allocate replacements from `Ctx.scratch` (an engine-owned arena) and never free anything; the engine re-normalizes ownership at every boundary that assumed gpa ownership before hooks existed.
* **Composition:** hooks fire in tuple order at every point; mutations chain; the first `preTool` veto short-circuits the rest.
* **Dispatch:** same comptime pattern as tools — `inline for` over the tuple with `@hasDecl` checks, no vtables (§2).
* **View vs. persistence:** `preLlm` edits what the provider *sees*, not what `self.mem`/`.jsonl` records — e.g. `todo_tracker`'s injected reminder/nudge (§3.8) never touches persisted memory, only the outbound view for that call.
* **`Ctx.style`:** carries the turn's current `Style` (§3.5) so a hook can vary its behavior by mode without a dedicated hook point per mode; defaults to `.react`.

### **3.8. Task/Todo Tracking (Reference Tool \+ Hook Pair)**

A second reference plugin pair, alongside `calculator`/`tool_audit_log`: `src/plugins/tools/todo_write.zig` \+ `src/plugins/hooks/todo_tracker.zig`, demonstrating that a stateful-feeling agent capability can be built entirely out of the existing tool/hook contracts with **no `core/engine.zig` changes**.

* **The tool holds no state.** `todo_write`'s `Args` is `{ todos: []const TodoItem }` where `TodoItem` is `{ content, status: enum { pending, in\_progress, completed } }` — a nested array-of-structs field, made possible by the §2 schema-reflection extension. Every call replaces the whole list (the LLM always passes the full list, not a diff), so `execute()` stays a pure function of its args like every other tool — it just renders the list to a checklist string and returns it as the persisted `.tool` message content.  
* **The hook derives everything from message history, not shared state — and is what gives the style toggle (§3.5) meaning.** `todo_tracker.preLlm` scans the outbound `view` backward for the most recent `todo_write` tool result on every provider call. If found, it keeps exactly one system message in that view carrying the current list; if not found *and* `ctx.style == .todo`, it instead injects a nudge to create one before proceeding; if not found and `ctx.style == .react`, it stays silent. Either way, at most one injected message exists at a time, refreshed in place (or moved to the end and refreshed) rather than appended anew each iteration, satisfying the idempotence requirement `preLlm` hooks are subject to (docs/feat/hooks.MD; §3.7 above). Because this only touches the outbound `view`, never `self.mem`, it never pollutes the persisted `.jsonl` transcript.  
* **The one-line status marker is free; the full checklist lives in a panel, not the transcript.** The `[● todo\_write: Updating todo list (N items)]` marker line comes from the existing §3.6 mechanism (via `todo\_write.describe`) with zero new code. `todo\_tracker.postTool` wraps the full raw checklist in `[todos]`/`[/todos]` markers instead of printing it inline — `tui/app.zig` diverts that block into the live Todo Panel (§5.1) the same way the old Plan Panel diverted `[plan]`/`[/plan]` blocks, so the checklist doesn't scroll away with the rest of the transcript.

This pairing is the intended shape for future "the agent needs to remember X across calls" capabilities: derive state from `self.mem`/the outbound view via a hook, rather than reaching for module-level mutable state in a tool (no tool in this codebase does that, and introducing it would create cross-instance/test-isolation hazards a message-history-derived hook avoids entirely).

## **4\. State & Memory Management (.jsonl)**

Instead of a complex database or a volatile array, the agent uses an **append-only .jsonl (JSON Lines)** file for persistent memory.

* **Hydration:** On startup, the Memory Plugin reads the .jsonl file line-by-line to populate the active \[\]Message context.  
* **Instant Appends:** Every new prompt or response is simply stringified and appended as a new line to the file.  
* **Pruning execution:** When the Orchestrator triggers "Context Cleanup", the engine clears the physical .jsonl file and rapidly rewrites the newly cleaned \[\]Message array back to disk.

## **5\. I/O, UI, and Concurrency**

The agent uses a **Text User Interface (TUI)** (using libraries like vaxis or zigzag) instead of a basic linear CLI to provide a professional, application-grade experience.

### **5.1. UI Layout**

Single-column, borderless (full rationale and keymap: `docs/feat/tui-redesign.md`):

* **Main Chat View:** scrollable transcript viewport (top). Provider reasoning renders inside a dim, cyan-guttered "thinking" span; escalation reports and turn errors render inside a red-guttered error span (the agent brackets them with `\x1b[2;31m…\x1b[0m` stream markers — this gutter-block treatment replaced an earlier "Inspector Sidebar" idea: diagnostics stay in the one transcript, visually set off, rather than in a second panel).
* **Todo Panel:** a live block between the transcript and composer, present whenever a todo list is non-empty — an accent-guttered header (`▍ todo 2/5`, done/total) plus one row per item, colored by each row's already-baked-in leading glyph (`✓`→ok, `●`→warn, `○`→dim; `todo\_write` picked the glyph, the panel just maps it to a theme color). Fed by `tui/app.zig`'s `processStream`, which recognizes exactly two markers — `[todos]`/`[/todos]` (§3.8) — holding back candidate lines the same prefix-driven way tool-dot lines and other bracketed content still flush straight through, and diverting the captured block into the panel instead of the chat view. Overflow beyond a handful of rows collapses to a trailing "… N more" line rather than windowing around a "current" item, since todos (unlike the old Plan-and-Execute steps) aren't linear. **Deliberately not turn-scoped:** nothing resets it at turn end — a todo list is a standing, multi-turn artifact, so it only changes when a fresh `todo\_write` call arrives (or, at startup, when `main.zig` seeds it directly from the last persisted `todo\_write` result in hydrated `.jsonl` memory — the same data `todo\_tracker.preLlm` already reads, just surfaced in the UI too). The panel collapses to header-only on short terminals (never squeezing the transcript below 8 rows) and disappears when the list is explicitly emptied.
* **Composer:** multi-line input above the bar (`❯ ` prompt), growing 1–5 rows as content wraps; Enter sends, Alt+Enter inserts a newline (kitty CSI-u Shift+Enter honored if the terminal sends it), full cursor editing (arrows/Home/End/Ctrl+A/E/W/U), and ↑/↓ at the edges recall prompt history (seeded from hydrated `.jsonl` memory).
* **Contextual Bottom Bar:** one status/hint line, last row. Left side by state priority — busy (`● thinking… Ns · Esc cancel`, spinner animated by the TUI timer) > scrolled (`↑ N rows below…`) > idle key hints. Right side is identity: `[react]`/`[todo]` (§3.5 style toggle) · model · session, dropped piecewise on narrow terminals.
* **Hygiene:** alternate screen; panic-safe terminal restore (root panic handler, since Zig panics skip `defer`s); SIGWINCH re-wrap; Ctrl+Z suspend/resume; wheel-only mouse capture; `NO_COLOR`/`TERM=dumb` renders monochrome (chrome untinted, streamed SGR stripped at render); Unicode-width-aware wrapping (codepoints, wcwidth-style column charging); "terminal too small" notice below 24×6.

### **5.2. Dual-Thread Event Bus**

To ensure the TUI never freezes while waiting for heavy network requests or slow tools, the system is strictly decoupled:

* **Main Thread:** Runs the TUI loop, rendering the screen and capturing keystrokes.  
* **Background Thread:** Runs the ReAct Orchestrator.  
* **Communication:** They communicate safely via a Zig std.Thread.Queue using strongly typed events:  
  * PromptEvent(string): UI sends input to Orchestrator.  
  * TokenEvent(string): Orchestrator streams partial text back to the UI.  
  * ToolStartEvent(name): Orchestrator tells UI to spin a loader in the sidebar.

## **6\. Project Structure Blueprint**

diy-ai-agent/  
├── build.zig             \# Build script (defines dependencies and executable)  
├── build.zig.zon         \# Dependency manifests (e.g., zigzag/vaxis for TUI)  
└── src/  
    ├── main.zig          \# Entry point: Initializes threads, event bus, and kicks off TUI  
    ├── core/               
    │   ├── engine.zig    \# The Orchestrator (Comptime registry & ReAct loop)  
    │   ├── memory.zig    \# .jsonl file handling and context window pruning  
    │   ├── llm.zig       \# API wrappers for OpenAI/GLM/Anthropic  
    │   ├── tool.zig      \# The Comptime Interface Contract documentation  
    │   └── hook.zig      \# The (sparse) Interceptor Hook Contract (§3.7, §8)  
    ├── tui/                
    │   └── app.zig       \# Layout, rendering, and Event Queue consumer  
    └── plugins/            
        ├── tools/        \# Tool implementations (calculator.zig, web\_scraper.zig)  
        ├── hooks/        \# Interceptor hooks (tool\_audit\_log.zig)  
        └── io/           \# Alternative IO methods

## **7\. The Tool Plugin Contract**

Every tool passed into the AgentEngine at compile-time must export the following struct layout.  
pub const ToolContract \= struct {  
    pub fn name() \[\]const u8 { return "example\_tool"; }  
    pub fn description() \[\]const u8 { return "An example tool."; }  
    pub fn parametersSchema() \[\]const u8 {  
        return   
            \\\\{  
            \\\\  "type": "object",  
            \\\\  "properties": {},  
            \\\\  "required": \[\]  
            \\\\}  
        ;  
    }  
    pub fn execute(args\_json: \[\]const u8, alloc: std.mem.Allocator) anyerror\!\[\]const u8 {  
        \_ \= args\_json;  
        \_ \= alloc;  
        return "";  
    }  
};  

## **8\. The Hook Plugin Contract**

Interceptor hooks (§3.7) satisfy a **sparse** comptime contract — unlike §7's tool contract, where every member is mandatory, only `name()` is required here. Every other method is optional and checked at its engine call site via `if (@hasDecl(H, "methodName"))`; a hook implements only the points it cares about. This sparse-contract style is deliberate and precedent-setting for this codebase: tools stay all-mandatory, hooks are opt-in per method. `core/hook.zig` is the authoritative, compiled version of this contract (it defines `Ctx` and `PreToolAction`; the `Message`/`Outcome` types below live in `core/message.zig`/`core/engine.zig` and appear only illustratively, keeping `hook.zig` dependent on nothing but `std`).

pub const HookContract \= struct {
    pub fn name() \[\]const u8 { return "example\_hook"; }

    // All optional:
    pub fn onTurnStart(ctx: Ctx, user\_text: \*?\[\]const u8) anyerror\!void
    pub fn preLlm(ctx: Ctx, messages: \*std.ArrayList(Message)) anyerror\!void
    pub fn postLlm(ctx: Ctx, reply: \*const Message, content\_override: \*?\[\]const u8) anyerror\!void
    pub fn preTool(ctx: Ctx, tool\_name: \[\]const u8, args\_json: \*\[\]const u8) anyerror\!PreToolAction
    pub fn postTool(ctx: Ctx, tool\_name: \[\]const u8, result: \*\[\]const u8) anyerror\!void
    pub fn onEscalate(ctx: Ctx, tool\_name: \[\]const u8, diagnostic: \[\]const u8, raw\_args\_json: \[\]const u8, report: \*\[\]const u8) anyerror\!void
    pub fn onTurnEnd(ctx: Ctx, outcome: \*const Outcome) anyerror\!void
};

Registration mirrors tools exactly: add the module to the `Hooks` tuple in `src/main.zig`, next to the `Tools` tuple. The shipped reference hook is `src/plugins/hooks/tool_audit_log.zig`, an observe-only `preTool`/`postTool` audit trail written to the live output stream. Ownership, composition order, veto semantics, per-hook-point firing sites, and documented limitations are specified in `docs/feat/hooks.MD`.
