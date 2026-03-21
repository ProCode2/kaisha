# Memory + Session Plan

## Philosophy

No session picker. No memory management UI. No special history tool. The agent self-manages its memory using its existing tools — read, write, edit, bash, glob (Letta/MemGPT pattern). Memory is just files. The user opens the box and everything is already there.

## Directory convention

```
.kaisha/
├── memory/                 # Persistent agent memory (agent reads/writes these)
│   ├── context.md          # Project context, architecture, key facts
│   ├── decisions.md        # Important decisions made and why
│   ├── preferences.md      # User preferences learned over time
│   └── [agent creates more as needed]
├── history/                # Conversation logs (auto-managed)
│   ├── 2026-03-20.jsonl    # One file per day
│   ├── 2026-03-21.jsonl
│   └── ...
├── last_conversation       # Date of most recent conversation
├── settings.json
├── skills/
├── prompts/
└── secrets/
```

## How it works

### On startup

1. Read `.kaisha/last_conversation` → load that day's JSONL → resume
2. Load all `.kaisha/memory/*.md` → inject into system prompt
3. Agent has full prior knowledge without loading ALL history

### During conversation

- Messages auto-append to today's JSONL (`history/YYYY-MM-DD.jsonl`)
- Agent reads/writes memory files using existing tools
- Auto-compaction when context is too large (already built)

### When agent needs old context

The agent uses its existing tools — no special history tool needed:

```bash
# Search conversation history
bash: grep -r "docker deployment" .kaisha/history/ --include="*.jsonl" -l

# Read a specific day's conversation
read: .kaisha/history/2026-03-20.jsonl

# Find recent conversations
bash: ls -lt .kaisha/history/ | head -10

# Search memory files
bash: grep -r "API key" .kaisha/memory/
```

The system prompt teaches the agent these patterns.

### Memory self-management

The system prompt tells the agent:

```
Your persistent memory is in .kaisha/memory/. Read it at the start of
complex tasks. Update it when you make important decisions, learn
preferences, or discover project conventions. You manage your own
memory. Conversation history is in .kaisha/history/ as daily JSONL
files — search with grep, read with read tool.
```

The agent decides what to remember. No extraction pipeline. No special API.

## Implementation

### Step 1: History manager (agent-core)

New module `history.zig` implementing the `Storage` vtable:
- `appendToday(message)` — appends to `.kaisha/history/YYYY-MM-DD.jsonl`
- `loadLatest(allocator)` — reads the most recent conversation (from `last_conversation` file)
- Replaces `JsonlStorage` — same interface, new organization

### Step 2: Memory loading in system prompt

In `loop.zig` init, load `.kaisha/memory/*.md` files and append to system prompt. Similar to existing `context.zig` logic — walk directory, read markdown, concatenate.

### Step 3: Wire into kaisha

Replace `JsonlStorage` with history manager in `chat.zig` and `server_main.zig`. On startup: auto-resume. On each message: write `last_conversation`.

### Step 4: Update system prompt

Add section teaching the agent about:
- `.kaisha/memory/` — what it is, how to read/write/update
- `.kaisha/history/` — how to grep/search past conversations
- When to update memory (decisions, preferences, conventions, errors)

### What we don't build

- Dedicated history tool (agent uses bash grep + read)
- Vector search / embeddings (grep is enough)
- Session picker UI (auto-resume)
- Memory management UI (agent self-manages)
- Memory extraction pipeline (agent does it itself via write tool)
