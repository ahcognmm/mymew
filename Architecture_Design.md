# **Comprehensive Architecture Design: DIY Zig AI Agent**

## **1\. Executive Summary**

This document outlines the architecture for a highly modular, high-performance AI Agent written in Zig. The system is designed to be completely pluggable, allowing developers to swap out Language Models (LLMs), Memory storage, Tools, and User Interfaces.  
To maximize performance and leverage Zig's strongest features, the plugin system utilizes **comptime polymorphism (duck-typing)** rather than dynamic shared libraries (.so/.dll). This results in a single, statically-linked binary with zero runtime overhead for tool routing, robust compiler safety, and auto-generated JSON schemas.

## **2\. Core Architecture: The comptime Registry**

The system relies on an "Engine" (The Orchestrator) that accepts a tuple of Types at compile time.

* **Duck-Typing Interface:** Plugins do not implement a rigid \*anyopaque VTable. Instead, they just need to match a structural contract defined by the engine. If a struct exposes the required public functions, the compiler accepts it.  
* **Static Routing:** Tool execution requests are routed using Zig's inline for unrolling. This compiles down to a static series of string comparisons, eliminating dynamic dispatch overhead.  
* **Schema Auto-Generation:** The engine parses the Zig structs of all registered tools during initialization to automatically generate the massive JSON tool schemas required by OpenAI, Anthropic, and GLM (Zhipu).

## **3\. The ReAct Orchestrator Engine**

The Orchestrator is the central brain of the agent. It does not know *how* to call specific APIs; it routes a unified \[\]Message array between the IO, Memory, and LLM Provider plugins.

### **3.1. Native Function Calling**

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

## **4\. State & Memory Management (.jsonl)**

Instead of a complex database or a volatile array, the agent uses an **append-only .jsonl (JSON Lines)** file for persistent memory.

* **Hydration:** On startup, the Memory Plugin reads the .jsonl file line-by-line to populate the active \[\]Message context.  
* **Instant Appends:** Every new prompt or response is simply stringified and appended as a new line to the file.  
* **Pruning execution:** When the Orchestrator triggers "Context Cleanup", the engine clears the physical .jsonl file and rapidly rewrites the newly cleaned \[\]Message array back to disk.

## **5\. I/O, UI, and Concurrency**

The agent uses a **Text User Interface (TUI)** (using libraries like vaxis or zigzag) instead of a basic linear CLI to provide a professional, application-grade experience.

### **5.1. UI Layout**

* **Main Chat View:** Center scrollable area for conversation.  
* **Input Bar:** Fixed, multi-line bottom bar (Shift+Enter for newline, Enter to send).  
* **Inspector Sidebar:** A dedicated space to show spinning loaders for active tools, and to render the raw "Diagnostic Logs" when a tool completely fails, keeping the main chat clean.

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
    │   └── tool.zig      \# The Comptime Interface Contract documentation  
    ├── tui/                
    │   └── app.zig       \# Layout, rendering, and Event Queue consumer  
    └── plugins/            
        ├── tools/        \# Tool implementations (calculator.zig, web\_scraper.zig)  
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
