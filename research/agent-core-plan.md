# agent-core Plan

## Status: Phase 1 complete (extraction). Phase 2 in progress (pi-mono parity).

---

## Pi-mono Parity Gap Analysis

### Done

| Feature | Status | Notes |
|---------|--------|-------|
| 4+1 core tools (read/write/edit/bash/glob) | DONE | Via StaticTool→Tool vtable |
| Agent loop (send → tool calls → execute → repeat) | DONE | loop.zig, configurable max_iterations |
| OpenAI-compatible provider (SSE streaming) | DONE | providers/openai.zig |
| Anthropic provider (native Messages API) | DONE | providers/anthropic.zig |
| JSONL session storage | DONE | storage/jsonl.zig |
| Embedded tool descriptions (@embedFile .md) | DONE | prompt/tools/*.md |
| Vtable interfaces (Tool, Provider, Storage, HttpClient) | DONE | NullClaw pattern |
| ToolResult (success/output/error_msg) | DONE | NullClaw pattern |
| Token usage tracking | DONE | TokenUsage struct in ChatResponse |
| Path resolution (~/relative/absolute) | DONE | path.zig |

### Remaining — implementation order

#### 1. Context files (AGENTS.md loading)
- **Effort:** Low
- **Impact:** High — this is how project-specific instructions work
- **What:** Walk directory tree from cwd upward, load AGENTS.md (or CLAUDE.md) at each level. Concatenate into system prompt. Also load global `~/.kaisha/AGENTS.md`.
- **Pi-mono behavior:** Global `~/.pi/agent/AGENTS.md` + walk up from cwd collecting project AGENTS.md files. Also supports SYSTEM.md (full replacement) and APPEND_SYSTEM.md (append to default).
- **Files:** New `src/context.zig`

#### 2. Extension system (registerTool + events)
- **Effort:** High
- **Impact:** Defines the product — without this, agent-core is a closed tool set
- **What:** Allow registering custom tools, commands, and event listeners at runtime. Event types: tool_call, tool_result, message_start/end, turn_start/end, agent_start/end.
- **Pi-mono behavior:** Extensions are TypeScript modules exporting `(pi: ExtensionAPI) => void`. They call `pi.registerTool()`, `pi.registerCommand()`, `pi.on("event", handler)`. Loaded from `~/.pi/agent/extensions/` and `.pi/extensions/`.
- **Zig approach:** Extensions are Zig modules loaded at compile time (via build.zig imports) or dynamic tools registered at runtime via the Tool vtable. Events emitted as a union(enum) — consumers poll or use callbacks.
- **Files:** New `src/events.zig`, extend `tool.zig` ToolRegistry, new `src/extension.zig`

#### 3. Session tree (fork/branch/navigate)
- **Effort:** Medium
- **Impact:** Needed for real use — enables conversation branching and exploration
- **What:** Implement pi-mono's id/parentId tree structure in JSONL. Support fork (copy to new file), branch (multiple children of same parent), tree traversal (leaf-to-root for context building).
- **Pi-mono behavior:** Every entry has 8-char hex id + parentId. Multiple entries sharing parentId = branches. `/tree` navigates visually. `/fork` creates new session file. Tree lives in single JSONL file.
- **Files:** Extend `src/session.zig` with tree logic

#### 4. Compaction (context summarization)
- **Effort:** Medium
- **Impact:** Required for long sessions — without it, token limit hit = session dead
- **What:** When approaching token limit, summarize older messages into a CompactionEntry. Keep recent messages + summary. Manual `/compact` and auto-trigger.
- **Pi-mono behavior:** CompactionEntry stores summary + firstKeptEntryId + tokensBefore. Original JSONL preserved for /tree. Only affects what model sees. Customizable via extension hooks.
- **Files:** New `src/compaction.zig`, extend loop.zig

#### 5. Skills (on-demand prompt templates)
- **Effort:** Medium
- **Impact:** Big UX improvement — reusable task recipes
- **What:** Markdown files with usage instructions. Invoked via `/skill:name` or auto-detected by the model. Located in `~/.kaisha/skills/`, `.kaisha/skills/`.
- **Pi-mono behavior:** Follows agentskills.io standard. Skill = SKILL.md + optional scripts. Loaded from multiple paths. Model can invoke them.
- **Files:** New `src/skills.zig`

#### 6. Prompt templates (`/name` expansion with `{{vars}}`)
- **Effort:** Low
- **Impact:** Nice-to-have — shortcuts for common prompts
- **What:** Markdown files in `~/.kaisha/prompts/`, `.kaisha/prompts/`. Type `/name` to expand. Support `{{variable}}` substitution.
- **Pi-mono behavior:** Simple .md files, `/name` triggers expansion, `{{var}}` prompts user for input.
- **Files:** New `src/templates.zig`

#### 7. Steering + follow-up messages
- **Effort:** Small
- **Impact:** Enables mid-turn control (inject messages while agent is working)
- **What:** Two message queues: steering (delivered after current tool calls finish) and follow-up (delivered when agent would otherwise stop). Pi-mono calls these steer() and followUp().
- **Files:** Extend `src/loop.zig` AgentLoop

#### 8. Model switching mid-session
- **Effort:** Small
- **Impact:** Flexibility — switch between fast/powerful models within same conversation
- **What:** Change provider/model during session. Record as ModelChangeEntry in session JSONL.
- **Files:** Extend AgentLoop + SessionManager

#### 9. Settings (global + project config)
- **Effort:** Medium
- **Impact:** Needed for configurability — thinking level, model defaults, extensions
- **What:** Two-tier JSON config: `~/.kaisha/settings.json` (global) + `.kaisha/settings.json` (project, overrides global). Keys: model, thinkingLevel, extensions[], tools, theme, etc.
- **Pi-mono behavior:** Full 2-tier system. Project overrides global. Accessed via pi.settings.
- **Files:** New `src/settings.zig`

#### 10. Tool result dual output (LLM content + UI details)
- **Effort:** Small
- **Impact:** Cleaner UI — tools return structured data for rendering separately from LLM text
- **What:** ToolResult gets a `details` field (opaque bytes) alongside `output` (for LLM). UI layer reads details for rich rendering without parsing tool output text.
- **Pi-mono behavior:** AgentToolResult has `content: (TextContent | ImageContent)[]` + `details: T`.
- **Files:** Extend `src/tool.zig` ToolResult

---

---

## Pi-mono parity gaps — built but not wired

These modules exist in agent-core but are NOT used by kaisha:

| Module | What it does | What's missing |
|--------|-------------|----------------|
| skills.zig | Load skills from .kaisha/skills/ | Never called. Agent unaware of skills. |
| templates.zig | Load prompt templates, /name expansion | Never called. No /command in UI. |
| compaction.zig | Summarize old messages at token limit | Never called. Long sessions die. |
| settings.zig | Load model/provider/config from JSON | Never called. Everything hardcoded. |
| session.zig | Session tree, fork, branch, navigate | Only basic JSONL used. Tree features unwired. |
| steering | AgentLoop.steer() discards tool calls | UI blocks all input while agent is busy. |
| follow-up | AgentLoop.followUp() | UI never calls it. |

### Fix priorities (implement in this order):

#### P1. Allow typing while agent is busy + steering
- Remove `!self.is_busy` from input gate in chat.zig
- When busy: Send becomes "Steer", calls client.sendSteer()
- Agent receives steering, discards pending tool calls, re-asks LLM
- This is the most impactful missing feature

#### P2. Load settings from JSON
- Call Settings.load(allocator, cwd) at startup
- Use for model, provider, base_url, api_key env var name
- Remove hardcoded model IDs and URLs from chat.zig and server_main.zig
- Settings file: ~/.kaisha/settings.json + .kaisha/settings.json (project overrides)

#### P3. Auto-compaction
- Before each LLM call in loop.zig, check compaction.shouldCompact(messages)
- If true, run compaction.compact() — summarize old messages, keep recent
- Prevents token limit death on long sessions
- Critical for real usage

#### P4. Load skills at startup
- Call skills.loadSkills(allocator, cwd) in loop.zig init
- Append skill names + descriptions to system prompt
- Agent can reference skills: "Use the code-review skill for this"
- Skills loaded from ~/.kaisha/skills/ and .kaisha/skills/

#### P5. Template expansion (/commands)
- In sendMessage, check if input starts with /
- Look up template by name, expand {{variables}}, send expanded text
- Templates from ~/.kaisha/prompts/ and .kaisha/prompts/

#### P6. Session management UI
- New session, switch session, fork from current point
- Session list panel
- Requires UI work (new screen or panel)

---

## Upcoming — next implementation tasks (prioritized)

#### 11. Remote execution — Transport interface (NEXT)
- **Effort:** Medium
- **Impact:** Critical — foundation for remote agent, autonomous employee, sandboxed execution
- **What:** Define Transport vtable (pushEvent, pollCommand, waitPermission, requestPermission). Create LocalTransport wrapping existing EventQueue + PermissionGate. Refactor AgentLoop to use Transport. Zero behavior change.
- **Reference:** research/remote-execution-plan.md
- **Files:** agent-core/src/transport.zig, refactor loop.zig

#### 12. Remote execution — WebSocket server + kaisha-server binary
- **Effort:** High
- **Impact:** Unlocks remote agent — agent runs on server while UI stays on laptop
- **What:** WebSocketTransport implementing Transport vtable. JSON event/command protocol. New server_main.zig entry point (headless, no raylib). Cross-compile to x86_64-linux.
- **Reference:** research/remote-execution-plan.md
- **Files:** agent-core/src/transports/websocket.zig, src/server_main.zig, build.zig

#### 13. Remote execution — Client connection + reconnect
- **Effort:** Medium
- **Impact:** Completes the remote story — UI connects to remote agent
- **What:** WebSocket client in sukue/kaisha. ChatScreen connects to remote or local based on config. State sync on reconnect (server sends full state dump, client rebuilds).
- **Reference:** research/remote-execution-plan.md

#### 14. LSP integration (lsp-client/ package)
- **Effort:** High
- **Impact:** Code intelligence — go-to-definition, references, hover, diagnostics
- **What:** Standalone lsp-client package. JSON-RPC over stdin/stdout to language servers.
- **Reference:** Crush (charmbracelet/crush) LSP integration
- **Files:** New `packages/lsp-client/` package

#### 15. sukue Context abstraction
- **Effort:** Medium
- **Impact:** Completes raylib encapsulation — kaisha never touches raylib directly
- **What:** Context struct wrapping raylib calls. App struct. sukue types. Remove sukue.c re-export.
- **Reference:** research/ui-package-plan.md

#### 16. gitagent Zig implementation
- **Effort:** Medium-High
- **Impact:** Community contribution — first Zig implementation of gitagent.sh standard
- **What:** Parse agent.yaml, SOUL.md, RULES.md, skills/. Validate, export. CLI + library.
- **Reference:** research/gitagent-analysis.md

#### 17. Sandboxing
- **Effort:** Medium
- **Impact:** Security — safe tool execution
- **What:** Linux Landlock (~200 lines), Docker fallback
- **Files:** agent-core/src/sandbox.zig

#### 18. sukue layout + focus system
- **Effort:** Medium
- **Impact:** Required for multi-screen apps and keyboard navigation
- **What:** Vertical/horizontal stack layout, tab focus, active component tracking

#### 19. sukue text selection
- **Effort:** Medium (200-300 lines)
- **Impact:** UX — proper click-drag text selection + copy in chat bubbles
- **What:** Track mouse down/drag/up, compute character positions from font metrics, highlight selection rect, copy to clipboard. Currently click-to-copy-whole-message as stopgap.
- **Files:** sukue/src/components/text_selection.zig

#### 20. Autonomous employee features
- **Effort:** High
- **Impact:** Long-term vision — agent that works like an employee
- **What:** Channel integrations (Slack/Discord), computer-use (screen capture), meeting attendance, VM execution. Builds on remote execution (items 11-13).

---

## Completed phases

### Phase 1: Extraction (DONE)
- Created packages/agent-core/ with build.zig + build.zig.zon
- Moved message.zig, tools/, prompt/ from kaisha monolith
- Defined vtable interfaces (NullClaw pattern)
- Split lyzr.zig → AgentLoop + OpenAI provider
- Created CurlHttpClient in kaisha (injected)
- Deleted old src/core/
- All tests pass, app compiles and runs

### Phase 2: Pi-mono parity (DONE)
- Anthropic provider, session tree, compaction, skills, templates, settings
- Context files (AGENTS.md loading)
- Events (EventBus + EventQueue)
- Steering/follow-up messages (steering discards pending tool calls)
- Model switching mid-session

### Phase 3: Non-blocking UI + permissions (DONE)
- Agent runs on background thread, UI stays responsive
- EventQueue bridges agent→UI thread
- Tool feed with live status, diff rendering, full output display
- Permission system: inline Allow/Always/Deny in tool feed
- Scroll ownership (no cascading between components)

### Phase 4: sukue extraction (DONE)
- Extracted UI components to packages/sukue/
- sukue owns raylib/raygui/md4c
- kaisha imports through sukue, transitional sukue.c re-export
- build.zig: sukue links raylib, kaisha only links curl
