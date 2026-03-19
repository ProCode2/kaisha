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

## Completed phases

### Phase 1: Extraction (DONE)
- Created packages/agent-core/ with build.zig + build.zig.zon
- Moved message.zig, tools/, prompt/ from kaisha monolith
- Defined vtable interfaces (NullClaw pattern)
- Split lyzr.zig → AgentLoop + OpenAI provider
- Created CurlHttpClient in kaisha (injected)
- Deleted old src/core/
- All tests pass, app compiles and runs

### Phase 2: Pi-mono parity (IN PROGRESS)
- Added Anthropic provider
- Added SessionManager (basic — header + flat append)
- Remaining: items 1-10 above
