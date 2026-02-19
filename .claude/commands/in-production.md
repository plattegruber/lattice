# In Production

Check what is currently deployed and running in production.

## Instructions

You are checking the live Lattice production deployment. Perform these steps:

1. **Health check** — Fetch `https://lattice-broken-forest-2932.fly.dev/health` using `curl -sf`. Report the status, timestamp, and instance identity.

2. **Debug overview** — Fetch `https://lattice-broken-forest-2932.fly.dev/debug` using `curl -sf`. This returns system metrics, fleet state, intent stats, and PR tracking info. Report:
   - System: Elixir/OTP versions, uptime, memory usage, process count
   - Fleet: total sprites, counts by state
   - Intents: total count, breakdown by state and kind, 5 most recent
   - PRs: open count, merged count, details of any open PRs

3. **Fly.io machines** — Use the Fly.io MCP tools (`fly-machine-list` with app `lattice-broken-forest-2932`) to show machine IDs, regions, states, and VM sizes.

4. **Recent logs** — Use the Fly.io MCP tool (`fly-logs` with app `lattice-broken-forest-2932`) to fetch recent application logs. Highlight any errors or warnings.

5. **Summary** — Present a concise production status report with:
   - Overall health (healthy/degraded/down)
   - Key metrics (uptime, memory, sprites, intents)
   - Any issues or anomalies detected
   - Recent activity

Format the output as a clean, readable report. Flag anything that looks abnormal.
