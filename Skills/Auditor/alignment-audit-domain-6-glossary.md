# Domain 5: Glossary Consistency

**Purpose**: Ensure the `docs/Glossaries/` directory accurately reflects the domain vocabulary used across the codebase. Detect terms used in code without glossary entries, glossary entries never referenced in code, and cross-domain terms missing from `_shared.md`.

**Trigger**: Run this survey when:
- Adding or modifying any glossary file in `docs/Glossaries/`
- Editing any skill or documentation file that introduces new domain vocabulary
- After any session that creates new infrastructure, protocol, or pipeline concepts
- As part of a full alignment audit

**Survey procedure**:

1. **Extract glossary term set**: Read all `*.md` files in `docs/Glossaries/` and collect all term names (lines matching `^\*\*(\w[ \w]*)\*\*$`). Build a map: term → source glossary file. Separate `_shared.md` terms from domain-specific terms.

2. **Sample skill/doc files for term usage**: For each domain glossary (accountant.md, agent-operations.md, etc.), identify the primary source files that should use those terms.

    > **Primary source files** are determined by the glossary's `_Source:_` frontmatter field (each glossary term SHOULD list its source files). For terms missing `_Source:_`, define primary files as:
    > - **Domain glossaries** (e.g., `accountant.md`): files under the corresponding skill directory (`Skills/Bookkeeping/`, plus `Infrastructure/bookkeeping/`)
    > - **`_shared.md`**: all files under `Skills/`, `docs/`, `AGENTS.md`, and `Tasks/ToDo/todo.md` <!-- doc-lint: exempt -->
    > - **`deployment.md`**: `Skills/Docker/*.ps1`, `Skills/Docker/Modules/Interclaw.*/`, `docs/Reference/DEPLOYMENT.md`
    > - **`infrastructure.md`**: `Infrastructure/`, `Skills/Docker/`, `Infrastructure/manifests/`
    > - **`agent-operations.md`**: `Skills/ORCHESTRATOR/Personas/*/agents.md`, `docs/Reference/`, `Tasks/`

    Grep the primary source files for each term. Terms with zero references across all expected source files are orphaned — either the glossary entry is stale or the term was renamed in code but not updated in the glossary.

3. **Check for undocumented terms**: For each primary source file group, extract bolded terms, section headers, and named concepts. Cross-reference against the relevant glossary. Terms used in code but missing from the glossary are documentation gaps — log them as findings.

4. **Check `_shared.md` for cross-domain terms**: Scan all domain glossaries for terms that appear in two or more domain files. Any such term should be promoted to `_shared.md` with `_See also_` references from the domain glossaries. Log violations as Medium severity.

5. **Log findings**: Log each inconsistency to the Findings Manifest via `Write-Finding`. Use the finding's `Files` array to reference affected glossary and source files. Severity based on impact:
   - **High**: A critical domain term used extensively in code has no glossary entry → agents may use inconsistent vocabulary
   - **Medium**: Cross-domain term missing from `_shared.md` → risk of definition drift
   - **Low**: Orphaned glossary entry (term defined but never referenced) → documentation debt

6. **Plan generation note**: Do not generate session plans during survey. All plan generation happens in Phase B. The consolidation script groups glossary findings by file path (which glossary `.md` files need updating) and produces session plans from those groups.
