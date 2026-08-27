# Skill: Refactor Skills — Directory Restructure, Rename, Merge

**Purpose**: Guide a Cowork agent through restructuring a domain's skill folder — moving files, renaming skills, merging overlapping skills, and updating all cross-references without breaking the skill discovery system.

**Owner**: `Cowork` role. Also useful for Code/Plan agents planning a skills restructure.

**Trigger**: User says "restructure this domain", "move skills around", "merge these skills", "rename this skill".

**Prerequisites**: Write access to `Skills/`, `Skills/skills.json`, `Skills/skills-index.json`.

---

## Workflow

### Phase 0: Discover Current State

1. **Map the domain** — list all `.md` files and their frontmatter `name` fields:

   ```powershell
   Get-ChildItem -LiteralPath "Skills/<Domain>" -Recurse -Filter "*.md" | ForEach-Object {
       $name = (Select-String -Path $_.FullName -Pattern "^name: " | ForEach-Object { $_ -replace 'name: ','' } | Select-Object -First 1)
       [PSCustomObject]@{ Path = $_.FullName.Replace((Get-Item "Skills/<Domain>").FullName + '\',''); Name = $name }
   } | Sort-Object Path
   ```

2. **Check manifests** — find all entries for this domain in both manifests:

   ```powershell
   Select-String -Path "Skills/skills.json", "Skills/skills-index.json" -Pattern '"<domain>/' -SimpleMatch | ForEach-Object { "$($_.FileName): $($_.Line.Trim())" }
   ```

3. **Inventory cross-references** — grep for old paths/skill-names across the codebase before moving:

   ```powershell
   rg -l "old/path/or/name" "Skills/" "Infrastructure/" "docs/" "AGENTS.md"
   ```

4. **Verify `_moved-skills.md` exists** — if the domain already has one at `Skills/<Domain>/_moved-skills.md`, read it first to avoid conflicts.

### Phase 1: Execute Moves & Renames

1. **Create target directories** before moving:

   ```powershell
   New-Item -ItemType Directory -Path "Skills/<Domain>/<target>" -Force
   ```

2. **Move/rename files** using `Move-Item` or `Rename-Item`:

   ```powershell
   Move-Item -LiteralPath "old/path.md" -Destination "new/path.md" -Force
   Rename-Item -LiteralPath "path/old-name.md" -NewName "new-name.md"
   ```

3. **For bulk directory moves**, use:

   ```powershell
   Move-Item -LiteralPath "Skill/bookkeeping/old-folder" -Destination "Skills/Bookkeeping/new-parent/"
   ```

4. **Recover lost files** from git if a move accidentally drops content:

   ```powershell
   git show HEAD:"old/path/to/file.md" > "new/path/to/file.md"
   ```

### Phase 2: Update Manifests

1. **Fix paths in skills.json** — the most reliable approach is a Python or PowerShell replace on the raw text, covering all variants:

   ```powershell
   (Get-Content "Skills/skills.json" -Raw) -replace 'old/path/prefix/','new/path/prefix/' | Set-Content "Skills/skills.json" -NoNewline
   ```

2. **Fix skill names** when renaming — use targeted Python script since names are structured JSON keys.

   **⚠ Check both `path` fields AND `cross_refs` arrays** — the replace on raw text cleans both at once.

3. **Fix skills-index.json** identifiers and paths — same approach.

4. **Mark stale entries** when merging: set `"stale": true, "superseded_by": "new/skill/name"`.

5. **Verify after each manifest change**:

   ```powershell
   python -c "import json; json.load(open('Skills/skills.json'))" && echo "skills.json valid"
   ```

### Phase 3: Update Cross-References

1. **Update .md file references** — after manifests are updated, grep for old names/paths in active `.md` files and bulk-replace:

   ```powershell
   $files = @("file1.md","file2.md")
   foreach ($f in $files) { (Get-Content $f -Raw) -replace 'old/name','new/name' | Set-Content $f -NoNewline }
   ```

2. **Update frontmatter `name:` fields** in the moved files themselves.

3. **Update glossary** if terms changed (`docs/Glossaries/<domain>.md`).

4. **Update `_moved-skills.md`** — append a row for each move to the domain's migration registry.

5. **Update `AGENTS.md`** if the skill table references changed paths/names.

6. **Skip `Tasks/Complete/`, `Tasks/Handoff/`, `Archived/`** — these are historical records, do not update them.

### Phase 4: Verify & Commit

1. **Verify all paths resolve**:

   ```powershell
   python -c "
   import json, os
   d=json.load(open('Skills/skills.json'))
   bad=[e for e in d if e.get('name','').startswith('<domain>/') and not os.path.exists(e.get('path',''))]
   print([b['name'] for b in bad])  # should be empty
   "
   ```

2. **Verify all index paths resolve** (same pattern for `skills-index.json`).

3. **Clean up empty directories**:

   ```powershell
   Get-ChildItem "Skills/<Domain>" -Directory | Where-Object { (Get-ChildItem $_.FullName -File).Count -eq 0 } | Remove-Item -Force -Recurse
   ```

4. **Commit in logical groups** — one commit per concern (moves, manifests, cross-refs, docs):

   ```powershell
   git add <moved-files> && git commit -m "refactor: move X to Y"
   git add Skills/skills.json Skills/skills-index.json && git commit -m "chore: update manifest paths"
   git add <doc-files> && git commit -m "docs: update cross-refs"
   ```

5. **Push** and report the final structure.

## Common Patterns

### Rename a skill file (file + name + all refs)

1. `Rename-Item` the file
2. Update `name:` frontmatter in the renamed file
3. `-replace 'old/name','new/name'` in both manifests
4. `-replace 'old/name','new/name'` in all active `.md` files

### Merge skill A into skill B

1. Absorb A's content into B's `.md` file
2. Remove A's file
3. In skills.json: set `"stale": true, "superseded_by": "skill/B"` on A's entry
4. Update all cross-refs from A's name to B's name

### Move a directory subtree

1. `Move-Item` the directory to the new parent
2. `-replace 'old/dir/','new/dir/'` in both manifests (hits all paths at once)
3. `-replace 'old/dir/','new/dir/'` in active `.md` file cross-refs
4. Remove the now-empty old directory

## Known Gotchas

| Gotcha | Symptom | Fix |
|--------|---------|-----|
| PowerShell `Move-Item *` wildcard fails | Item not found | Use `Get-ChildItem | ForEach-Object { Move-Item }` |
| PS `-replace` on JSON with JSON-sensitive chars | Malformed JSON | Use Python `json.load()`/`json.dump()` instead |
| LF→CRLF warnings on commit | Git line-ending normalization | Normal; safe to ignore |
| Skills-index.json key not updated by raw `-replace` | Index still has old key | Use Python to rebuild the index dict |
| Cross-refs remain in `Tasks/Complete/` | Historical files reference old paths | Leave them — read-only history |

## See Also

- `Skills/Archive/workflow-cowork-cowork.md` — Cowork mode entry point
- `Skills/Archive/bookkeeping-moved-skills.md` — worked example of this pattern
- `Skills/skills.json` — central skill manifest
- `Skills/skills-index.json` — lightweight discovery index
