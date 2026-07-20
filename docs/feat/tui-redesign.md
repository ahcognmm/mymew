# TUI Redesign

**Status: implemented** (all four phases, 2026-07). This doc is kept as the design rationale;
the source of truth for current behavior is `Architecture_Design.md` §3.4/§3.6/§5.1 and the
code (`src/tui/app.zig`, `src/main.zig`).

Design proposal for the second iteration of `src/tui/app.zig`. The current TUI is a solid
skeleton — alt screen, SIGWINCH handling with a self-pipe wakeup, dual-thread streaming,
O(viewport) rendering with incremental rewrap, and the in-place tool-dot patching mechanism
(design doc §3.6) are all keepers. This doc is about what's missing and what should change,
audited against modern TUI conventions (lazygit/fzf/helix-class hygiene).

Non-goals: no framework adoption (stays hand-rolled, dependency-free), no multi-panel layout
(a chat agent is a conversation, not a dashboard — single-column is the right canonical
layout), no change to the `io_bus` byte-stream protocol or the `app.zig`-has-no-`core/*`-import
rule.

## 1. Audit of the current TUI

Ranked by severity. ✅ = already right, keep.

| # | Finding | Severity |
|---|---------|----------|
| 1 | **Unicode is broken end-to-end.** `wrapLogicalLine` counts *bytes* as columns (`col += 1` per non-escape byte), so any multi-byte UTF-8 in the LLM's output (CJK, emoji, `’`, box chars) wraps early and can split mid-codepoint. `handleKey` drops every byte ≥ 127, so the user cannot *type* non-ASCII at all. | correctness |
| 2 | **Composer overflow corrupts the screen.** `drawInputLine` writes `"> " + input` at the last row with no clipping; once input exceeds the terminal width, DECAWM autowrap on the bottom row scrolls the whole alternate screen up one line — status line and transcript shift and never recover. | correctness |
| 3 | **No mid-turn cancel.** `Agent.requestStop()` sets `should_exit`, which the background loop only checks *between* turns. A runaway turn (many chained tool calls) cannot be interrupted except by killing the app. | UX, needs a small `core/` change |
| 4 | **Panic leaves the terminal broken.** Zig panics do not run `defer`s, so a panic exits with raw mode + alt screen still active — the classic worst-case TUI failure. Needs a root-level panic override that restores termios and leaves the alt screen before the default handler prints. | hygiene |
| 5 | **Zero discoverability.** No footer hints, no help screen. Ctrl+P (style toggle), PgUp/PgDn, and Ctrl+C are all invisible — a new user has to read `main.zig` to learn the keymap. | UX |
| 6 | **Composer is a byte bucket.** No cursor movement (append/backspace only), no multi-line input (design doc §5.1 promises Shift+Enter newlines), no prompt history. | UX |
| 7 | **Ok/fail tool dots are color-only.** In monochrome (or for red-green CVD users) a green `●` and a red `●` are identical. | accessibility |
| 8 | **No scroll indicator.** When the user scrolls up (`view_start != null`), streaming continues into the tail invisibly with no "N rows below" cue and no visible way back. | UX |
| 9 | **Ctrl+Z is dead.** ISIG is off and byte 26 falls into the ignored range — suspend silently does nothing. Either support it properly or it stays a dead key. | hygiene |
| 10 | **Colors are hardcoded literals**, scattered through `app.zig`/`engine.zig`; `NO_COLOR` is not honored. (They are at least 16-ANSI theme-coherent colors, not hex — half right.) | polish |
| 11 | `\r` bytes (e.g. the agent error path writes `"\r\n[error: …]"`) land in the transcript and count as a width-1 column in wrapping. | polish |
| ✅ | Alt screen, restore-on-clean-exit, SIGWINCH rewrap + immediate wakeup, event-driven redraw (400 ms tick only animates), background-thread I/O, O(viewport) render with incremental tail rewrap, headless `-p` dual-product mode, in-place dot patching. | keep |

Clutter audit: not applicable in the usual direction — the current UI is *under*-decorated,
not over-decorated. The redesign deliberately adds no borders; chrome stays at two rows.

## 2. Layout

Single-column conversation, borderless, three regions. The composer grows upward (1–5 rows)
by shrinking the transcript; the transcript and the bar never move otherwise.

### Standard (≥ 80 cols), idle

```
 You: why does the tokenizer fail on emoji?

 │ The user is asking about the width handling in…      ← thinking span (dim, cyan gutter)
 [✓ read_file: Reading file src/tui/app.zig]
 [✗ execute_command: zig build test]
 The wrap loop counts bytes, not columns, so a 4-byte
 emoji consumes four cells of budget…
 [4.2s]

 ❯ how should I fix it█                                 ← composer, 1–5 rows
 Enter send · M-↵ newline · ^G help · ^C quit           [react] · glm-4.6 · default
```

(`^P style` and the rest of the keymap live behind `^G` — keeping the hint row at 44 columns
is what lets the full right-side identity fit at a standard 80-column terminal.)

### While the agent is working (bar is contextual)

```
 ❯ █
 ● thinking… 3.2s · Esc cancel                          [plan 2/4] · glm-4.6 · default
```

### While scrolled up

```
 ❯ █
 ↑ 24 rows below · PgDn newest · Esc jump to tail       [react] · glm-4.6 · default
```

The single bottom bar replaces the current status line *and* serves as the footer hint bar:
left side is contextual (hints when idle, spinner + elapsed + cancel hint while busy, scroll
position when scrolled — in that priority order, busy > scrolled > hints), right side is
persistent context (orchestration style — including live plan-step progress `plan i/n` parsed
from the §3.5 step markers —, model name, session name). Left side is truthful state, right
side is identity; both are dim so the transcript stays the loudest thing on screen.

### Floor: 80×24 and a 60-col tmux split

- 80×24: 22 transcript rows + 1 composer row + 1 bar. Hints fit at 80 cols (the hint string
  above is 44 cols; right context ~28 cols).
- 60 cols: right-side context drops first (style tag only, then nothing); hints compress to
  `↵ send · ^G help`. Transcript wraps narrower — already handled by rewrap.
- Below **40×6**: clear the screen and print `terminal too small (40×6 min)` centered, keep
  polling; resume rendering when resized back. Today this case renders garbage.

## 3. Keymap

Typing is the primary activity, so no bare-letter bindings; everything is Ctrl/Alt/function.

| Key | Action |
|---|---|
| `Enter` | send (non-empty) |
| `Alt+Enter` | insert newline (reliable everywhere; `Shift+Enter` additionally honored when the terminal supports kitty CSI-u — progressive enhancement, matching §5.1's promise) |
| `←/→`, `Home/End`, `Ctrl+A/E` | cursor movement in composer |
| `↑/↓` | move within multi-line composer; at top/bottom edge (or empty), recall prompt history |
| `Ctrl+W` / `Ctrl+U` | delete word / clear composer |
| `PgUp/PgDn` | scroll transcript (arrows no longer scroll — they belong to the composer now) |
| `Esc` | priority order: cancel running turn → jump scroll to tail → clear composer |
| `Ctrl+P` | toggle orchestration style (kept) |
| `Ctrl+G` | help overlay (full keymap; any key dismisses). `?` is a typeable character, so it can't be the binding |
| `Ctrl+L` | force full redraw |
| `Ctrl+Z` | suspend properly: restore termios, leave alt screen, `raise(SIGTSTP)`; on `SIGCONT` re-enter and full redraw |
| `Ctrl+C` / `Ctrl+D` | quit cleanly (kept) |

Mouse: enable wheel-scroll only (`?1000;1006` reporting, translating wheel events to
transcript scroll; clicks ignored). Trade-off: mouse reporting disables drag-to-select in the
emulator (Shift bypasses it) — but without it, most emulators' alt-screen wheel fallback sends
arrow keys, which now edit the composer. Wheel capture is the lesser evil. If it proves
annoying, it's one escape sequence to turn off.

History: composer submissions are already persisted (`.jsonl` memory hydrates every `role:
.user` message) — history recall reads from what the engine already loaded, no new storage.

## 4. Cancel (the one `core/` change)

`Engine` gains `cancel_requested: std.atomic.Value(bool)`. `runToolLoop` checks it at the top
of each iteration (before each provider call) and between tool dispatches. On cancel: append a system note `"[turn cancelled by
user]"` to memory (same persistence rules as everything else), return a new `Outcome.cancelled`,
and the TUI prints a dim `[cancelled]` line. The provider HTTP call itself is not aborted
mid-stream in v1 — cancellation takes effect at the next loop boundary, which is honest enough
(the bar shows `cancelling…` until it lands). `Architecture_Design.md` §3 gets a short
"Cancellation" subsection in the same change, per the repo rule.

## 5. Visual language

- **Semantic theme tokens.** One `Theme` struct (`accent`, `muted`, `ok`, `err`, `warn`,
  `gutter_thinking`, `gutter_error`, `you_label`) holding SGR strings, defaulting to the
  current 16-ANSI choices. `NO_COLOR=1` (and `TERM=dumb`) swaps in a theme of empty strings —
  the layout already carries meaning without color, which is the point. The tool-dot
  *protocol* bytes shared with `engine.zig` are explicitly **not** themed: they are a wire
  format, and the fixed-12-byte invariant is what makes in-place patching safe.
- **✓/✗ finals for tool dots.** On the done-signal, patch the pending `●` to a green `✓`
  (U+2713) or red `✗` (U+2717) instead of a green/red `●`. Both are 3-byte UTF-8 like `●`,
  so the 12-byte in-place patch invariant holds untouched — this fixes color-only signaling
  (finding 7) for free. Pending stays a blinking yellow `●`. `engine.zig`'s doc comment and
  the §3.6 literals update in both files, same duplication convention as today.
- **Error gutter.** Generalize `Row.is_thinking` to `gutter: enum { none, thinking, err }`.
  Escalation reports and `[error: …]` lines render with a red left bar, same mechanism as the
  thinking gutter — this is the honest replacement for §5.1's never-built "Inspector Sidebar",
  and §5.1 should be amended to match (single column + gutter blocks, no sidebar).
- **No borders anywhere.** Whitespace and the two gutters are the only structure. The `[4.2s]`
  turn-time line and blank-line separators stay as-is.

## 6. Unicode correctness (finding 1)

Wrapping walks *codepoints*, not bytes, and charges each its display width: a small
hand-rolled `charWidth(cp: u21) u2` — zero-width (combining marks, ZWJ, VS16), wide (a compact
sorted range table of East Asian Wide/Fullwidth + emoji presentation), else 1. This is
`wcwidth` reduced to ~30 ranges, dependency-free, and grapheme clusters are *not* segmented in
v1 (a ZWJ emoji family may over-count; acceptable — miswrapping by a cell beats splitting
mid-codepoint). The composer accepts UTF-8 input by accumulating multi-byte sequences instead
of dropping bytes ≥ 127, and cursor movement steps by codepoint. `\r` is stripped on append
(finding 11).

## 7. Implementation phases

Each phase ships independently and `zig build test` stays green throughout. New pure-function
tests ride along: wrap-width with CJK/emoji fixtures, composer editing ops, and one pinned
80×24 frame snapshot (size- and color-pinned, so it can't flap).

1. **Correctness floor** — codepoint/width-aware wrapping, UTF-8 composer input, composer
   horizontal clipping (no autowrap scroll), root panic handler restoring the terminal,
   too-small guard, `\r` stripping. No behavior change visible to ASCII-only users.
2. **Composer + cancel** — multi-line grow (1–5 rows), cursor editing, history recall,
   `Alt+Enter`, `Esc` priority chain, `Engine.cancel_requested` + `Outcome.cancelled`
   (+ `Architecture_Design.md` update).
3. **Chrome** — contextual bottom bar (hints / busy / scrolled), `plan i/n` progress, scroll
   indicator, `Ctrl+G` help overlay, ✓/✗ dot finals, error gutter (+ §5.1 amendment).
4. **Polish** — `Theme` tokens + `NO_COLOR`/`TERM=dumb`, wheel scroll, `Ctrl+Z` suspend,
   `Ctrl+L` redraw.

## 8. Addendum: the plan panel (2026-07)

User request after the initial redesign shipped: in plan-execute mode, the plan should not
print into the chat view — it lives in a dedicated block **above the composer**, tracking
which step is running.

```
 …transcript (tool markers, step output — no plan text, no [step] markers)…

 ▍plan 2/5
 ▍✓ check ecr-refresh cronjob status
 ▍● describe node uat-hybrid-app-03
 ▍○ check pod scheduling constraints
 ▍○ summarize findings
 ❯ █
 ● thinking… 48s · Esc cancel                    [plan 2/5] · glm-5.2 · default
```

Decisions:

- **Fed by the stream, not by `core/*`.** §3.5's bracket markers were designed for exactly
  this ("a future consumer parsing the stream"). `Tui.processStream` is a hold-back filter:
  a line starting `[` at column 0 is buffered only while it remains a prefix of a known
  phase marker; anything else (a `[hook]` line, `[cancelled]`, a tool-dot marker whose second
  byte is ESC) flushes through after at most a couple of buffered bytes. The buffer survives
  chunk boundaries — the `ChannelWriter` has a zero-byte buffer, so markers genuinely arrive
  split.
- **"Instead of", per the request:** the `[plan]…[/plan]` body, `[planning...]`,
  `[step]`/`[/step]`, and `[synthesis]` marker lines are suppressed from the transcript —
  the panel now carries that state, and showing it in both places fails the clutter audit.
  Step *output*, tool markers, `[cancelled]`, and escalation reports stay in the transcript.
  The plan is still persisted to `.jsonl` memory; only presentation moved.
- **Same visual language:** no border (the green field in the user's sketch was read as a
  location, not a border spec) — an accent `▍` gutter binds the block, and the step glyphs
  reuse the established tool-marker language: green `✓` done, yellow `●` running, dim `○`
  pending. Header states: `planning…` → `plan i/n` → `plan · synthesizing…`; degrade path
  (no parseable plan) shows the single step from its `[step 1/1: …]` marker.
- **Floor:** panel caps at header + 6 steps and never squeezes the transcript below 8 rows;
  below 16 terminal rows it collapses to header-only; when steps overflow, the window follows
  the current step. The panel disappears when the turn ends.
