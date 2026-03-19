# GitAgent (gitagent.sh) — Analysis for Kaisha

## What it is

An open standard for defining AI agents as files in a git repo. Not a framework, not a runtime — a **specification** for how to describe an agent so it can be exported to any framework (Claude Code, OpenAI, CrewAI, Lyzr, etc.).

**Repo:** https://github.com/open-gitagent/gitagent
**Website:** https://www.gitagent.sh
**License:** MIT
**Version:** 0.1.0 (early)

## Core idea: Your repo IS the agent

Three required files define the agent:
- `agent.yaml` — manifest (name, version, model, compliance, dependencies)
- `SOUL.md` — personality, communication style, values, decision-making principles
- `RULES.md` — hard constraints, must-always/must-never, safety boundaries

## Full directory structure

```
my-agent/
├── agent.yaml              # Required: manifest
├── SOUL.md                 # Required: identity/personality
├── RULES.md                # Hard constraints & safety
├── DUTIES.md               # Segregation of duties (maker/checker/executor/auditor)
├── AGENTS.md               # Framework-agnostic fallback
├── skills/                 # Reusable capability modules
│   └── {skill-name}/
│       ├── SKILL.md        # Describes capability, inputs, outputs
│       └── {scripts}       # Implementation (shell, Python, etc.)
├── tools/                  # MCP-compatible YAML schemas
├── workflows/              # Multi-step YAML procedures (SkillsFlow)
├── knowledge/              # Reference documents
├── memory/runtime/         # Live state (gitignored)
│   ├── dailylog.md
│   └── context.md
├── hooks/                  # Lifecycle handlers
│   ├── bootstrap.md        # Startup procedures
│   └── teardown.md         # Cleanup on shutdown
├── config/                 # Environment overrides
├── compliance/             # Regulatory artifacts
├── agents/                 # Sub-agent definitions
└── examples/               # Calibration interactions
```

## Export adapters

One agent definition, many runtimes:
- `system-prompt` — concatenated text for any LLM
- `claude-code` — generates CLAUDE.md
- `openai` — OpenAI Agents SDK Python
- `crewai` — CrewAI YAML config
- `lyzr` — Lyzr Studio agent
- `github` — GitHub Actions agent
- `openclaw`, `nanobot` — additional formats

## Workflows (SkillsFlow)

```yaml
name: review-pr
steps:
  fetch:
    tool: github/get-pr
    inputs:
      pr_number: "${{ inputs.pr_number }}"
  analyze:
    skill: code-review
    depends_on: [fetch]
    inputs:
      diff: "${{ steps.fetch.outputs.diff }}"
  comment:
    tool: github/comment
    depends_on: [analyze]
    conditions: ["${{ steps.analyze.outputs.issues_found }}"]
```

## Compliance features

- FINRA (Rule 3110, 4511, 2210), Federal Reserve (SR 11-7, SR 23-4), SEC, CFPB
- DUTIES.md enforces segregation of duties at file level
- `gitagent validate --compliance` catches violations before deployment
- `gitagent audit` generates compliance reports

## CLI

```
gitagent init [--template minimal|standard|full]
gitagent validate [--compliance]
gitagent info
gitagent export --format <claude-code|openai|crewai|lyzr|...>
gitagent import --from <format> <path>
gitagent run <source> --adapter <adapter>
gitagent install       # resolve git dependencies
gitagent audit         # compliance report
gitagent skills <cmd>  # manage skills
```

## Agent composition

```yaml
# agent.yaml
extends: https://github.com/org/base-agent.git
dependencies:
  reviewer:
    source: https://github.com/org/code-reviewer.git
    version: "^1.0.0"
```

Agents can inherit from parents and depend on other agents.

---

## Critical Assessment: Is this useful for Kaisha?

### What's genuinely useful

1. **The file structure convention.** SOUL.md + RULES.md + skills/ is a clean way to organize agent definitions. Kaisha already has `src/prompt/system.md` — this is a more structured version of the same idea.

2. **Skills as directories.** Each skill = SKILL.md + implementation scripts. This maps directly to Kaisha's extension system need. Instead of inventing a custom format, adopt or adapt this convention.

3. **Workflows (SkillsFlow).** The `depends_on` + `${{ steps.X.outputs.Y }}` pattern for multi-step agent workflows is useful for the "autonomous employee" vision. An agent that can run a review pipeline (fetch PR → analyze → comment) needs this kind of orchestration.

4. **Export adapters.** If Kaisha can read gitagent repos, it can run any agent from the registry. This is a network effect play — the registry already has shared agents.

5. **Agent composition.** `extends` + `dependencies` for agent inheritance is genuinely smart for building specialized agents from a base.

### What's NOT useful / concerns

1. **It's a spec, not an implementation.** GitAgent doesn't give you an agent runtime, tools, or an LLM integration. It's a packaging format. Kaisha already has the runtime — the question is whether to adopt the packaging format.

2. **Very early (v0.1.0).** The spec could change significantly. Building deep integration with an unstable spec is risky.

3. **Compliance features are enterprise overkill.** FINRA/SEC/Federal Reserve compliance is irrelevant for Kaisha's use case. That's 30%+ of the spec surface area that adds zero value.

4. **The "export to any framework" promise is weak.** Exporting a SOUL.md to a Claude Code CLAUDE.md or an OpenAI agents SDK config is string concatenation, not real portability. The hard part (tools, runtime, sandboxing) isn't portable.

5. **npm-based CLI.** The gitagent CLI is a Node.js package. Running `npx gitagent run` to launch an agent adds a heavy dependency. Kaisha is a Zig binary — this is philosophically opposite.

6. **Registry is new and small.** The network effect hasn't materialized yet.

### Verdict

**Adopt the conventions, not the dependency.**

- Use SOUL.md / RULES.md / skills/ directory structure as Kaisha's agent definition format
- Don't depend on the gitagent npm package or CLI
- Don't implement full spec compliance (DUTIES.md, SkillsFlow, etc.) unless needed
- Consider writing a Zig-native gitagent reader that can load agent repos — this gives access to the registry without the npm dependency
- The SkillsFlow workflow format is worth studying for Phase 5 (autonomous employee)

### Concrete adoption plan

1. **Now:** Rename `src/prompt/system.md` → adopt SOUL.md convention. Add RULES.md for hard constraints.
2. **Phase 1 (extensions):** Use `skills/{name}/SKILL.md + scripts` as the skill directory format.
3. **Later:** Write a minimal gitagent repo loader in Zig (read agent.yaml + SOUL.md + skills/) so Kaisha can consume agents from the registry.
4. **Skip:** Compliance, DUTIES.md, SkillsFlow, export adapters, npm CLI dependency.
