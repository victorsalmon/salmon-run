# Skill: Prototype & Build a Skill

**Purpose**: Guide a Cowork agent through building a reusable, modular skill end-to-end — from single-shot prototyping through scalable implementation, with curiosity-driven failure analysis, conservative API usage, and structured recording of what worked and what didn't.

**Owner**: `Cowork` role. Also useful for any agent building new tooling or scripting a novel process.

**Output location**: Skill file to `Skills/<Domain>/<name>.md`; utility scripts to `Skills/<Domain>/Scripts/<script-name>`; usage notes and working patterns recorded in Cowork artifacts.

**Trigger**: User says "Build a Skill", "Prototype", "Let's build a tool for X", or "I want to codify this process."

**Prerequisites**: Write access to `Skills/` and `Tasks/Handoff/` directories. Target API/service credentials available.

---

## Workflow

### Phase 0: Planning Discussion — Align Before Building

Start every prototyping session with a brief collaborative discussion to get clear on the goal before writing any code. This is a conversation, not an interrogation.

1. **Summarize what I understand** about the goal based on the trigger or prior conversation.
2. **Ask what's most important to clarify first** — let the user steer. Topics might include:
   - The core action the skill should perform
   - The data involved (input/output, format, sources)
   - Which external APIs or services it needs to call
   - Known constraints, gotchas, or prior failed attempts
3. **Flag what I can figure out on my own** (codebase search, API docs, existing scripts) vs. what I need the user's input on.
4. **Propose a rough plan or approach**, then invite the user to adjust it.

**Key principle:** This is a lightweight planning discussion — not a full requirements spec. The goal is shared context and direction, not exhaustive coverage. Stop when both you and the user have a clear enough picture to start prototyping. We will discover details as we go.

If the user says "let's just start prototyping" or is clearly eager to begin, keep this phase to 1–2 rounds of clarification and move on.

### Phase 1: Single-Shot Prototype

Test the core loop **once per input type** before running any batch:

1. Pick **one** representative record from each input type/variant.
2. Write the minimal script or command to process that single record.
3. Run it. Watch the output carefully.
4. Ask: *Why did it work? Why did it fail?*

**Rules:**
- Never run more than 1 record per type in the first pass.
- Never ignore a failure and proceed anyway. Stop. Investigate.
- If the API returns an error, read the error body. Don't guess.
- If the API succeeds but the output is wrong, inspect both input and output. Don't move on until you understand the gap.

**Anti-patterns:**
- ❌ Running all 100 records and seeing which fail — burns rate limits, timeouts, and trust.
- ❌ "The error is probably just a typo" — read the error, verify the fix, then retry.
- ❌ Retrying the same failing request 3 times hoping it works — stop and diagnose.
- ❌ "Let's add a try/catch and skip failures" — you skipped learning why it failed. Fix first, then handle edge cases intentionally.

### Phase 2: Iterate — Why, Not Just What

After each single-shot test, ask:

| Question | Purpose |
|----------|---------|
| Did the API behave as documented? | Catches doc-vs-reality gaps |
| Did the input format matter? | Catches type-specific bugs |
| Was auth configured correctly? | Catches credential issues early |
| Was there a parsing assumption that was wrong? | Catches brittle logic |
| How long did the call take? | Calibrates timeout/retry settings |
| What would break if we added pagination? | Anticipates scale issues |

Fix each issue before running another record. If the fix is non-trivial, add a comment or log entry explaining *why* the fix was needed.

### Phase 3: Save the Utility Script

Once the single-shot works for each type:

1. Extract the core logic into a **standalone script** at `Skills/<Domain>/Scripts/<descriptive-name>.ps1` (or `.py`, `.js`, etc.).
2. The script must:
   - Accept inputs as **parameters** (not hardcoded values)
   - Have a `-WhatIf` or `-DryRun` switch for safe testing
   - Log its actions at each step
   - Return structured output (exit code, stdout JSON, or written file)
   - Validate its own prerequisites (check auth, check dependencies)
3. Write a **header comment block** at the top:

```
<#
.SYNOPSIS
  One-line summary of what this script does.

.DESCRIPTION
  Paragraph explaining the problem it solves and how it fits into the skill workflow.

.PARAMETER <name>
  Description of each parameter.

.EXAMPLE
  Example usage with typical arguments.

.NOTES
  What worked: <what went right during prototyping>
  What didn't: <what failed and how it was resolved>
  API limits: <observed rate limits, batch sizes that work>
  Idempotent: Yes/No — can this be re-run safely?
#>
```

4. Reference the script from the skill `.md` file in the appropriate section.

### Phase 4: Scale Up — Small Batch

After the single-shot passes:

```
Single shot (1 per type) → verify each
  ↓ pass
Small batch (3-5 records) → verify each
  ↓ pass
Medium batch (20 or 10% of total) → verify each
  ↓ pass
Full run → monitor for new failure modes
```

1. Run a small batch (3-5 records, covering all known types).
2. Verify every output.
3. If any fail, go back to Phase 2.
4. If all pass, expand the batch to ~20 records or 10% of total, whichever is smaller.
5. Verify every output again.
6. Only after two successive batch passes do you run the full dataset.

**Rate limit discipline:**
- Insert `Start-Sleep` or `time.sleep()` between calls. Default: 1 second minimum.
- For APIs with documented limits, use `(1000 / rate_per_second)` ms as minimum delay.
- If a `429` or rate-limit error occurs: stop, read `Retry-After` header, back off accordingly, then reduce pace by 50%.
- Log the total number of API calls made at each phase to track footprint.

### Phase 5: Record What Worked and What Didn't

At session end (before handoff), write a structured Cowork log entry covering:

```
**Problem**: <what we set out to solve>
**Approach**: <the path taken>
**Tools used**: <languages, libraries, APIs, endpoints>
**What worked**: <patterns that succeeded, with verification method — test pass, API response, command stdout>
**What didn't work**: <approaches tried and rejected, with why>
**Surprises**: <unexpected behaviours discovered>
**Skill gaps**: <what the skill doesn't cover yet>
**API footprint**: <number of calls made, errors encountered, rate limit headroom>
**Utility scripts created**: <paths to saved scripts>
```

This log feeds the Cowork Stub written per the Cowork Workflow in AGENTS.md.

---

## Utility Script Template

Use this structure for all new utility scripts:

```powershell
<#
.SYNOPSIS
  Brief description of what this script does.

.DESCRIPTION
  Full description of the problem it solves and where it fits in the skill workflow.

.PARAMETER InputPath
  Path to input data.

.PARAMETER DryRun
  If set, log what would be done without making changes.

.EXAMPLE
  .\Script.ps1 -InputPath "data.csv" -DryRun

.NOTES
  What worked: X, Y, Z
  What didn't: A (resolved by doing B)
  API limits: 10 req/s, observed safe at 1 req/100ms
  Idempotent: Yes
#>

param(
  [Parameter(Mandatory)]
  [string]$InputPath,

  [switch]$DryRun
)
```

---

## Anti-Pattern Checklist

Before declaring a prototype complete, check all:

- [ ] Every API endpoint was tested with a real call, not assumed to work.
- [ ] Every input type was tested at least once.
- [ ] Failures were investigated, not papered over with try/catch skips.
- [ ] The utility script has parameterized inputs, not hardcoded values.
- [ ] The script has `-DryRun` or `-WhatIf` support.
- [ ] Rate limits are documented in the script header.
- [ ] The script is idempotent, or its non-idempotence is documented.
- [ ] What-worked and what-didn't was recorded.
- [ ] The skill `.md` file references the script by relative path.
- [ ] The API was not hammered with invalid requests — calls were paced and error bodies were read.
