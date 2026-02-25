# Lattice Daily Improvement Loop (DIL)

## Purpose

Introduce a **controlled, high-confidence, low-drama proactive improvement system** for Lattice.

Once per day, Lattice may open **at most one GitHub issue** proposing a small-to-medium improvement that:

- Advances the North Star
- Is grounded in evidence
- Is high confidence
- Is incremental (not architectural upheaval)
- Has clear implementation scope
- Has already been researched before being proposed

This is not brainstorming.
This is not speculative architecture.
This is disciplined, compounding improvement.

---

## Design Principles

### 1. High Confidence Only

Proposals must be:

- Backed by repository evidence
- Backed by runtime/log evidence OR measurable friction
- Backed by external research where relevant
- Clearly scoped
- Low-risk

No moonshots.
No sweeping rewrites.
No vague "we should rethink X".

If unsure → do nothing.

---

### 2. Research Before Proposal

Every proposal must include:

- Internal repo scan
- Open issues scan
- Closed issues scan
- Related discussions scan
- External research (if relevant)
- Tradeoff summary

Lattice does not propose unresearched ideas.

---

### 3. Non-Disruptive Cadence

- Run once per day
- Skip if:
  - A previous DIL issue is still open
  - The repo has been inactive for >7 days
  - The last proposal was rejected within 48 hours

This prevents spam and oscillation.

---

### 4. GitHub as HITL

All output is a normal GitHub issue.

No side channels.
No Slack.
No hidden memory.

GitHub is the Human-in-the-Loop substrate.

---

## System Architecture

### New Component: Improvement Evaluator

A daily-scheduled Lattice job:

```python
lattice.scheduler.daily_improvement()
```

Executed via Fly cron or Oban periodic job.

---

## High-Level Flow

1. Check safety gates
2. Gather context
3. Identify candidate improvements
4. Score candidates
5. Select top high-confidence candidate
6. Research deeply
7. If still high confidence → open issue
8. Log reasoning internally

---

## Step 1 — Safety Gates

Abort if:

- An open issue exists labeled: `dil-proposal`
- Last DIL issue < 24h ago
- Repo activity < threshold (configurable)
- Current branch unstable / failing CI

Conservative by default.

---

## Step 2 — Context Gathering

### Internal Signals

- Repo tree structure
- Logging patterns
- TODOs
- Large files
- High cyclomatic complexity areas
- Functions with excessive arguments
- Sprite execution logs
- Failure rates
- Context truncation events
- Retry counts
- Memory fetch latency
- PR rejection reasons
- Oversized prompts

### GitHub Signals

- Recently closed issues
- Recently rejected PRs
- Comment friction
- Repeated reviewer comments
- Patterns like:
  - "we should log this"
  - "this feels brittle"
  - "context is missing"

### North Star Mapping

Load the North Star document and extract:

- Core goals
- Architectural boundaries
- Explicit priorities

Improvements must tie directly to one of these.

---

## Step 3 — Candidate Identification

Allowed categories (v1):

### Category A — Observability

- Missing structured logs
- No correlation ID propagation
- No tracing in critical paths
- Lack of sprite lifecycle visibility

### Category B — Context Efficiency

- Repeated context rehydration
- Oversized prompts
- Missing context caching
- Known context truncation patterns

### Category C — Reliability

- Retry logic inconsistent
- Missing backoff
- No idempotency guard
- Sprite timeout misalignment

### Category D — Developer Ergonomics

- Missing docs in core modules
- Confusing naming
- Lack of inline examples
- Missing test coverage in critical paths

Explicitly excluded (v1):

- Major refactors
- Product expansion
- New feature domains
- New communication channels
- Multi-tenancy
- Marketing ideas

---

## Step 4 — Candidate Scoring

Each candidate is scored 0–5 on:

| Dimension | Description |
|----------|-------------|
| North Star Alignment | Directly improves stated goals |
| Evidence Strength | Clear repo/log evidence |
| Scope Clarity | Small/medium and well-bounded |
| Risk Level | Low breakage risk |
| Implementation Confidence | Clear solution path |

Minimum threshold: **18 / 25**

If no candidate qualifies → no issue opened.

---

## Step 5 — Deep Research Phase

For the selected candidate:

1. Scan entire repo for related code
2. Check for prior attempts
3. Review closed issues
4. Perform external research if relevant
5. Compare at least two approaches
6. Document tradeoffs
7. Confirm minimalism

If confidence drops → abort.

---

## Step 6 — Issue Format

### Title

```text
[DIL] Improve <specific subsystem> via <specific change>
```

### Labels

- `dil-proposal`
- `research-backed`

---

### Issue Body Template

```markdown
#### 1. Summary

Clear, concrete statement of improvement.

---

#### 2. Why This Matters

Explicit mapping to North Star.

---

#### 3. Evidence

Concrete evidence:

- File references
- Log patterns
- PR comments
- Failure metrics
- Context truncation indicators

---

#### 4. Proposed Change

Specific implementation:

- Files to modify
- Behavior to add
- Minimal scope

---

#### 5. Alternatives Considered

At least one.

---

#### 6. Risks

Honest assessment.

---

#### 7. Effort Estimate

- XS (≤ 1 hr)
- S (≤ 1 day)
- M (≤ 3 days)

---

#### 8. Confidence Level

Explicit:

> Confidence: High (based on X, Y, Z)
```

---

## Anti-Patterns (Hard Constraints)

The DIL system must NOT:

- Propose vision pivots
- Suggest renaming the product
- Re-architect core systems
- Expand scope
- Suggest unrelated tools
- Generate speculative features
- Post more than once per day
- Argue with users in comments

This is disciplined compounding improvement only.

---

## Version 1 Limitations

- Single proposal per day
- Single repo only
- No multi-repo awareness
- No cross-org analysis
- No auto-PR creation
- No auto-implementation

Deliberate constraints.

---

## Implementation Plan

### Phase 1 — Manual Evaluation Mode

- Run evaluator in dry-run
- Print proposed issue to logs
- Review manually
- Tune scoring heuristics

Minimum 7 days.

---

### Phase 2 — Controlled Automation

Enable auto-issue creation with:

- One open DIL issue max
- No self-closing
- No self-merging
- No silent iteration

---

## Philosophy

Lattice should not "have ideas."

It should:

1. Observe
2. Measure
3. Identify friction
4. Research
5. Propose minimal fixes
6. Compound

No drama.
No ego.
Just steady improvement.

---

## Future (Not v1)

- Impact measurement
- Learning from accepted vs rejected proposals
- ROI ranking
- Auto-PR for XS changes
- Cross-repo insight
- Multi-tenant improvements

Not now.

---

End of spec.
