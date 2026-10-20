# ADR 0032 — Worktree isolation for subagents, enter_worktree and exit_worktree

- Status: accepted
- Date: 2026-10-20
- Tags: agents, tools, git, permissions, sessions, claude-code
- karr: #168 (stream A3 of the Claude Code flow plan)

## Context

ADR 0027 §7 decided `isolation: "worktree"` for subagents and left it unimplemented. Claude
Code also lets the main conversation move into a worktree with `EnterWorktree` and leave it
with `ExitWorktree`; ADR 0027 §10 kept both unmapped. This ADR implements §7, settles what
§7 left open, and adds the two tools.

What Claude Code does (code.claude.com/docs/en/worktrees, tools-reference, sub-agents; the
tool texts of a current Claude Code session; read 2026-10-20):

- **`EnterWorktree`** (`name` or `path`, mutually exclusive): without `path` it creates a
  worktree under `.claude/worktrees/<name>` on a new branch (`worktree-<name>`; a name is
  generated when none is given; segments of letters, digits, `.`, `_`, `-`, separated by `/`,
  at most 64 characters) from the base of `worktree.baseRef`, and switches the session's
  working directory into it. It answers
  `Entered worktree at “P” on branch “B”. The session is now working in the worktree. …`.
  Creating a new one is refused while the session already works in a worktree; `path`
  switches into an existing worktree (it must appear in `git worktree list`), the previous
  one stays on disk untouched and only the new one is tracked for cleanup. A `path` outside
  `.claude/worktrees/` always asks the person — a permission rule or "don't ask again" does
  not suppress it, only `bypassPermissions` does.
- **`ExitWorktree`** (`action`: `keep` | `remove`, `discard_changes`): returns to the
  original directory. It only removes a worktree `EnterWorktree` created in this session
  (one entered by `path` can only be kept); outside a worktree session it is a no-op that
  says so. `remove` refuses a worktree with uncommitted files or commits not on the original
  branch and lists them unless `discard_changes: true`. Not available to subagents that run
  in their own worktree.
- **Session end**: a clean worktree is removed with its branch; one with work makes the
  person choose keep or remove. `-p` runs clean up nothing.
- **Base** (`worktree.baseRef`): `fresh` (default) the remote's default branch
  (`origin/HEAD`), falling back to the local `HEAD` when there is no remote or no cached
  `origin/HEAD`; `head` the current `HEAD` (inside a worktree: that worktree's `HEAD`).
  For `fresh` Claude Code fetches the default branch when the repository was not fetched for
  24 hours.
- **`.worktreeinclude`** at the repository root (`.gitignore` syntax): files that match a
  pattern *and* are gitignored are copied into every worktree Claude Code creates.
- **Isolation**: while a session works in a worktree, `Edit`/`Write`/`NotebookEdit` into
  the main checkout are refused, and Bash commands whose working directory or git target is
  the main checkout are refused. Hook processes keep `${CLAUDE_PROJECT_DIR}` at the project
  root; the hook input's `cwd` follows the worktree.
- Subagent worktrees: removed when the subagent made no changes, kept otherwise, locked
  while the agent runs; the Agent frontmatter field `isolation: worktree` makes an agent
  always run isolated.

## Decision

### 1. One module does the git work

`Langertha::Raider::Worktree` (internal, ADR 0017) creates, locks, unlocks, inspects and
removes worktrees with the `git` command line (no git library): `create` (path, branch,
base, `.worktreeinclude` copy), `lock`/`unlock`, `changes` (the `git status --porcelain`
lines and the commits on the branch beyond its base), `remove` (worktree and branch), and the
lookups `repository_top` (the main checkout: the parent of `git rev-parse --git-common-dir`,
so a root inside a worktree finds the same repository), `base_ref` and `list`. Every git call
runs with a fixed argument list (no shell) and reports failure as a value, never dies into
the caller's answer. Subagent isolation (§2) and the two tools (§4) share it.

### 2. Subagent isolation implements ADR 0027 §7, with these settlements

- **Where**: always under the main checkout's top (`<top>/.claude/worktrees/agent-ID` in the
  Claude layout, `<top>/.raider/worktrees/agent-ID` otherwise), also when the caller already
  works in a worktree — worktrees are never nested inside each other's directories.
- **Base**: `fresh` resolves to `origin/HEAD` when it exists, else the root's `HEAD` —
  Claude Code's current fallback, which replaces §7's chain through `init.defaultBranch`,
  `main` and `master`. raider does not fetch (no network side effect a person did not ask
  for). `head` is the caller's working root's `HEAD`, so a caller in a worktree hands its own
  state on.
- **`.worktreeinclude`** is honoured in both layouts (it is a file of the repository, not of
  the Claude layout): `git ls-files --others --ignored --exclude-from=.worktreeinclude`
  lists the candidates, `git check-ignore` keeps those the repository ignores, and each is
  copied to the same relative path. A missing file copies nothing.
- **Frontmatter**: an agent file's `isolation: worktree` makes every spawn of it isolated;
  the call's `isolation` parameter cannot turn it off. Any other frontmatter value is an
  error result at spawn time (`Agent 'x': isolation "V" is not supported; use "worktree".`),
  as an unsupported call value is.
- **Not mounted for isolated agents**: an agent running in its own worktree gets neither
  `enter_worktree` nor `exit_worktree` (§4 mounts them only in the main run anyway).
- **Resume** (`send_message`, ADR 0027 §5): the worktree is used again when it still
  exists; when it was removed, a branch that still exists is checked out into the same path;
  when both are gone it is created anew from the base, as at the start.
- **Ending**: every way a run of the agent ends — completed, failed, killed by `kill_shell`,
  cancelled with the application (leaving raider) or by a new conversation (`/clear`,
  ADR 0027 §3) — unlocks the worktree and applies §7's cleanup: no changes → worktree and
  branch removed; else kept. A kept worktree is named in the result (§2 of ADR 0027:
  `worktreePath: P` / `worktreeBranch: B`) and the notification (`<worktree>` element), and
  the registry entry of the agent (`Langertha::Raider::Tasks`) carries `worktree` and
  `branch`. A run cancelled without a notification (`/clear`, leaving raider) still cleans
  up; its kept worktree is named in a meta line instead (`agent agent_1 left its worktree P
  on branch B`).

### 3. The working root

The application gains a **working root**: the directory the file, search and shell tools
work in, the permission policy's root, the `cwd` of hook inputs and the `Working directory:`
line of the system prompt. It starts as the root. `enter_worktree` moves it into a worktree
(the same subdirectory of the worktree when the root is a subdirectory of the repository),
`exit_worktree` moves it back. Everything else stays at the root: the context and layout
(ADR 0019), settings and config, instructions and skills, the session store and journal,
the directory hook processes run in and `CLAUDE_PROJECT_DIR`. The copy has the same tracked
files, and the person's configuration should not change because the model changed
directories.

- Tools see the new working root from their next call on; a call already running finishes
  where it started. The current raid goes on (the tool result tells the model, §4); the
  next mission compiled shows the new working directory.
- Subagents spawned while the session works in a worktree start in the working root
  (inherit it), and an isolated one branches from it under `head` (§2).
- **Edits into the main checkout are refused** while the working root is a worktree — in
  the main run and in an isolated subagent alike: a `write_file`, `edit_file` or
  `multi_edit` whose target is inside the main checkout's top but outside every worktree of
  it is an error result `PATH is in the main checkout TOP; this session works in the
  worktree W. Edit W/REL instead.`, before any rule or mode is asked. Shell commands are not
  inspected (a deliberate difference: Claude Code's command-text checks for git redirects
  are not built); `bash` starts in the working root.

### 4. `enter_worktree` and `exit_worktree`

Two stock tools of the main run (depth 0), mounted next to `agent`; `ToolNames` maps
`EnterWorktree` → `enter_worktree` and `ExitWorktree` → `exit_worktree` (parameters
unchanged), so permission rules (`EnterWorktree`, `ExitWorktree`) and hook matchers name
them in Claude's spelling too. Both are effect class `write` (`ToolEffects`): one creates a
checkout and a branch, the other may delete them; the permission gate treats them like any
write tool (asked in `default`, allowed in `acceptEdits` and `auto`, refused in `plan`).

**`enter_worktree`** — `name` (optional) or `path` (optional), not both (error result
otherwise).

- Not inside a git repository → `enter_worktree needs a git repository; ROOT is not inside
  one.`
- **`name`** (or none): refused while the working root is a worktree
  (`Already working in the worktree W; pass path to switch to another one, or exit_worktree
  first.`). The name must match the Claude Code rule (segments `[A-Za-z0-9._-]+` joined by
  `/`, at most 64 characters), no `.` or `..` segment — the name becomes a directory); none given → `session-N` (a counter per application, as
  `agent_N`, skipping names whose directory or branch exists). The worktree is
  `<top>/.claude/worktrees/NAME` (Claude layout) or `<top>/.raider/worktrees/NAME`, branch
  `worktree-NAME`, from the base of §2; an existing directory or branch of that name is an
  error result (`Worktree NAME exists; pass path to enter it.`) — no silent reuse. It is
  tracked as *created by this session*.
- **`path`**: the absolute (or root-relative) path of a worktree listed by `git worktree
  list` of the repository, not the main checkout itself. Allowed while already in a
  worktree: the previous one stays on disk untouched and is no longer tracked; the new one is
  tracked as *entered*, never removed by raider. The previous one gets no `worktree.exited`. The path must equal a listed worktree; a subdirectory
  of the root that the entered worktree lacks falls back to its top. Entering the worktree
  that already is the working root answers `Already working in the worktree P; nothing
  changed.` (not an error; a created one stays tracked as created). A `path` outside `<top>/.claude/worktrees/`
  and `<top>/.raider/worktrees/` is asked about even when a rule or the mode would allow the
  call — only `bypassPermissions` skips the question; nobody to ask → refused. The question
  offers no session-wide answer (`for this session` counts once); a deny rule still refuses
  first, a hook `allow` does not skip it.
- Result: `Entered worktree at “P” on branch “B”. The session is now working in the
  worktree. Use exit_worktree to leave mid-session; when the session ends it is removed if
  unchanged and kept otherwise.` An entered worktree ends `… it was entered by path, so it stays on
  disk when the session ends.` instead.

**`exit_worktree`** — `action` (`keep` | `remove`, required), `discard_changes` (boolean).

- Not in a worktree → `No worktree session is active; nothing changed.` (not an error).
- `keep`: the working root returns to the root; result `Left the worktree P; it stays on
  branch B. Working directory: ROOT.`
- `remove` on an *entered* worktree → error result `P was entered by path, not created by
  this session; use action "keep".`
- `remove` with changes (§2's test) and without `discard_changes` → error result that lists
  the `git status --porcelain` lines and the number of commits beyond the base and ends
  `Pass discard_changes: true to remove it anyway.`; nothing changes. Otherwise the worktree
  is removed (`--force` with `discard_changes`) and the branch deleted; result `Removed the
  worktree P and its branch B. Working directory: ROOT.`
- A removal git refuses leaves the working root back at the root and reports
  `worktree kept: REASON` — the answer never dies.

### 5. Cleanup at a new conversation and at the end of the session

When the conversation is replaced (`/clear`, `/reset`, `/new`) and when the session ends
(REPL exit, `raider -p` finished, SIGTERM), a worktree *created* by `enter_worktree` that is
still the working root is closed as `exit_worktree` would: unchanged → removed with its
branch; with changes → kept, and a meta line names path and branch
(`worktree P kept on branch B (has changes)`). An *entered* one is only left. The working
root returns to the root. raider does not ask at exit (Claude Code does): the person is
leaving, and keeping work is the safe answer; removing clean worktrees is what Claude Code
does unasked. Background agents' worktrees are handled by their own ending (§2).

### 6. Journal

`worktree.entered` (`path`, `branch`, `created` boolean) and `worktree.exited` (`path`,
`branch`, `removed` boolean, `reason` — `exit_worktree`, `clear`, `session_end`) go to the
session journal. `agent.started` gains `worktree` and `branch`, `agent.finished`
`worktree_kept` (ADR 0027 §7).

## Deliberate differences from Claude Code

- No fetch for `fresh`; no `WorktreeCreate`/`WorktreeRemove` hooks (non-git VCS); no
  periodic sweep and no stale-lock sweep; no `--worktree` command-line flag; no pull-request
  bases.
- `enter_worktree`/`exit_worktree` exist in the main run only, not in subagents.
- A `name` whose worktree exists is an error, not a reopening.
- Shell commands are not inspected for git redirects into the main checkout (§3).
- A resumed session (`--continue`/`--resume`) starts at the root, not in the worktree it
  ended in; the journal events (§6) make returning there possible later.
- The session end does not ask keep/remove; it keeps what has work (§5).
- Default names are `session-N`, not generated words (predictable for scenarios).
- ACP and Hall sessions do not close a worktree at their end or at a new conversation, and a
  `raider -p` killed by a signal leaves it as it is (follow-ups on #168).

## Consequences

- The main run has two more tools; tool lists in prompts and golden tests grow.
- The file, search and shell tools and the permission policy read their root through the
  application's working root instead of a fixed value.
- ADR 0027 §7's base fallback chain, §10's "EnterWorktree, ExitWorktree stay unmapped" and
  ADR 0025's "unknown" row for them are superseded by §2 and §4.

## Source

Brief A3 (2026-10-20) of the Claude Code flow plan
(`perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md`), karr #168;
Claude Code documentation as cited above. Builds on ADR 0017, 0019, 0020, 0021, 0022, 0024,
0025, 0027.
