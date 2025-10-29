# Overview

Maintain the rule files in `./cursor/rules` so they always reflect the current, stable architecture.

## Responsibilities
- Track project changes (provided by the user or discovered via `git log`/`git diff`) and map them to the relevant Cursor rule files.
- Review the existing rule text before editing; avoid unnecessary rewrites.
- Update or create rule files only when patterns and decisions are solid and broadly applicable.
- Keep every rule file concise (hard limit 300 lines, aim for <100).
- Generally follow the `[area]-[domain].mdc` naming format (area: `engine` or `godot`; domain: feature scope or concept such as `code-style`), unless the rules are applicable in both areas.

## Operating Procedure
1. **Understand the change.** Gather the context from the latest instructions or recent commits to learn what behavior or structure has shifted.
2. **Locate candidate rules.** Inspect `./cursor/rules` for files that govern the affected area. Prefer updating an existing rule over creating a new one unless a distinct context is required.
3. **Assess current guidance.** Read the relevant rule file(s) to confirm what they currently state about the topic.
4. **Edit deliberately.**
   - Capture only enduring architecture, conventions, or behaviors.
   - Confirm the file name matches its scope and rename using the `[area]-[domain].mdc` convention before committing content changes.
   - Make sure `alwaysApply`, `glob`, and `description` follow the gating rule: either set `alwaysApply: true`, or set `alwaysApply: false` and use either `globs` (list of file patterns) OR `description` (when the rule should apply).
   - Remove or revise guidance that is now outdated.
5. **Validate.** Ensure the revised file remains under the line limit, retains a clear overview-first structure, and excludes speculative or temporary notes.
6. **Document outcome.** Summarize the updates made so future maintainers understand the change rationale.

## Content Rules
- Include: stable architectural patterns, naming conventions, directory purposes, automation boundaries, default decision logic.
- Exclude: open questions, experimental ideas, TODOs, or anything likely to change soon.
- Structure each file with a short overview followed by crisp sections for solidified rules.

## Quality Checks
- No redundant overlapping globs across files; prefer the most specific scope.
- Confirm decisions align with the current codebase behavior.
- Run quick sanity checks (e.g., `rg` to verify file matches) when adding new globs.
- Leave the file formatted in clear Markdown with bullet lists or short paragraphs only where helpful.
