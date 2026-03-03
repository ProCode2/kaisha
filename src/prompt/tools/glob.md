Find files and folders by name pattern. Searches a directory tree and returns all paths that match the pattern. Use this to locate files when you don't know exactly where they are, or to list the contents of a folder.

WHEN TO USE THIS TOOL:
- Finding a file when you don't know its exact location
- Listing all files of a certain type (all PDFs, all CSVs, etc.)
- Exploring what's inside a folder
- Discovering the structure of a project or directory
- Finding files whose names match a keyword

DO NOT USE THIS TOOL FOR:
- Searching INSIDE files for text → use Bash with grep for that
- Reading a file's contents → use Read

PARAMETERS:
- pattern (required): The glob pattern to match filenames against. See patterns below.
- path (optional): The directory to search in. Use absolute paths like /Users/pradipta/Documents or ~ for the home directory. Defaults to the current working directory.

GLOB PATTERN GUIDE:
- * → match anything within a single folder level (no /)
- ** → match any number of folder levels (crosses into subfolders)
- ? → match exactly one character
- [abc] → match any one of: a, b, or c
- [a-z] → match any character in range a through z

COMMON PATTERNS:
- * → everything in the top level of the folder
- **/* → everything recursively (all files, all subfolders)
- *.pdf → all PDFs in the top level of the folder
- **/*.pdf → all PDFs anywhere in the folder tree
- report* → files/folders starting with "report"
- *budget* → files/folders with "budget" anywhere in the name
- **/*2024* → anything with "2024" in the name, anywhere
- src/**/*.zig → all .zig files anywhere under the src/ folder

DISCOVERY STRATEGY:
When you don't know where something is, search broadly and then narrow down:
1. Start: pattern=* path=~ (see what's in the home directory)
2. Narrow: pattern=* path=~/Documents (see top-level Documents contents)
3. Specific: pattern=**/*expense* path=~/Documents (find expense files)

IMPORTANT RULES:
- Always use absolute paths for the path parameter. Use ~ for home directory (e.g. ~/Documents), not relative paths like Documents or ../projects.
- If you're not sure of the path, start from ~ and explore downward
- If Glob returns "No files matched" and you expected results, check that the path exists first using Bash: ls ~/expected/path

EXAMPLES:

User: "Find my expense report from last year"
→ glob: pattern="**/*expense*2024*", path="~"
→ Show the user the matching files

User: "What's in my Documents folder?"
→ glob: pattern="*", path="~/Documents"
→ Show the top-level contents

User: "Find all the PDFs in my Downloads"
→ glob: pattern="*.pdf", path="~/Downloads"

User: "I have a project called architect-db somewhere, where is it?"
→ glob: pattern="**/architect-db", path="~"
→ If nothing found, try: bash: find ~ -name "architect-db" -type d 2>/dev/null

User: "Show me all the spreadsheets I have"
→ glob: pattern="**/*.xlsx", path="~" (and also **/*.csv in parallel)

User: "List all the source files in my project"
→ glob: pattern="src/**/*", path="~/projects/myproject"