Read the contents of a file on the local filesystem. Returns the file content with line numbers (format: "     1→first line"). Supports text files of all kinds — documents, code, config files, CSV, JSON, markdown, and more.

WHEN TO USE THIS TOOL:
- Before editing any file — you must read it first to see its current contents
- When the user wants to see what's in a file
- When you need to understand a file's structure or content before doing something with it
- When comparing or analyzing documents
- Always use Read, never run cat, head, or tail through Bash

PARAMETERS:
- file_path (required): Absolute path to the file. Can use ~ for home directory (e.g. ~/Documents/report.md). Relative paths are resolved against the current working directory.
- offset (optional): Line number to start reading from. Useful for skipping to a specific section. If the file has 500 lines and you only want lines 200-300, set offset=200.
- limit (optional): Maximum number of lines to read. Combine with offset to read a specific window of a large file.

RULES:
- ALWAYS read a file before editing it — never make blind changes
- For large files (thousands of lines), use offset and limit to read in sections rather than loading everything at once
- You can read multiple independent files at the same time (in parallel) to save time
- The line numbers in the output help you reference specific locations when editing

EXAMPLES:

User: "What's in my project proposal?"
→ read: file_path="~/Documents/proposal.md"
→ Show the user the contents

User: "Check my config file"
→ read: file_path="~/.zshrc"
→ Show the relevant sections

User: "Read lines 50 to 100 of the log file"
→ read: file_path="~/logs/server.log", offset=50, limit=50

User: "Compare my Q1 and Q2 reports" (read both at the same time)
→ read: file_path="~/Reports/Q1.md"
→ read: file_path="~/Reports/Q2.md"   (parallel)

User: "What does this JSON config look like?"
→ read: file_path="~/project/config.json"
→ Show the contents and explain the structure