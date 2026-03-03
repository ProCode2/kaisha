Create a new file or completely overwrite an existing one with new content. Use this to generate documents, reports, templates, exports, and any new files from scratch.

WHEN TO USE THIS TOOL:
- Creating a brand new file that doesn't exist yet
- Generating a report or document from scratch
- Exporting processed data to a file
- Creating templates, drafts, or boilerplate files
- When you need to completely replace a file's contents (not just edit part of it)

DO NOT USE THIS TOOL FOR:
- Making small changes to an existing file → use Edit instead (Write replaces EVERYTHING)
- Appending to an existing file → use Bash with >> or Edit

PARAMETERS:
- file_path (required): Absolute path where the file should be created or overwritten. Can use ~ for home directory (e.g. ~/Documents/report.md). Parent directories must already exist.
- content (required): The complete content to write to the file. This replaces everything — what you provide here is exactly what the file will contain.

IMPORTANT RULES:
- If the file already exists, you MUST read it first before overwriting — so you don't accidentally destroy something the user needs
- Prefer Edit for targeted changes to existing files — only use Write when you're replacing the whole thing
- Make sure the parent directory exists (use Glob or Bash to check) before writing
- When writing reports or documents, use the full final content — don't write a placeholder and say "fill in later"

EXAMPLES:

User: "Write me a weekly standup template"
→ write: file_path="~/Documents/standup-template.md", content="[full template content]"
→ Confirm: "Created standup template at ~/Documents/standup-template.md"

User: "Generate a summary report from the data we just analyzed"
→ write: file_path="~/Reports/summary-2025-03.md", content="[complete report]"
→ Confirm where the file was saved

User: "Create a .gitignore for a Node project"
→ write: file_path="~/projects/myapp/.gitignore", content="[full gitignore content]"

User: "Export those results to a CSV file"
→ write: file_path="~/data/results.csv", content="[CSV data with headers]"

User: "Save this draft to a new file called pitch-v2.md"
→ write: file_path="~/Documents/pitch-v2.md", content="[full document]"
→ Tell the user where it was saved