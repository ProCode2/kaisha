List and check available secrets. You can see secret names and descriptions but NEVER the actual values.

WHEN TO USE THIS TOOL:
- Before using any secret in a command — verify it exists first
- When you need to know what credentials are available for a task
- When the user asks about configured secrets or authentication

PARAMETERS:
- action (required): "list" to show all secrets, "check" to verify one exists
- name (optional): Secret name to check (required when action is "check")

HOW SECRETS WORK:
Secrets are referenced using the <<SECRET:NAME>> syntax in your tool calls. The proxy automatically substitutes the real value before execution and masks it in output.

Example: if GITHUB_TOKEN is available, you write:
  git clone https://<<SECRET:GITHUB_TOKEN>>@github.com/org/repo.git

The proxy handles:
1. BEFORE execution: replaces <<SECRET:GITHUB_TOKEN>> with the real token
2. Command runs with the real value
3. AFTER execution: any occurrence of the real token in output is replaced back with <<SECRET:GITHUB_TOKEN>>

So if the output contains <<SECRET:GITHUB_TOKEN>>, it means the real value WAS used successfully — the output is masked for security. This is expected, NOT an error.

IMPORTANT RULES:
- ALWAYS check what secrets are available before trying to use them
- Use the exact <<SECRET:NAME>> syntax — the proxy only recognizes this pattern
- If you see <<SECRET:NAME>> in command output, the secret was used correctly — do NOT report it as a failure
- NEVER try to read, echo, print, or extract the actual secret value
- NEVER store secret values in files — use <<SECRET:NAME>> references instead
- If a command fails with authentication errors, check that the secret name is correct and the secret is available

EXAMPLES:

List all available secrets:
  {"action": "list"}
  → Available secrets (2):
    <<SECRET:GITHUB_TOKEN>> — GitHub personal access token
    <<SECRET:AWS_ACCESS_KEY>> — AWS deploy credentials

Check if a specific secret exists:
  {"action": "check", "name": "GITHUB_TOKEN"}
  → GITHUB_TOKEN: available — GitHub personal access token

Check a secret that doesn't exist:
  {"action": "check", "name": "STRIPE_KEY"}
  → STRIPE_KEY: not available

Using secrets in other tools:
  bash: git clone https://<<SECRET:GITHUB_TOKEN>>@github.com/org/repo.git
  bash: curl -H "Authorization: Bearer <<SECRET:API_KEY>>" https://api.example.com
  bash: docker login -u user -p <<SECRET:DOCKER_PASSWORD>> registry.example.com
  edit: replace "old_api_key" with "<<SECRET:NEW_API_KEY>>" in config.yaml
