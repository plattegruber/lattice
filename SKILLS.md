# Recommended Claude Code Skills & Plugins

Plugins and MCP servers to install for working on Lattice.

## Tier 1 — Install These

### Elixir Plugin (`georgeguimaraes/claude-code-elixir`)

Purpose-built Elixir development plugin with thinking skills for Elixir, Phoenix, Ecto, and OTP patterns. Includes auto-format and credo hooks.

```bash
claude plugin marketplace add georgeguimaraes/claude-code-elixir
```

Includes:
- `elixir-thinking` — core language patterns
- `phoenix-thinking` — Phoenix/LiveView patterns
- `otp-thinking` — GenServer, Supervisor, concurrency patterns
- Auto-hooks: `mix format` on save, `mix compile --warnings-as-errors`, `mix credo`

### Fly.io MCP Server

Already configured in `.mcp.json`. Requires `flyctl` installed and authenticated.

Gives Claude direct access to manage Fly apps, machines, logs, certs, and orgs.

```bash
flyctl auth login  # One-time setup
```

### Claude Code GitHub Action

Enables `@claude` mentions in PRs for automated code review.

```bash
# Inside Claude Code:
/install-github-app
```

Or configure manually — see [anthropics/claude-code-action](https://github.com/anthropics/claude-code-action).

## Tier 2 — Install When Needed

### Code Review Plugin

Language-agnostic code review workflows from Anthropic's official plugin directory.

```bash
claude plugin install code-review@claude-plugin-directory
```

### PR Review Toolkit

Multi-agent PR review with confidence scoring.

```bash
claude plugin install pr-review-toolkit@claude-plugin-directory
```

### GitHub MCP Server (optional, not preconfigured)

Structured access to repos, PRs, issues, Actions, and code search. Richer than the `gh` CLI for some workflows. Not included in `.mcp.json` by default — add manually if needed:

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github@latest"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "<your-token>"
      }
    }
  }
}
```

## Tier 3 — Nice to Have

| Plugin | Use Case |
|--------|----------|
| `elixir-architect` (`maxim-ist/elixir-architect`) | Architecture docs and ADR generation |
| `commit-commands` | Structured commit workflows |
| `feature-dev` | Feature development workflow |
| `playwright` | Browser-based LiveView E2E testing |
