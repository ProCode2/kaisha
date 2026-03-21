# Pending Issues — DVUI App

## Bugs

1. **Input not clearing after send** — text stays in the input field after sending a message. Need to clear the internal buffer after send.

2. **Emoji rendering as boxes** — fonts don't have emoji glyphs. Noto Emoji monochrome is 2MB (too big). Options:
   - Strip emoji (4-byte UTF-8 sequences) before rendering
   - Find a smaller emoji font (<500KB)
   - Tell LLM not to use emoji via system prompt
   - Current state: `addTextWithEmoji` tries to use Noto Emoji font but the font was removed

3. **Noto Emoji font broken** — GitHub raw download returns HTML, not the TTF. The correct file is at `google/fonts` repo (variable weight, 2MB). Too large to embed.

## UI Issues

4. **Secrets panel** — verify it actually opens after the layout fixes

5. **Tool feed scrollable** — scroll area added to tool_feed container (max 400px height). Needs testing.

6. **Send button position** — fixed by deiniting textEntry before creating button. Needs testing.

7. **Markdown renderer edge cases** — tables render as raw pipes, no grid formatting. Blockquotes added but untested.

## Missing Features (from old UI)

8. **Diff view for edit tool calls** — old tool_feed.zig had diff_view for showing file edits with red/green coloring. Not ported to DVUI.

9. **Template expansion** — `/name` shortcuts expanded to templates. Not ported (low priority, needs cwd from Box interface).

10. **Keyboard shortcuts for permissions** — Y/A/N keys for Allow/Always/Deny. Removed because DVUI event API differs. Need to re-add.

## Technical Debt

11. **`g_local_box_for_secrets_tool` global** — StaticTool has no context parameter. Breaks with multiple simultaneous LocalBoxes. Needs StaticTool vtable refactor.

12. **Memory cleanup on exit** — switched to page_allocator to silence GPA leak reports. Proper cleanup would free: BoxManager.list() results, history messages, websocket buffers, DockerBox instances.

13. **Docker box history loading** — config.name was empty due to freed JSON parse buffer. Fixed with name fallback in loadConfig. Needs verification.

14. **Old UI code (Clay/sukue)** — still exists on main branch. Once DVUI is validated, remove: sukue Clay integration, old chat.zig, old box_list.zig, old tool_feed.zig, Clay dependency.
