## Update Skills Workflow

Single-pass workflow. Does not enter a drain/poll loop.

### Phase 0: Inventory — What Skills Were Used

1. **Load skill-usage log**: Attempt to read `Tasks/Logs/<session-timestamp>-skill-usage.log`. Each line contains `SKILL_USED:<skill-name>` recorded during the session.

2. **Fallback to context introspection**: If the log file does not exist or is empty, introspect session context to list every skill loaded. Verify each candidate exists on disk via glob or read before adding to the inventory.

3. **Deduplicate**: Combine log + introspection results. Store as an ordered list of skill paths.

4. **Classify each skill**:
   - **Formal skill**: Registered in `skills.json` with a `.md` file at the resolved path.
   - **Ad-hoc pattern**: Used during the session but no skill file exists. Needs formalization (Phase 2).
   - **External / built-in**: Not owned by this project (e.g., opencode built-in skills like `customize-opencode`). Skip — cannot modify.

5. **Identify scripts used**: Scan session context for any `.ps1`, `.py`, `.js`, or other script files invoked. Add them to a parallel script inventory for Phase 3.

### Phase 1: Lessons Consolidation (not Append-Only)

For each formal skill in the inventory:

1. **Read the skill file(s)**: Load the `.md` file(s) at the resolved path from `skills.json`.

2. **Consolidate lessons into the skill body**: Do NOT append a dated section. Instead, update the skill's existing structure:

   | Source lesson | → Target location |
   |---|---|
   | **What Worked** | Merge into the skill's Procedure section as current best practice. If already present, skip. |
   | **What Didn't Work** | Add or update `## Troubleshooting` / `## Known Failure Modes`. Document WHY it failed and the resolution. |
   | **Improvements for next run** | Apply to the Procedure section. If already incorporated, record the date in the Changelog. |
   | **Helpful Information** | Add to relevant section as inline notes or reference data. |
   | **Root Cause Analysis** | Condense into the troubleshooting entry. Keep root cause, fix, and prevention — omit session narrative. |

3. **Write (or update) Changelog**: At the bottom of the skill file (before `## Cross-References`), maintain a single `## Changelog` section with one-line entries per session:

   ```markdown
   ## Changelog
   - YYYY-MM-DD: Integrated retry logic from receipts pipeline into Procedure
   - YYYY-MM-DD: Documented IMAP rate limit error in Troubleshooting
   ```

   **Changelog rules**:
   - One bullet per session — never more
   - No sub-headings, no narrative, no pipe tables
   - ISO 8601 date prefix
   - If a Changelog already exists, insert the new entry in reverse chronological order

4. **Fall back to dated Lessons Learned block for novel failures only**: If a lesson describes a genuinely novel failure mode that does not fit into any existing skill section (rare — typically only for completely new capabilities), you MAY append a `### Lessons Learned — YYYY-MM-DD` block. This is the exception, not the rule. The block must include a `<!-- consolidate-next-cycle -->` comment:

   ```markdown
   ### Lessons Learned — YYYY-MM-DD
   <!-- consolidate-next-cycle -->

   **What Worked**:
   - <approach> — <verification method>

   **What Didn't Work**:
   - <approach> — <why it failed, error message, root cause>

   **Improvements for next run**:
   - <specific improvement>

   **Helpful Information**:
   - <gotchas, edge cases, useful context for future agents>
   ```

   **Formatting rules** (for the fallback block, if used):
   - Heading level: `###` (level-3) only
   - Date separator: em-dash `—` with spaces
   - Date format: `YYYY-MM-DD` (ISO 8601)
   - Content: bullet points (`-`), never pipe tables
   - Sub-headings: bold text (`**What Worked**`), not markdown headings
   - Requires `<!-- consolidate-next-cycle -->` comment immediately after the heading

5. **Fix stale content** if encountered during the session:
   - References to deleted/retired files → replace with current paths or remove
   - Superseded_by pointers that lead to broken targets → fix or remove
   - Code examples that use removed APIs → update to current API
   - Outdated procedure steps → rewrite to match actual process

6. **Update cross-references** in the skill if the session revealed missing or broken links:
   - Add cross_refs for related skills discovered during the session
   - Fix any `git grep -l` references that point to stale paths

### Phase 2: Formalize — Create New Skill Files

For each ad-hoc pattern identified in Phase 0 step 4:

1. **Evaluate**: Is this pattern likely to be reused by future agents? If yes, proceed. If it was a one-off workaround, add a Changelog entry in the relevant skill noting the context.

2. **Choose file structure**:
   - **Single-file** (`.md`): For simple, focused skills (1-3 step procedures, reference info).
   - **Three-file** (`SKILL.md` + `workflow.md` + `tools.md`): For complex workflows with multiple phases and tool constraints.

3. **Write the skill file(s)** following project conventions:
   - YAML frontmatter block at the top with `name`, `description`, `type`, `flavor`, `loaded_by`, `container` (minimum: `name`, `description`, `type`, `flavor`)
   - Clear purpose statement and trigger conditions after frontmatter
   - Step-by-step instructions
   - Red lines / constraints section
   - Cross-references to related skills, scripts, and docs
   - `depends_on` listing prerequisite skills

4. **Register placeholder path**: Note the file path for Phase 4 registry update.

### Phase 3: Script Audit & Refactor

For each script in the script inventory (Phase 0 step 5):

1. **Read the script**: Understand its inputs, outputs, and logic.

2. **Assess reusability**:
   - Does it accept data as parameters/arguments (not hardcoded)?
   - Does it have a clear, semantic name following conventions?
   - Does it follow PowerShell/Python/JS best practices?
   - Does it have help text or `--help` support?
   - Does it validate its inputs?

3. **Refactor if needed**:
   - Add parameter blocks (PowerShell): `param([string]$InputPath, [string]$OutputDir)`
   - Add argument parsing (Python): `argparse` or `sys.argv` with validation
   - Add `--help` / `-?` documentation
   - Validate inputs before processing
   - Output structured data (JSON, CSV) for pipeability
   - Handle errors gracefully with meaningful messages
   - Follow language-specific best practices:
     - **PowerShell**: `Verb-Noun` naming, `[CmdletBinding()]`, `Write-Output` / `Write-Error`, `.PARAMETER` comment-based help
     - **Python**: `if __name__ == "__main__":` guard, `argparse`, type hints, `logging`
     - **JavaScript/Node**: `#!/usr/bin/env node`, `process.argv` or `commander`/`yargs`, error-first callbacks or async/await

4. **Rename if needed**: Apply semantic naming per AGENTS.md conventions.

### Phase 3b: Cross-Reference Scripts in Skills

After refactoring, ensure skills that use or reference each script list it:

1. **For each skill that calls the script**: Add a cross-reference to the script path in the skill's `Cross-references` section (or `cross_refs` in `skills.json`).

2. **For each script**: Add a header comment block noting which skill(s) call it:
   ```
   # Used by: Skills/<domain>/<skill>/SKILL.md
   ```

3. **Create a script reference table** in the owning skill if multiple scripts exist:
   ```markdown
   ## Scripts
   | Script | Purpose | Inputs |
   |--------|---------|--------|
   | `Scripts/Verb-Noun.ps1` | Processes X | `-InputPath`, `-OutputDir` |
   ```

### Phase 3c: Glossary Update

After all skills and scripts are updated, update the project glossary with any new or changed domain terminology:

1. **Inventory new domain terms**: Scan all skills and scripts modified or created in this session for domain-specific terms (nouns, concepts, patterns) that appear in multiple domains or have project-specific meaning.

2. **Determine the correct glossary file**:
   - **Cross-domain terms** (appear in 2+ domains): add to `docs/Glossaries/_shared.md`
   - **Domain-specific terms**: add to the relevant file under `docs/Glossaries/` (e.g., `Bookkeeper.md`, `agent-operations.md`, `deployment.md`, `infrastructure.md`)
   - If no existing glossary file matches, add a new one.

3. **Add or update entries** following the existing format:
   ```markdown
   **Term**:
   Definition explaining what the term means in this project's context.
   _Avoid_: Synonyms that should not be used, deprecated names
   _See also_: Related terms (use `_shared:Term` format for cross-domain refs)
   _Source_: File paths where the term is defined or primarily used
   ```

4. **Verify existing entries**: For every glossary file that references files modified in this session, check that the `_Source_` paths still exist on disk and still match current usage. Update stale paths or remove entries for retired concepts.

5. **Flag for CC**: If any new glossary entries were added, the caller's Completion Checklist must run `git add` on the modified glossary file(s).

### Phase 4: Registry — skills.json Update

1. **Collect all changes**:
   - New skills created in Phase 2
   - Existing skills whose `cross_refs`, `description`, `stale`, or `superseded_by` changed in Phase 1
   - Skills whose lessons-learned update improves the `description` field

2. **Build new entries** following the registry schema:
   ```json
   {
     "name": "domain/topic",
     "path": "Skills/<Domain>/<topic>.md",
     "container": "opencode",
     "type": "<type>",
     "description": "One-sentence summary.",
     "depends_on": [],
     "cross_refs": ["<related paths>"],
     "tags": ["domain", "topic"],
     "stale": false,
     "last_verified": "<today's date>"
   }
   ```
   **Note for workflow SKILL.md files**: The `container`, `flavor`, and `loaded_by` fields live in the YAML frontmatter of the SKILL.md, not in `skills.json`. When creating or updating a workflow SKILL.md entry, omit these fields from the JSON entry — they are redundant and will be dropped.

3. **Insert/update into `skills.json`**:
   - Add new entries in alphabetical order by `name`
   - Update existing entries in-place
   - For skills marked stale: add `"superseded_by": "<replacement skill name>"` and set `"stale": true`

4. **Validate against schema**:
   ```powershell
   $schemaPath = "Skills/skills.schema.json"
   $registryPath = "Skills/skills.json"
   # Manual validation: verify required fields present, stale have superseded_by, paths exist on disk
   ```

5. **Run the Skills Registry Gate (mandatory pre-commit)**:
   ```powershell
   pwsh Orchestrator/Orchestration/Invoke-SkillsRegistryGate.ps1
   ```
   - Exit code **0** (clean): proceed to commit.
   - Exit code **1** (broken refs): hard stop. The script lists every missing path/cross_ref/depends_on/superseded_by/persona_anchor/shared_refs. Fix the broken references (correct the path, drop the dead ref, or remove the entry) and re-run until exit 0.
   - Exit code **2** (schema parse error): the registry JSON is corrupt. Restore from git and re-apply the registry changes carefully.
   - Exit code **3** (registry file missing): re-create `Skills/skills.json`.
   - The gate is a hard requirement; do not commit while it returns non-zero.

6. **Update `AGENTS.md`** if any new skill is a shared-spec skill (referenced in the Key Files table or role templates).

### Sign Off

After Phase 4 completes, output a summary:

```
=== Update Skills Summary ===
Skills updated with consolidated lessons: <N>
Skills created: <N>
Scripts refactored: <N>
Glossary entries added/updated: <N>
Registry entries added/updated: <N>
Last verified: <date>
```

Write a summary to `Tasks/Logs/update-skills-<timestamp>.md` for auditability.

Do NOT enter a drain/poll cycle. Single pass.


### Archiving Stale Skills

When retiring a skill, prefer stale: true with superseded_by over deletion. If the skill is truly obsolete (no live references in the codebase), move to Archived/Skills/<original-path> with DEPRECATED- prefix and update the registry path.
