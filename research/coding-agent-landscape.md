# Coding Agent Landscape Research (March 2026)

## Target Architecture for Kaisha

Pi-mono core (4 tools + extensions) + NullClaw patterns (vtable interfaces, sandboxing) + LSP integration (from Crush).

---

## Tier 1 — Direct references for Kaisha

### Pi-mono (badlogic/pi-mono)
- **Language:** TypeScript monorepo
- **Stars:** ~25K
- **License:** Open source
- **Core:** Just 4 tools — read, write, edit, bash. ~300 word system prompt.
- **Architecture:** Layered monorepo (foundation → core → apps). 4 modes: interactive, print/JSON, RPC, SDK.
- **Extension system:** TypeScript modules adding tools, commands, keybindings, event handlers, UI. Located in `~/.pi/agent/extensions/` or `.pi/extensions/`. Shareable as npm/git packages.
- **Why it matters:** Closest match to what Kaisha already is. Same philosophy, same tool set. Extension system is what Kaisha needs next.
- **Weakness:** TypeScript — architecture ports well, implementation doesn't.
- **Links:** https://github.com/badlogic/pi-mono, https://mariozechner.at/posts/2025-11-30-pi-coding-agent/

### NullClaw (nullclaw/nullclaw)
- **Language:** Zig (45K lines)
- **Binary:** 678KB, <2ms boot, <1MB RAM
- **License:** Open source
- **Architecture:** Every subsystem is a vtable interface (`*anyopaque` + function pointer structs). Swap implementations via config, no recompile.
- **Components:** 50+ AI providers, 35+ tools, 19 channel integrations (Slack, Discord, Telegram, etc.)
- **Sandboxing:** Multi-layer — Landlock (Linux), Firejail, Docker
- **Why it matters:** Proves the Zig agent pattern works. Vtable architecture is the reference for how to do interfaces in Zig.
- **Weakness:** General assistant, not coding-focused. Tool depth for SWE is shallow — no AST, no LSP, no diff editing.
- **Links:** https://github.com/nullclaw/nullclaw, https://nullclaw.org/

### Crush (charmbracelet/crush)
- **Language:** Go (Bubble Tea TUI)
- **Stars:** ~21.6K
- **License:** Open source
- **Architecture:** TUI agent with "fantasy" abstraction layer for multi-provider AI. SQLite for conversation history.
- **Key differentiator:** **Native LSP integration** — understands code structure (definitions, references, types), not just text grep.
- **Tools:** File manipulation, shell execution, LSP queries, MCP support
- **Why it matters:** Only terminal agent with real LSP integration. This is the reference for adding code intelligence to Kaisha.
- **Weakness:** More feature-heavy than pi-mono. TUI is Bubble Tea, not extractable. Bigger than what Kaisha needs at core.
- **Links:** https://github.com/charmbracelet/crush, https://deepwiki.com/charmbracelet/crush/6.4-lsp-integration

---

## Tier 2 — Worth studying for specific patterns

### SWE-agent (Princeton/Stanford)
- **Language:** Python
- **Stars:** ~15K
- **Key idea:** Agent-Computer Interface (ACI) — tools designed FOR LLMs, not adapted from human tools. Mini version is 100 lines, scores 74% on SWE-bench.
- **Sandboxing:** Docker container
- **Lesson:** Design tools around how LLMs think, not how humans work.

### Goose (block/goose)
- **Language:** Rust
- **Stars:** ~27K
- **Key idea:** MCP-first extensibility. 3-component design: Interface / Agent / Extensions. Builtin extensions compiled into binary as Rust implementing `McpClientTrait`.
- **Lesson:** MCP trait pattern maps well to Zig interfaces. Clean separation of concerns.

### Codex CLI (openai/codex)
- **Language:** Rust
- **Stars:** ~20K+
- **Key idea:** App Server protocol (Items/Turns/Threads). Platform-native sandboxing (seatbelt on macOS, bubblewrap on Linux).
- **Lesson:** Sandboxing without Docker. The Items/Turns/Threads abstraction for session management.

### OpenCode (opencode-ai/opencode)
- **Language:** Go
- **Stars:** ~122K
- **Key idea:** 75+ provider support, LSP integration, SQLite storage, vim-like editor
- **Lesson:** LSP + SQLite patterns. But too feature-heavy — opposite of minimal philosophy.

### Aider (Aider-AI/aider)
- **Language:** Python
- **Stars:** ~30K+
- **Key idea:** Tree-sitter repository map — extracts symbol definitions from ASTs across entire repo. Best code context approach.
- **Lesson:** Tree-sitter for repo-wide code understanding. `grep-ast` for AST-aware search.

### Agentless (UIUC)
- **Language:** Python
- **Stars:** ~2K
- **Key idea:** No agent loop at all. 3-phase pipeline: Localize → Repair → Validate. Beats many agents at $0.34/issue.
- **Lesson:** Sometimes a pipeline beats an agent loop. The hierarchical localization (file → class → method → edit location) is smart.

---

## Tier 3 — Niche / early stage

| Project | Language | Stars | Key idea |
|---------|----------|-------|----------|
| picocode | Rust | 38 | Minimal CI-focused coding agent with personas |
| Devon | Python+TS | 4K | Multi-agent specialization (code gen, explore, test, debug) |
| Mentat | Python | 3K | GitHub bot integration — fleet of agents handling PRs |
| Moatless Tools | Python | 1K | Dual ReAct loops. $0.01/issue with DeepSeek |
| AutoCodeRover | Python | 3K | AST-first code navigation. Statistical fault localization |

---

## Autonomous Employee / VM Agents

| Project | Type | Key capability |
|---------|------|----------------|
| **Devin** (Cognition) | Proprietary | Full VM (terminal + editor + browser). Gold standard but closed source |
| **OpenHands** | Python+TS, 69K stars | Open-source Devin alternative. Docker desktop with bash + browser + VNC + VSCode |
| **Agent S2** (Simular AI) | Open source | Computer-use agent. Outperforms Claude Computer Use and OpenAI CUA |
| **OpenCUA** (xLang) | Open source | Computer-use framework spanning 3 OSes, 200+ apps |

---

## Architecture Decision: Implementation Order

### Current state (what Kaisha has)
- 5 tools: read, write, edit, bash, glob
- Agent loop (lyzr.zig)
- LLM API client (client.zig)
- Detailed tool prompts via @embedFile
- Chat UI (raylib/raygui)
- JSONL storage

### Phase 1 — Finish pi-mono parity
- Extension/plugin system (load custom tools at runtime)
- Skills (reusable prompt templates)
- Multi-provider support
- Session management (multiple conversations)

### Phase 2 — LSP integration (biggest differentiator)
- LSP client: JSON-RPC over stdin/stdout to language servers (zls, gopls, pyright, etc.)
- Expose as agent tools: `lsp_definition`, `lsp_references`, `lsp_hover`, `lsp_diagnostics`
- Only need ~5 of the ~50 LSP message types
- Estimated: 1000-2000 lines of Zig

### Phase 3 — NullClaw-style vtable refactor
- Extract interfaces for providers, tools, channels
- Do this AFTER having 2+ providers (don't abstract prematurely)
- `*anyopaque` + function pointer structs (idiomatic Zig)

### Phase 4 — Sandboxing
- macOS: sandbox-exec / seatbelt profiles (~200 lines)
- Linux: Landlock LSM (~200 lines)
- Docker: spawn container via bash (fallback)

### Phase 5 — Autonomous employee features
- Channel integrations (Slack, Discord — HTTP APIs)
- Computer-use (screen capture + mouse/keyboard control)
- Meeting attendance (calendar + video call APIs)
- VM execution environment

---

## Key Technical Patterns to Adopt

1. **ACI principle** (SWE-agent): Design tools for how LLMs think, not how humans use terminals
2. **Vtable interfaces** (NullClaw): `*anyopaque` + fn pointer structs for swappable components
3. **Tree-sitter repo map** (Aider): AST-based symbol extraction for code context
4. **LSP as tool** (Crush): Wrap LSP operations as agent-callable tools
5. **Hierarchical localization** (Agentless): file → class → method → edit location
6. **Multi-layer sandboxing** (NullClaw/Codex): OS-native + container fallback
7. **Extension system** (Pi-mono): Minimal core + user-extensible tools/skills/themes
