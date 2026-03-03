Edit a file by finding a specific piece of text and replacing it with new text. Targeted and precise — only the matched text changes, everything else stays exactly as it is.

WHEN TO USE THIS TOOL:
- Fixing a typo or incorrect value in a document
- Updating a date, name, price, or any specific detail
- Correcting a line in a config file
- Renaming something throughout a document
- Any change where you know exactly what text needs to change

DO NOT USE THIS TOOL FOR:
- Making a completely new file → use Write
- Completely rewriting a file → use Write
- Changes where you don't know the current exact text → Read the file first

PARAMETERS:
- file_path (required): Absolute path to the file to edit. Can use ~ for home directory.
- old_string (required): The EXACT text currently in the file that you want to replace. It must match character-for-character including spaces, punctuation, and line breaks.
- new_string (required): The text to put in its place.
- replace_all (optional): If true, replaces every occurrence of old_string in the file. Default: false (only replaces the first occurrence, and fails if there are multiple).

CRITICAL RULES:
- ALWAYS read the file before editing — you need to see the exact current text
- old_string must be unique in the file (appear exactly once) unless you use replace_all: true. If it appears multiple times and replace_all is false, the edit will fail.
- If old_string is too short and appears multiple times, include more surrounding context (the full sentence or paragraph) to make it unique
- Preserve the exact indentation and whitespace from the original file — don't add or remove spaces
- The edit will FAIL if old_string is not found. If this happens: read the file again, copy the exact text, and try again.

EXAMPLES:

User: "Change the deadline in my brief from March 15 to April 1"
→ First: read the file to find the exact text
→ edit: file_path="~/Documents/brief.md", old_string="Deadline: March 15, 2025", new_string="Deadline: April 1, 2025"

User: "Fix the typo 'recieve' → 'receive' in my email draft"
→ edit: file_path="~/Documents/email-draft.md", old_string="recieve", new_string="receive"
→ (if it appears multiple times, add replace_all: true)

User: "Update the price from $499 to $599 everywhere in the proposal"
→ edit: file_path="~/Documents/proposal.md", old_string="$499", new_string="$599", replace_all: true

User: "Rename 'Project Alpha' to 'Project Horizon' throughout the document"
→ edit: file_path="~/Documents/roadmap.md", old_string="Project Alpha", new_string="Project Horizon", replace_all: true

WHEN THE EDIT FAILS:
- "old_string not found" → Read the file again. The text may have been different than expected — copy it exactly.
- "old_string not unique" → Add more surrounding context to old_string, or use replace_all: true if you want every occurrence changed.