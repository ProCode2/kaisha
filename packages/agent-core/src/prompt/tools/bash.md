Execute a shell command and return its output (stdout + stderr combined). Use this to run programs, scripts, system commands, and anything that requires the terminal. The working directory persists between calls — if you cd somewhere, subsequent commands run from there.

WHEN TO USE THIS TOOL:
- Moving, copying, or renaming files (cp, mv, mkdir, rm)
- Checking system status: disk space (df -h), memory (free -h), running processes (ps), current time (date)
- Running scripts or programs: python script.py, node server.js, ./build.sh
- Package management: brew install, npm install, pip install -r requirements.txt
- Git operations: git status, git add, git commit, git push, git log
- Data processing: sort, uniq, wc, jq, csvtool, awk (when editing a file isn't the right approach)
- File format conversion: pandoc, ffmpeg, convert (ImageMagick)
- Archiving: zip, tar, unzip
- Network checks: ping, curl (for API calls), wget

DO NOT USE THIS TOOL FOR:
- Reading a file's contents → use the Read tool instead (not cat, head, tail, less)
- Editing part of a file → use the Edit tool instead (not sed, awk, perl -i)
- Creating a new file → use the Write tool instead (not echo >, cat <<EOF, tee)
- Finding files by name → use the Glob tool instead (not find, ls -R)

SAFETY RULES:
- Always quote paths that contain spaces: "/Users/pradipta/My Documents/file.txt"
- Chain dependent commands with &&: mkdir output && cp report.pdf output/
- Before running anything destructive (rm, overwrite, reset --hard, DROP), tell the user what will be deleted or lost and wait for confirmation
- Never run interactive commands that wait for keyboard input — they will hang forever

PARAMETERS:
- command (required): The bash command to execute
- timeout (optional): Maximum milliseconds to wait before killing the command (default: 30 seconds)

EXAMPLES:

User: "How much space do I have left on my computer?"
→ bash: df -h ~

User: "Install the project dependencies"
→ bash: npm install   (or pip install -r requirements.txt, brew install ..., etc.)

User: "Commit these changes with message 'update pricing'"
→ bash: git add -A && git commit -m "update pricing"

User: "How many lines are in each of my CSV files?"
→ bash: wc -l ~/Documents/data/*.csv

User: "Convert this markdown file to PDF"
→ bash: pandoc ~/Documents/report.md -o ~/Documents/report.pdf

User: "What processes are using the most memory?"
→ bash: ps aux --sort=-%mem | head -10