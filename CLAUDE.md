# Kaisha — Zig + raylib/raygui desktop AI agent

## Build & Run
- `zig build` to compile
- `zig build run` to run
- Zig 0.15, raylib 5.5, raygui, libcurl

## Behavior Rules
- **Be critical, not sycophantic.** Evaluate every suggestion (user's or your own) before endorsing it. Find weaknesses and tradeoffs. Never say "great idea" without verification.
- **Research by fit, not popularity.** When comparing tools/frameworks/approaches, rank by relevance to the actual problem, not by GitHub stars or hype.
- **Own mistakes directly.** If you missed something or gave bad advice, say so plainly. No hedging.
- **No filler.** No "Certainly!", "Great question!", "I'd be happy to help." Just do the work.
- **Never let a file grow past ~200 lines.** When a component gets large, stop and refactor into sub-components BEFORE adding more features. Extract reusable pieces into their own files immediately. A 600-line UI file is a failure of discipline, not a success of implementation. Each file should do one thing.
- **Compose, don't accumulate.** Build small components (diff_view, content_preview, pill_button, json_util) and compose them. Don't inline rendering logic, JSON parsing, and button drawing into one monolithic function.

---

## Project Vision

Kaisha is NOT just one app. It's a collection of **reusable Zig packages** that together form an autonomous AI employee. Each package is independently useful and publishable to the Zig community. Kaisha (the desktop app) is the consumer that ties them together.

### Philosophy
- **Token-efficient by design.** Kaisha must NEVER be a token-hungry tool. Every architectural decision should optimize for minimal token consumption. Retrieve don't dump — fetch only the context the current turn needs, never load entire histories into prompts. Use structured tool outputs with truncation over raw data. Prefer hierarchical localization (file → class → method → line) over brute-force context stuffing. Summarize and compact aggressively. A well-engineered agent that uses 10K tokens should outperform a lazy one using 100K. This is a core engineering constraint, not an optimization — treat token waste as a bug.
- **Pi-mono's minimalism:** 4 core tools (read/write/edit/bash), everything else via extensions. Small system prompt. Don't bake in what can be extended.
- **NullClaw's Zig patterns:** Vtable interfaces (`*anyopaque` + fn pointer structs) for swappable components. Multi-layer sandboxing. Compile to a single small binary.
- **GitAgent standard:** Agent definitions as files in git repos (SOUL.md, RULES.md, skills/). Kaisha implements the gitagent spec natively in Zig — no npm dependency.
- **Community-first:** Every layer is a standalone Zig package others can use. Don't build a monolith.
- **Inject, don't import.** Packages communicate through vtable interfaces. agent-core never knows about libcurl. Kaisha wires implementations at init time.

### Package Architecture (planned)

```
gitagent/            → Zig implementation of the gitagent.sh standard
                       (parse agent.yaml, SOUL.md, RULES.md, skills/, workflows)
                       (validate, export, run — CLI + library)

agent-core/          → Minimal agent loop + tool system (pi-mono equivalent in Zig)
                       (4 core tools, extension loading, provider interface)
                       (vtable interfaces for tools, providers, channels)

lsp-client/          → LSP client library for Zig
                       (JSON-RPC over stdin/stdout, definition/references/hover/diagnostics)

sukue/      → Lightweight app toolkit for Zig on raylib — simple API, composable components
                       (theme, scroll, buttons, text, diff view, markdown renderer, layout)

kaisha/              → The desktop app (consumes all of the above)
                       (sukue UI + agent core + gitagent loader + LSP)
```

### Design Decisions Made
- Agent definitions follow gitagent standard (SOUL.md, RULES.md, skills/)
- Tool prompts embedded at compile time via @embedFile from markdown files
- Tools always use absolute paths; ~ expanded via $HOME; start from home when exploring
- Glob ignores .git, node_modules, build dirs; caps at 300 results with truncation notice
- Bash output capped at 30KB with truncation notice (pipe read cap 1MB)
- Read capped at 2000 lines with "use offset to read more" notice
- All tool outputs tell the LLM when they're truncated and how to get more

### Implementation Order
1. ~~Pi-mono parity~~ DONE (providers, sessions, compaction, skills, templates, settings, events, steering)
2. ~~Non-blocking UI + permissions~~ DONE (thread, EventQueue, tool feed, permission gate)
3. ~~sukue extraction~~ DONE (UI package owns raylib, kaisha imports through sukue)
4. **NOW: Remote execution** — Transport interface → WebSocket server → kaisha-server binary → client reconnect (research/remote-execution-plan.md)
5. **Next:** LSP integration (lsp-client/ package)
6. **Then:** sukue Context abstraction (remove transitional sukue.c, wrap raylib fully)
7. **Then:** gitagent Zig implementation
8. **Then:** Sandboxing (Landlock on Linux, Docker fallback)
9. **Later:** sukue layout + focus system
10. **Later:** Autonomous employee features (channels, computer-use, meetings — builds on remote execution)

### Key References
- Pi-mono: https://github.com/badlogic/pi-mono (architecture reference)
- NullClaw: https://github.com/nullclaw/nullclaw (Zig patterns reference)
- Crush: https://github.com/charmbracelet/crush (LSP integration reference)
- GitAgent: https://github.com/open-gitagent/gitagent (agent definition standard)
- SWE-agent ACI: design tools FOR LLMs, not adapted from human tools
- Research docs: research/ directory in this repo
