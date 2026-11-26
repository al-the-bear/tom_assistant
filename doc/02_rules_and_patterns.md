# Tom Brain Workspace: Complete Rules, Constraints, and Architectural Patterns

## Section 1: Code Organization Rules

### Project Naming Conventions

- **Project Names**: Use initial capitals with no underscores for documentation (e.g., `Tom Core`, `DartScript`, `VS Code Bridge`)
- **Package Names**: Use snake_case in pubspec.yaml (e.g., `tom_core`, `tom_vscode_extension`)
- **File Names**: Follow Dart conventions (snake_case for files)

### File Organization Patterns

**Dart Files:**
- Standard library files: `*.dart`
- DCli scripts (executable in dcli): `*.dcli.dart`
- D4rt scripts (executable in d4rt interpreter): `*.d4rt.dart`
- Generated reflection: `*.reflectable.dart`
- Generated models: `*.g.dart` (freezed, json_serializable, etc.)
- Generated copies: `*.freezed.dart`, `*.mocks.dart`

**File Structure in Source:**
```
lib/
  {module}.dart           # Public API exports
  src/
    {part}/               # Optional: logical groupings
      {module}/           # Feature implementation
        {module}.dart     # Main file
        {submodule}/      # Nested implementations
```

### Path Requirements

- **Absolute Paths**: Use absolute paths in all automated tools and scripts
- **Relative Symlinks**: Use relative symlinks for cross-machine mounts (e.g., `_ai/` layer)
- **No Temporary Files in /tmp**: Use `<workspace-root>/ztmp` for temporary files instead

### Directory Structure Standards

**Core Workspace Layout:**
```
workspace_root/
  lib/              # Package source (dart_package) or app source (flutter_app)
  bin/              # CLI entry points (console apps only)
  example/          # Usage examples
  test/             # Test files
  doc/              # User-facing documentation
  _agent_guidelines/  # Development guidelines (global or local)
  assets/           # Images, fonts, configuration
  .tom_metadata/    # Workspace metadata (auto-generated)
  tom_workspace.yaml    # Workspace-level configuration (user-editable)
  pubspec.yaml      # Package manifest
  analysis_options.yaml  # Linter configuration
  README.md         # Project documentation
  CHANGELOG.md      # Version history
  LICENSE           # License information
```

**Documentation Placement:**
- **User Documentation** → `doc/` folder (with subfolders for modules if needed)
- **Development Guidelines** → `_agent_guidelines/` folder (global or local to project)
- **README.md** → Always remains at project root (never move to doc/)
- **API Summaries** → `doc/api/api_summary_{module}.md`
- **Templates** → `_ai/quests/templates/` (YAML templates, document templates)
- **Quest Files** → `_ai/quests/{quest-id}/` folder

---

## Section 2: Development Workflow Rules

### Pre-Execution Steps

**CRITICAL: Commit First Rule**
- Before making changes to any project, commit the current state of that project
- Commits must be scoped to only the project(s) being modified
- Do not commit unrelated repos in the same commit
- Use meaningful commit messages that describe the changes

### QA and Testing Requirements

**Before Marking Tasks Complete:**
1. Run `dart analyze` on affected packages
2. Fix ALL issues in the VS Code Problems pane
3. Run `dart test` or `testkit :test` to verify changes work
4. Run `dart format` to ensure consistent formatting
5. No task is complete if analyzer errors/warnings exist

**Baseline Tracking for Tests:**
- Use `testkit :baseline` to create baseline CSV files
- Baseline files stored in `doc/baseline_MMDD_HHMM.csv`
- Use `testkit :test` to add results to most recent baseline
- Result format: `<current>/<baseline>` (e.g., `OK/OK`, `X/OK`, `OK/X`, `X/X`, `--/OK`)

### Dart Analyze Requirements

- **MUST run before task completion**: `dart analyze`
- **Analyzer errors** = Critical, must be fixed
- **Analyzer warnings** = Must be fixed unless explicitly ignored
- **False positives**:
  - Unused imports for reflection: Add `// ignore: unused_import`
  - Path dependency warnings during development: Expected, can proceed
  - Stale cache errors: Clear with `rm -rf .dart_tool && dart pub get`

### Build and Publish Order

**For Pub.dev Dependencies:**
1. Modify the base package (e.g., `tom_build_base`)
2. Test with test tools inside the base package
3. Republish to pub.dev
4. Run `dart pub upgrade` in each dependent project
5. Recompile dependent tools
6. Run tests in all dependent projects

**CRITICAL: Never use path overrides or `pubspec_overrides.yaml` for missing APIs** → Always publish to pub.dev first, then update version constraints

---

## Section 3: Multi-Project Rules

### tom_build_base Foundation Requirement

**ALL CLI tools MUST be based on `tom_build_base`:**
- CLI argument parsing (`CliArgParser`, `isHelpCommand`, `isVersionCommand`)
- Version display (generated `version.versioner.dart`)
- Process execution (`ProcessRunner`)
- Workspace navigation and project discovery
- Logger infrastructure (`ToolLogger`)
- Macro expansion (`expandMacros`)
- Help text generation (`getToolHelpHeader`)

**If functionality belongs to `tom_build_base`:**
1. Add it to `tom_build_base` FIRST
2. Create/use test tools in `tom_build_base` to verify
3. Publish `tom_build_base` to pub.dev
4. Update version in dependent tools
5. Rebuild all dependent tools

**NEVER add temporary downstream implementations** in tool packages — shared CLI infrastructure belongs in `tom_build_base`.

### Dependency Management Rules

**Workspace Layers (L1-L4):**
- **L1** = Code (al_the_bear submodule tree + sibling workspaces)
- **L2** = Binaries (tom_binaries repository)
- **L3** = AI state (`_ai/` = tom_agent_state, symlinked to single clone)
- **L4** = Third-party upstreams (pinned dependencies)

**Skills for Multi-Repo Workflow:**
- `/tom_pull` = Sync all layers (L1 + L4, then L3, then L2)
- `/tom_push` = Commit + push all layers (L3 → L2 → L1)
- `/tom_pull_code` = Sync L1 + L4 only
- `/tom_pull_binaries` = Sync L2 only (latest wins, discard local)
- `/tom_pull_ai` = Sync L3 only
- `/tom_clone <dir>` = Bootstrap fresh workspace

### Version Publishing Rules

**Published Packages to Pub.dev:**
| Package | Version | Location |
|---------|---------|----------|
| tom_build_base | 1.8.0 | tom_ai/basics/tom_build_base |
| tom_basics | 1.0.0 | tom_ai/basics/tom_basics |
| tom_d4rt | 1.8.1 | tom_ai/d4rt/tom_d4rt |
| tom_d4rt_generator | 1.8.2 | tom_ai/d4rt/tom_d4rt_generator |
| tom_reflection | 1.0.1 | tom_ai/reflection/tom_reflection |

**Publishing Workflow:**
1. Bump version in `pubspec.yaml`
2. Update `CHANGELOG.md`
3. Update `README.md` if API changed
4. Run tests: `dart test`
5. Dry run: `dart pub publish --dry-run`
6. Publish: `dart pub publish`
7. Update dependent projects' `pubspec.yaml`
8. Run `dart pub get` in dependent projects

### Path Overrides vs Pub.dev

**NEVER use:**
- `pubspec_overrides.yaml` for missing API dependencies
- Path overrides for published packages

**ALWAYS:**
- Publish to pub.dev first
- Update version constraints in `pubspec.yaml`
- Run `dart pub upgrade` to fetch from pub.dev

---

## Section 4: Copilot/AI Assistant Rules

### Todo List Requirements

**CRITICAL: Always follow these rules:**

1. **Create immediately**: Open chat todo list right after receiving prompt
2. **Pre-execution commit**: Add todo item for committing project state before work begins
3. **Scope commits**: Commits only include projects being modified
4. **Clear goals**: Each todo has explicit completion condition
5. **Mark in progress**: When starting a todo, immediately mark as `in_progress`
6. **Mark complete**: Only when FULLY completed (not just started)
7. **No batch marking**: Mark each todo complete as you finish it
8. **Task count**: Keep ONE todo as `in_progress` at a time

### Chat Todo List Patterns

**Template Structure:**
```
- [ ] Pre-execution: Commit current state of {project}
- [ ] {Main task 1}
- [ ] {Main task 2}
- [ ] {Main task 3}
- [ ] (Optional) Post-task verification and documentation
```

**Rules:**
- Always open a todo list, even for single-item prompts
- Use VS Code's internal todo list feature
- Add completion criteria for each task
- Mark items as complete only when verified

### Clarification File Patterns

**When clarification is needed:**
1. Create file in `_ai/clarifications/` with timestamp
2. Filename format: `{YYYYMMDD}_{HHMMSS}_clarification.{quest-id}.md`
3. Include numbered questions with answer options
4. Document assumptions if clarification not possible
5. Pause work until user responds

### Doc Placement Rules

**User Documentation:**
- Location: `doc/` folder (or subfolders for modules)
- Purpose: End-user guides, API docs for consumers
- Examples: User guides, API documentation, test baselines, issue tracking

**Development Guidelines:**
- Location: `_agent_guidelines/` (global or local)
- Purpose: Build workflows, testing patterns, coding standards
- Examples: Build guides, development workflows, architecture decisions

**Rule of Thumb:**
- **Developers** (including Copilot) → `_agent_guidelines/`
- **End-users** → `doc/`

---

## Section 5: Workspace Architecture Rules

### 4-Layer Architecture (L1, L2, L3, L4)

**Layer 1 (Code):** al_the_bear submodule tree + sibling workspaces
- Git repositories with Dart/Flutter projects
- Updated via `git pull --rebase` + `submodule update --remote --rebase`
- Command: `/tom_pull_code`

**Layer 2 (Binaries):** tom_binaries repository
- Precompiled binaries (flutter, dart tools, etc.)
- "Latest wins" semantics — local changes discarded
- Command: `/tom_pull_binaries`

**Layer 3 (AI State):** tom_agent_state (single clone, symlinked)
- Cloned ONCE at workspace root `_ai/`
- All other `_ai/` mounts are relative symlinks to this single clone
- Quest files, trail files, AI context
- Command: `/tom_pull_ai`

**Layer 4 (Third-party Upstreams):** External dependencies
- Pinned versions in `.gitmodules`
- Fetched during `git submodule update`
- Command: `/tom_pull_code` (includes L4)

### When to Use /tom_pull vs /tom_pull_code vs /tom_pull_binaries

- **`/tom_pull`**: Default, syncs all layers in dependency order (L1+L4 → L3 → L2)
- **`/tom_pull_code`**: Only code (L1+L4), skip binaries and AI state
- **`/tom_pull_binaries`**: Only update binaries (L2), discard local changes
- **`/tom_pull_ai`**: Only AI state (L3)

### Fleet Machine SSH Patterns

**VPN Network:** `10.8.0.0/24` with WireGuard

| Machine | OS | VPN IP | SSH Dest | Root | Path | Shell |
|---------|----|---------|---------|----|------|-------|
| **mbp** | macOS ARM64 | 10.8.0.7 | N/A (local) | — | `/Users/alexiskyaw/Desktop/Code/al_the_bear` | bash |
| **bomber** | Linux | 10.8.0.9 | `alexis@10.8.0.9` | `root@bomber` | `/srv/repos/al_the_bear` | bash |
| **bigbeast** | Linux | 10.8.0.1 | `alexis@10.8.0.1` | `root@bigbeast` | `/srv/repos/al_the_bear` | bash |
| **legiondary01** | Windows | 10.8.0.6 | `alexi@10.8.0.6` | N/A | `C:\Code\al_the_bear` | Git Bash |
| **legiondary02** | — | 10.8.0.5 | OUT OF SCOPE | — | — | — |

**SSH Access Rules:**
- Connect as the correct user (alexiskyaw on mbp, alexis on Linux, alexi on Windows)
- On Linux machines, repos owned by `alexis` — run git as `sudo -u alexis ...`
- Fleet skills connect via **VPN IP** (not root@)
- Git Bash on Windows: `C:\Program Files\Git\bin\bash.exe` (invoke explicitly)
- PowerShell default on Windows legiondary01 has restrictions on heredocs and command substitution

**Reachability:**
- mbp, bomber, and bigbeast can reach all 4 machines
- legiondary01 is target-only (reached by driver hosts)
- Windows (legiondary01) public keys in `C:\ProgramData\ssh\administrators_authorized_keys` (not per-user)

### When to Commit and Push

**Commit First Rule (Pre-Execution):**
- Before making changes, commit the current project state
- Only commit the project being modified (not unrelated repos)

**End-of-Session Push Rule:**
- At end of every session, push all your own work
- "Own work" = edits inside the quest project you own
- Use `/tom_push` to push all layers or per-layer variants
- For fleet root (al_the_bear), commit/push al_the_bear itself

**Specific Rule for Fleet Root Quest:**
- Only push the `al_the_bear` repository itself
- Don't blanket-publish L1, L2, L3 (use dedicated skills for those)

---

## Section 6: D4rt Integration Rules

### File Extensions (.dart vs .dcli.dart vs .d4rt.dart)

| Extension | Description | Execution |
|-----------|-------------|-----------|
| `*.dart` | Standard Dart files, normal compilation | `dart run`, compiled binaries |
| `*.dcli.dart` | DCli shell scripts | `dcli script.dcli.dart` |
| `*.d4rt.dart` | D4rt interpreter scripts | `d4rt script.d4rt.dart` |
| `*.dcli` | DCli replay files | `.load` or `.replay` in REPL |
| `*.d4rt` | D4rt replay files | `.load` or `.replay` in D4rt REPL |

**Note:** DCli replay files can run in D4rt but may have compatibility issues

### When to Bridge and When to Execute Directly

**Bridge (use D4rt bridge generator):**
- Need to call native Dart classes from D4rt scripts
- D4rt needs access to complex Dart types
- Calling code is more readable via bridge

**Execute Directly (no bridge):**
- Using built-in D4rt functions
- Simple, standalone D4rt logic
- No need for external Dart class interaction

### DCli vs D4rt Usage Patterns

**Use DCli when:**
- Writing quick shell-like scripts
- Primarily executing system commands
- Need simple string/process manipulation
- Building workflows with `dcli run`

**Use D4rt when:**
- Need sandboxed Dart code execution
- Complex data processing/transformation
- Building reusable script components
- Integrating with Dart libraries via bridges

**D4rt Bridging Patterns:**
- Follow guidelines in `tom_ai/d4rt/tom_d4rt/_agent_guidelines/d4rt_bridgedclass_guidelines.md`
- Use `BridgedClass` registration for native Dart classes
- Auto-generation via `tom_d4rt_generator`
- E2E testing via `testing_d4rt_bridges.md` patterns

---

## Section 7: Quest/Documentation Rules

### Quest File Naming and Structure

**Standard Quest Files (include quest-id in filename):**

```
_ai/quests/{quest-id}/
├── overview.{quest-id}.md              # PRIMARY: quest context, objectives, state
├── todos.{quest-id}.yaml               # Structured todo list (YAML schema)
├── open_topics.{quest-id}.md           # Topics for future discussion (Copilot adds)
├── deferred.{quest-id}.md              # Deferred work steps (Copilot adds when user says "for now")
├── copilot_todos.{quest-id}.md         # Copilot's task list (user reviews before execution)
├── references.{quest-id}.md            # Relevant documents and resources
├── {quest-id}.code-workspace           # VS Code workspace file (workspace-root folder only)
├── live-trail.md                       # Rolling log of last ~5 exchanges
└── history/                            # Generated, gitignored — machine-local
    ├── {quest-id}.anthropic.prompts.md # Full history of prompts sent
    └── {quest-id}.anthropic.answers.md # Full history of answers received
```

### Overview, Todos, Completion_Steps Patterns

**overview.{quest-id}.md:**
- Primary document for quest context
- Read FIRST when resuming a quest
- Contains: objectives, current state, constraints, decision context
- Updated as quest progresses

**todos.{quest-id}.yaml:**
- Structured todo list with schema validation
- Uses `_ai/schemas/yaml/todo.schema.json`
- Tracks task status and dependencies
- Automatically validated

**deferred.{quest-id}.md:**
- Deferred work steps
- Created when user explicitly says "for now"
- Documents incomplete implementation for future continuation
- Includes: what remains, next steps, decision points

### When to Defer Work vs Complete

**Defer (add to completion_steps):**
- User explicitly says "for now" or defers a task
- Out of scope for current session
- Blocked by external dependencies
- Requires multi-session effort

**Complete:**
- All tests pass
- Code analyzed and cleaned
- Documentation updated
- Matches specified acceptance criteria
- No blockers remaining

---

## Section 8: Testing Rules

### Test Project Naming (zom_ prefix)

**Test Project Convention:**
- Projects starting with `zom_` are for testing purposes ONLY
- Located in `zom_workspaces/zom_analyzer_test/` folder
- Used for: build tool testing, workspace analyzer testing, code generator testing
- NOT included in production builds
- Examples: `zom_test_standalone`, `zom_test_flutter`, `zom_test_package`

### TestKit Usage Patterns

**Commands:**
```bash
testkit :test              # Run tests, add results to most recent baseline
testkit :baseline          # Create new baseline CSV file
testkit :test --test-args="--name 'pattern' --fail-fast"  # With test filtering
```

**Baseline CSV Format:**
- Located in `doc/baseline_MMDD_HHMM.csv`
- Most recent file is the currently relevant baseline
- Columns: ID, Groups, Description, Result
- Result format: `<current>/<baseline>` (e.g., `OK/OK`, `X/OK`, `OK/X`)
- `-` = SKIP, `X` = FAIL, `OK` = PASSED

**Naming Convention for Tests:**
- Use format: `ID: description [date] (result)`
- Example: `001: Parser handles empty input [2026-06-14] (OK)`
- Enables automatic baseline CSV formatting

### Baseline Tracking

- **Create**: `testkit :baseline` generates new `baseline_MMDD_HHMM.csv`
- **Update**: `testkit :test` adds column to most recent baseline
- **Tracking**: Shows progression: pass → fail → fix → pass (regression detection)

### When Tests Are Required

**ALWAYS write tests:**
- Bug fixes (test reproduces bug first)
- New features (test describes expected behavior)
- API changes (test verifies new contract)
- Edge cases (test boundary conditions)

**Exception (write after):**
- Exploratory prototyping (add tests before merging)
- Spike investigations (discard code, add tests for real implementation)
- Emergency hotfixes (add test immediately after)

---

## Section 9: Quality Assurance Rules

### When dart analyze Must Be Run

**BEFORE marking ANY task complete:**
1. Run `dart analyze` on affected packages
2. Fix ALL issues in VS Code Problems pane
3. Re-run `dart analyze` until clean

**No task is complete if:**
- Analyzer errors exist
- Analyzer warnings exist (unless explicitly ignored with `// ignore:`)
- VS Code Problems pane shows issues
- Tests failing

### Analyzer Error vs Warning Handling

| Issue Type | Action | Exception |
|-----------|--------|-----------|
| **Errors** | Must fix | None — critical |
| **Warnings** | Must fix | Explicit `// ignore:` comment allowed |
| **False positives** | Use ignore directives | See below |

**Common False Positives:**
- `unused_import` for reflection: Add `// ignore: unused_import` with reason
- `prefer_relative_imports` in generated code: Ignore as necessary
- Path dependency warnings: Expected during development, can proceed
- File name linting errors: Try to fix, use `// ignore: file_names` if essential

### Problems Pane Cleanup Requirement

**Definition:** VS Code Problems pane must be empty before task completion

**Scope:**
- Only check files modified in this session
- Related files affected by changes
- Generated files if modifications required

**Process:**
1. Run `dart analyze`
2. Address each error (fix or ignore with comment)
3. Address each warning (fix or ignore with comment)
4. Reload VS Code window if needed
5. Verify Problems pane is clean

### Task Completion Criteria

A task is complete when ALL of these are true:

✅ Original requirements met (from prompt or spec)
✅ All tests pass (new and existing)
✅ `dart analyze` runs clean (no errors/warnings unless ignored)
✅ VS Code Problems pane is empty
✅ Code formatted (`dart format`)
✅ Documentation updated if needed
✅ Changes committed with meaningful message
✅ No open blockers or unresolved questions

---

## Section 10: Cross-Machine Fleet Rules

### Machine Names and SSH Destinations

**Fleet Machines (SSH Mesh):**

| Machine | User | SSH Dest | Purpose |
|---------|------|----------|---------|
| **mbp** | — | Local | Developer machine (primary) |
| **bomber** | alexis | `alexis@10.8.0.9` | Linux build host |
| **bigbeast** | alexis | `alexis@10.8.0.1` | Linux hub (VPN center) |
| **legiondary01** | alexi | `alexi@10.8.0.6` | Windows build host |
| **legiondary02** | — | OUT OF SCOPE | Not part of fleet |

**Accessing Machines:**
- On Linux: Use `alexis` user (repos owned by alexis)
- On Windows: Use `alexi` user (note: not `alexis`)
- On macOS: No SSH (local machine)

### VPN Configuration

**Network:** WireGuard, `10.8.0.0/24` (10-bit prefix)

**VPN IPs:**
- mbp: 10.8.0.7
- bomber: 10.8.0.9
- bigbeast: 10.8.0.1 (hub)
- legiondary01: 10.8.0.6
- legiondary02: 10.8.0.5 (out of scope)

**Access Pattern:**
- All SSH connections use VPN IPs: `user@10.8.0.x`
- Key-based authentication (non-interactive, BatchMode)
- No password authentication

### Which Machines Can Be Driver Hosts

**Can drive `/tom_full_reconcile*` commands:**
- mbp (macOS)
- bomber (Linux)
- bigbeast (Linux)

**Cannot drive (target-only):**
- legiondary01 (receives changes, doesn't push)
- legiondary02 (out of scope)

**Rationale:** Driver hosts must have pub.dev access, correct Git config, and can push to origin

### State Synchronization Patterns

**One-Round vs Two-Round Reconciliation:**

- **One-Round (`tom_reconcile`):** Local machine only
  - Stash uncommitted work
  - Fetch remote changes
  - Merge (not rebase) into local
  - Restore stash
  - Recommit if needed
  - Push only if no conflicts

- **Two-Round (`tom_full_reconcile`):** All fleet machines
  - Round 1: Each machine reconciles independently (stash → fetch → merge → restore)
  - Round 2: Each machine reconciles again (captures Round 1 changes from origin)
  - Ensures convergence when multiple machines have changes

**Why Two Rounds:**
- Changes committed on machine A are pushed to origin
- Machines B, C, D fetch and merge Round 1 changes
- But uncommitted work on B, C, D may now conflict with A's changes
- Round 2 catches these new conflicts

**Git Workflow (never rebases during reconcile):**
- `git stash` → `git fetch` → `git merge origin/main` → `git stash pop`
- Merge (not rebase) to preserve local history
- Handles submodule pointer changes via bulk `submodule update`

---

## Gotchas and Anti-Patterns

### Critical Anti-Patterns

❌ **NEVER DO:**
- Use path overrides for pub.dev dependencies — publish first, then update version
- Commit unrelated repos in a single commit — scope to changed project only
- Leave analyzer errors/warnings — they block task completion
- Mark todos complete without verification — tests must pass, code must be clean
- Create new `_ai/` mount by cloning — use `tom_clone` / `tom_ensure_ai_link`
- Implement CLI features in tool packages — belongs in `tom_build_base`
- Force push to main/master branches — dangerous, requires explicit user approval
- Skip pre-commit review — commit first, test second, push third
- Use `cd` in scripts — use absolute paths throughout

### Common Pitfalls

⚠️ **Watch Out For:**
- **False Positive Analyzer Errors**: DCli and D4rt scripts may reference non-existent symbols until generation completes. This is expected and temporary.
- **Circular Dependencies**: The workspace enforces dependency direction (foundation ← domain ← application). Circular dependencies cause build failures.
- **Stale Cache**: If `.dart_tool/` becomes corrupted, rebuild: `rm -rf .dart_tool && dart pub get`
- **Windows PowerShell Escaping**: `$(...)` and `@{...}` patterns get mangled by outer PowerShell parser. Use Git Bash for git commands.
- **Pub.dev Timing**: Published packages take a few minutes to appear in search. Bump version and wait if not visible immediately.
- **Test Baseline Dates**: Test descriptions must follow format with date for proper CSV generation. Format: `ID: description [YYYY-MM-DD] (result)`

### Important Notes

**The `_ai/` Layer is ONE Clone:**
- `tom_agent_state` is cloned ONCE at workspace root `_ai/`
- All other `_ai/` mounts are relative symlinks
- Never `git clone` over a symlink or convert symlink to clone
- `tom_clone` and `tom_ensure_ai_link` own the layout

**Doc Placement Matters:**
- User docs go in `doc/`
- Developer docs go in `_agent_guidelines/`
- README.md always stays at project root
- Wrong placement breaks documentation generation

**Test Projects Are Excluded:**
- Anything prefixed with `zom_` is test-only
- Not included in production metadata
- Used for testing build tools and generators only

---

## Summary of Key Commands and Patterns

### Fleet Operations
```bash
/tom_pull              # Sync everything (all layers)
/tom_push              # Commit and push (all layers)
/tom_clone <dir>       # Bootstrap fresh workspace
/tom_full_reconcile    # Sync all machines (two-round)
```

### Daily Development
```bash
dart analyze           # Check for errors/warnings
dart test             # Run unit tests
testkit :test         # Run tests with baseline tracking
dart format .         # Format code
dart pub get          # Update dependencies
```

### Building Tools
```bash
buildkit -R --project <name> :pubupdate :versioner :compiler --targets darwin-arm64
buildkit -R --project <name> :pubupdate :versioner :d4rtgen :compiler --targets darwin-arm64
```

### Publishing Packages
```bash
dart pub publish --dry-run
dart pub publish
```

---

This comprehensive document covers all rules, constraints, and architectural patterns for the Tom Brain workspace. It serves as a reference for both AI assistants and human developers working within the system.
