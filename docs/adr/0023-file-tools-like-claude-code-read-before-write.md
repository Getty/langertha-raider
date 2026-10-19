# ADR 0023 — File tools like Claude Code: texts, read before write, multi_edit, paths outside the root

- Status: accepted
- Date: 2026-10-19
- Tags: tools, claude-code, files, policy, security
- karr: #159 (stream D of the Claude Code flow plan, items 1, 2, 3, 4, 6 and 11 of the list on #156)

## Context

raider's file tools (`Langertha::Raider::FileTools`) answered in their own words:
`Wrote N bytes to P`, `Edited P`, `Error: old_string not found`, `Error: not a file: P`.
`read_file` returned the bare file, without line numbers, offset, limit or any cut, and read
images and binaries as text. `write_file` and `edit_file` changed any file, read or not. There
was no `MultiEdit`: `ToolNames` mapped the name, but the `edits` list went through unchanged and
`edit_file` failed. Every path outside the root and the additional directories was refused by
the tools ("Path escapes root"), in every layout.

Claude Code, which raider is to behave like in a Claude Code project (ADR 0019), answers
differently, and a model trained on it reads those answers. What it says, taken from its session
logs (`~/.claude/projects/*/*.jsonl`, about 4600 sessions) and from the strings of the installed
Claude Code 2.1.303 (and 1.0.98 for `MultiEdit`, which newer versions dropped):

- `Write`: `File created successfully at: P` / `The file P has been updated successfully.`,
  both followed by ` (file state is current in your context — no need to Read it back)` in
  current versions.
- `Edit`: `The file P has been updated successfully.` (+ the same note), with `replace_all`
  `The file P has been updated. All occurrences were successfully replaced.` Errors, each as a
  `<tool_use_error>…</tool_use_error>` error result: `No changes to make: old_string and
  new_string are exactly the same.`, `String to replace not found in file.\nString: X`, `Found N
  matches of the string to replace, but replace_all is false. To replace all occurrences, set
  replace_all to true. To replace only one occurrence, please provide more context to uniquely
  identify the instance.\nString: X`, `Cannot create new file - file already exists.`, and
  `File does not exist. Note: your current working directory is D.`
- Read before write: `File has not been read yet. Read it first before writing to it.` and
  `File has been modified since read, either by the user or by a linter. Read it again before
  attempting to write it.` (both `<tool_use_error>`). A read with offset/limit counts as read;
  what Write/Edit wrote counts as read; for a whole read a changed mtime with unchanged content
  is no change.
- `Read`: `N<TAB>line` (no padding, the empty piece after the last newline numbered too), 2000
  lines by default, `offset` 1-based; `<system-reminder>Warning: the file exists but the contents
  are empty.</system-reminder>`; `…is shorter than the provided offset (N). The file has M
  lines.`; `File does not exist. Note: your current working directory is D.` (plain error, `Did
  you mean X?` when a similar name exists); `EISDIR: illegal operation on a directory, read
  'P'`; `File content (399.6KB) exceeds maximum allowed size (256KB). Use offset and limit
  parameters …`; binaries by extension list `This tool cannot read binary files. The file appears
  to be a binary .X file. …`; images as image blocks, PDFs as `PDF file read: P (SIZE)` plus a
  document, notebooks as `<cell id="…">…</cell id="…">` with outputs.
- `MultiEdit` (1.0.98): `Applied N edits to P:\n1. Replaced "…" with "…"`, strings cut at 50
  characters; `Original and edited file match exactly. Failed to apply edit.`
- Paths: Claude Code reads and writes anywhere its permissions allow. Outside the working
  directories it asks (`Claude requested permissions to read from P, but you haven't granted it
  yet.`), `acceptEdits` accepts edits only inside them, `bypassPermissions` allows everything,
  allow rules like `Read(//tmp/**)` open a place.

Langertha (core) carries MCP `image` content natively in a tool result on the `anthropic`,
`responses` and `gemini` wires when `supports('image_input')` is true for the model; elsewhere it
sends a placeholder `[image] image/png (N bytes)`. A PDF resource blob becomes a document block
on Anthropic and rides natively on Responses/Gemini for image-input models.

## Decision

### 1. Texts and error flags are Claude Code's

`write_file`, `edit_file`, `read_file` and the new `multi_edit` answer with the texts above,
verbatim, with the same error flag and the same `<tool_use_error>` frame where Claude Code puts
one (validation failures; `File does not exist` from Read, `EISDIR` and the size limit are plain
error results). Where Claude Code names a path or the working directory, raider names the
absolute real path and the root. The parameter is `path`, as before (`ToolNames` maps
`file_path` for hooks and rules); the texts say `path` where Claude Code says `file_path`.
Write and Edit append Claude Code's current note `(file state is current in your context — no
need to Read it back)`: it is true in raider too, see §2. The old texts are gone.

`list_files` has no counterpart in current Claude Code (`LS` was dropped); it keeps its output
and gets Claude-style errors: `Directory does not exist. Note: your current working directory is
D.` and `P is a file, not a directory. Use read_file to read it.`

### 2. Read before write, per run

`Langertha::Raider::FileTools::ReadState` records, per real absolute path, the mtime
(sub-second), the size and — for a whole read — the SHA-256 of the bytes. `write_file`,
`edit_file` and `multi_edit` on an **existing** file ask it first: never read in this run →
`File has not been read yet…`; mtime or size changed since and (for a whole read) the bytes
differ → `File has been modified since read…`. A new file needs no read. A `read_file` with
offset/limit, a cut read, an image/PDF/notebook read count as read (as in Claude Code); the
tools' own writes record what they wrote, so edits follow each other without a new read. An
empty `old_string` on a missing file creates it, on an empty file fills it (no read needed, as
in Claude Code).

The state is **per run**: `Application::begin_run` empties it (next to the todo list), the
application hands it to the file tools (`read_state`), and `file_read_state` exposes it. The
prompt builder records the instructions file it shows the model in its mission, so its
`write_file` works (Claude Code seeds files it put into context the same way).

A **subagent** (ADR 0020) starts with a read state of its own, empty: its file tools are a
server of their own over it (`Subagent->file_read_state`), so a file the caller read counts
as unread until the subagent reads it, and a file the subagent changed counts as modified
for the caller. Claude Code does the same for a subagent with a fresh context — it clones
the parent's state only for a forked agent, which inherits the conversation that saw the
files; raider has no forked agents.

It holds in **both layouts**. The file tools are the same in the Claude and the raider layout;
a second, looser set of semantics for the same tool name would make results depend on a file the
model cannot see. Writing a file the model has not seen is the mistake the rule exists for, in
any project.

### 3. read_file

`read_file(path, offset, limit, pages)`: `cat -n` form as above (tab separator, CR at line end
dropped), at most 2000 lines unless `limit` is given, a line over 2000 characters cut with `...
[truncated]`. When the default cut hides lines, a note in Claude Code's `[Truncated: PARTIAL view
— P: showing lines 1-2000 of N total. Call read_file with offset=2001 limit=2000 for the next
page, or grep …]` form follows. Without offset and limit a file over 256 KB is refused with
Claude Code's text. Bytes are decoded as UTF-8 with replacement characters; a NUL byte in the
first 8 KB, or an extension on Claude Code's binary list, is refused with its binary text;
devices, FIFOs and sockets with its device text.

**Images and PDFs.** PNG, JPEG, GIF, WebP come back as MCP `image` content (at most 3.75 MB, 5 MB
in base64), PDFs as `PDF file read: P (SIZE)` and a `resource` blob of type `application/pdf`
(at most 32 MB) — but only when the active engine says so itself: `supports('tool_result_images')`
for images, `supports('tool_result_pdf')` for PDFs (Langertha ADR 0039; two questions, a model can
take one and not the other; `Application::_engine_sees_images` / `_engine_reads_pdf`, asked on every
call, so `raider_switch_engine` is followed). Raider no longer guesses from the wire name. Otherwise an error result `This model
cannot see images: P was not read. Use a model that can read images, or a shell command or script
that can describe or convert the file.` (`… see PDF files …`). A placeholder the model cannot
look at is worse than a clear refusal. **Notebooks** (`.ipynb`) come back as Claude Code shows
them: `<cell id="…"><cell_type>markdown</cell_type>…</cell id="…">` (code cells without the
tag, `<language>` when not python), the text of the outputs after each cell, output images as
image content when the model sees images; invalid JSON or a non-notebook gets Claude Code's
notebook texts.

The tool descriptions follow Claude Code's (lean) Read/Write/Edit prompts, adapted to `path`
and to raider's tool names.

### 4. multi_edit

`multi_edit(path, edits: [{old_string, new_string, replace_all?}, …])`, Claude Code's
`MultiEdit`: the edits are applied one after the other to the content in memory, each to the
result of the one before, with `edit_file`'s rules and texts; **atomic** — the first failing edit
ends the call and nothing is written: `<tool_use_error>Edit I of N failed, no edit was applied:
<edit_file's text></tool_use_error>`. An empty `old_string` is allowed only in the first edit, on
a missing or empty file (creates it). Edits that cancel out give Claude Code's `Original and
edited file match exactly…`. Read before write holds. The result is Claude Code's `Applied N
edits to P:` list plus the file-state note.

`ToolEffects`: `multi_edit => [write]`. In the policy it is a writing file tool everywhere
`write_file`/`edit_file` are: `Edit(...)`/`Write(...)`/`MultiEdit(...)` rules (`@WRITERS` in
`Rule.pm`, `multi_edit` accepted as a rule name), `acceptEdits`/`auto` inside the roots, the
plan-mode refusal (by its `write` effect), the suggested session rule `Edit(DIR/**)`, the ACP
permission kind `edit`, the `how to allow` hint. `ToolNames` maps `MultiEdit → multi_edit` with
`file_path ↔ path` (worker C); the hooks' file-tool list knows it.

### 5. Paths outside the root: the gate decides in the Claude layout

In the **Claude layout** (`context->mode eq 'claude'`) the file and search tools are no longer
confined; the policy decides before them. The policy gets `ask_outside_roots` (set by the
application from the layout, carried by `for_subrun` and `from_sources`, part of
`policy_revision`). With it, a call of `read_file`, `list_files`, `write_file`, `edit_file`,
`multi_edit`, `glob` or `grep` whose path — as written, or as real path with symlinks of its
nearest existing ancestor followed (`Permissions::outside_paths`) — leaves the root and the
additional directories:

- deny rules first, then `bypassPermissions` allows it (Claude Code's bypass), then the plan-mode
  refusal of changes, then ask rules, then **allow rules** (`Read(//tmp/**)`, `Read(~/x/**)`,
  `Edit(//abs/**)` — the existing rule syntax), and then, before the mode would allow a read or
  an `acceptEdits`/`auto` edit, it **asks**: `MODE mode asks before this call: read_file
  requested permissions to read from P, which is outside the project root and the additional
  directories, but you haven't granted it yet` (`write to` for changes). This holds in `default`,
  `acceptEdits`, `auto` and `plan` (reads; changes are refused in plan before). `acceptEdits`
  does **not** take edits outside the roots — Claude Code's acceptEdits covers the working
  directories only, and ADR 0021 already said so for raider.
- The suggested session rule is `Read(//DIR/**)` (the file's directory for `read_file`, the
  directory itself for the others) or `Edit(//DIR/**)`; nobody to ask → refused with the rule,
  where to put it, "add the directory to additionalDirectories", `--permission-mode
  bypassPermissions`.
- A symbolic link inside the root that points out of it is outside: the policy holds the real
  path, so a link cannot pass the gate as an inside path. A `once` approval is bound to the exact
  call (ADR 0021).
- `hides_read` (search results under a read rule) leaves the outside check out
  (`decide(..., skip_roots => 1)`): a search the gate let into a directory shows what it finds
  there, only rules hide.

`build_file_tools_server` and `SearchTools` take `confine` (default true; a value or a CodeRef
asked per call). The application passes `sub { !$app->permissions->ask_outside_roots }`, so the
tools and the policy can never disagree — `reload_context` rebuilds the policy from the new
layout. Library users keep the confined tools unless they turn `confine` off, and must then put
a gate in front. In the **raider, native and bare layouts nothing changes**: the tools refuse
every path outside (`Path escapes root`), in every mode, also `bypassPermissions`.

### Deliberate differences from Claude Code

- **Read state per run, not per session.** Claude Code keeps it for the conversation (cleared on
  `/clear`, re-seeded after compaction). raider empties it in every `begin_run`: what is known
  about a file never outlives the run that learned it, also across `--continue`/resumed
  sessions, where nothing could carry it anyway. Cost: after a new prompt the model reads the
  file again before editing it.
- **Read before write in every layout**, not only the Claude one (§2).
- **Files in the prompt are seeded as read** (addendum below); nested `CLAUDE.md` files that a
  tool result brings in are not.
- **Size check on mtime and size, plus the hash for a whole read.** Claude Code compares the
  mtime (and the content for whole reads); raider also takes a changed size as a change.
- **Token limit by estimate** (addendum below): 25000 tokens as Claude Code, counted as bytes
  divided by four — there is no tokenizer here; the 256 KB limit, the 2000-line cut and the
  2000-character line cut remain. The line cut is marked `... [truncated]` (Claude Code
  documents the cut but its marker is not observable).
- **PDF `pages` returns text, not page images** (addendum below). No image resizing: an image
  over 3.75 MB is refused.
- **Images and PDFs only for a model and wire that carry them**, else a refusal (§3); Claude Code
  always sends them. Which `/anthropic` shims drop images (AKI) is a private predicate of core; a
  public capability for "images in tool results" is a follow-up for the langertha board.
- **No curly-quote normalisation** in `edit_file` (Claude Code matches `'` against `’`), no
  "Did you mean" for a path under a mistyped working directory, `Did you mean` names the full
  path.
- **`.ipynb` can be edited with `edit_file`/`multi_edit`** (raider has no NotebookEdit; Claude
  Code refuses and points to NotebookEdit).
- **`multi_edit` applies edits to the result of the previous ones** and does not refuse an
  `old_string` that a previous `new_string` produced (Claude Code 1.0.98 validated every edit
  against the original file and refused that case); the error names the edit's number.
- **Relative paths** are allowed and read against the root (Claude Code demands absolute
  paths).

## Consequences

- **Incompatible:** the result texts of the file tools changed (§1); `read_file` returns
  numbered lines (a caller that wants the bare file reads it with `bash cat`); `write_file`,
  `edit_file` on an existing file fail until it was read in the run; in the Claude layout a path
  outside the root is asked about (refused without a person) instead of refused by the tool, and
  `bypassPermissions` reaches it.
- Scenarios and tests that changed existing files without reading them read them first now
  (`t/scenarios/07`, `79`, `log-01`, `log-11`, `log-12`); new scenarios 110–118, tests t/190–192.
- Follow-ups: a core capability for tool-result images; sub-agents (stream A) share the
  application's read state unless they get their own — to decide with ADR for sub-agents.
  (Seeding context files and PDF pages: addendum below.)

## Addendum (k163): token limit, PDF pages, seeded files, one confinement

**Token limit.** A `read_file` of text whose result is over 25000 tokens is refused with Claude
Code's `File content (N tokens) exceeds maximum allowed tokens (25000). Use offset and limit
parameters to read specific portions of the file, or search for specific content instead of
reading the whole file.` (`isError`, no `tool_use_error` frame), whole file or part, and does not
count as read. N is the UTF-8 byte length of the numbered text divided by four, rounded up:
Claude Code estimates the same way when no tokenizer is at hand, and a tokenizer would be a
dependency for a limit that only has to be about right. The 256 KB check for a whole read stays
in front of it; since 25000 tokens are about 100 KB the token limit is what usually decides.
No environment override (Claude Code has one); a decision for later if someone needs it.

**PDF pages.** `read_file(path, pages)` with `pages` `"N"`, `"N-M"` or `"N-"` (1-based) at most 20
pages per request; the formats, the `Invalid pages parameter: …` text and the `Page range … exceeds
maximum of 20 pages per request. Please use a smaller range.` text are Claude Code's, framed as
`tool_use_error`. Decision: the pages come back as **text from `pdftotext -layout`** (poppler),
headed `PDF pages F-L of P:` and `Page N:` per page — Claude Code renders them to images with
`pdftoppm`. Text works for every model, also one that cannot see images, needs one program and
costs far fewer tokens; a scanned PDF without a text layer returns empty pages, for that the
model uses `bash`. The result is subject to the token limit and counts as a partial read.
Without `pdftotext` the call is refused saying so and naming `poppler-utils`; nothing falls back
to sending the whole file. Programs are looked up on `PATH` at each call (`File::Which`) and run
with `IPC::Run`; nothing poppler is a dependency of the dist. Without `pages`, a PDF over 10
pages (counted by `pdfinfo`, when it is there) is refused with Claude Code's `This PDF has N
pages, which is too many to read at once. Use the pages parameter …`; without `pdfinfo` there is
no count and no refusal, the PDF is sent whole up to 32 MB as before.

**Seeded as read.** `Application::begin_run` now records, after emptying the state, every
instructions file of the prompt (`Context::instruction_items`: the `CLAUDE.md` hierarchy,
`CLAUDE.local.md`, `AGENTS.md`) with the bytes on disk, as Claude Code counts a `CLAUDE.md` it
injected as read. They count as whole reads: a later change on disk is still caught. A file with
`@import`s is recorded by its own bytes (the prompt shows the expanded text; Claude Code marks
such a view as partial, we do not care to). The prompt builder's own record (§2) stays. Not
seeded: nested `CLAUDE.md` files handed out by the `NestedMemory` plugin, and everything for a
subagent (its state is its own and empty, §2). Outside the Claude layout and in `--bare` the
prompt carries no such files and nothing is seeded.

**One confinement.** `FileTools` and `SearchTools` each carried a copy of the root,
additional-directories and `confine` logic. `Langertha::Raider::PathConfine` is that logic once
(`allows($real)`, `confined`, `real_extra_roots`); both tools build one over the same three
arguments, so they cannot disagree. Behavior is unchanged, including the one difference the copies
had: search tools take an additional directory only if it is a directory (`dirs_only`).

Tests t/235–t/239, scenarios 165–169.

## Source

The logs and binaries named above; plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md`
(stream D); ADR 0021 (modes, rules, additional directories), ADR 0019 (layout), ADR 0018 (tool
names, effects), ADR 0025 (MultiEdit name mapping).
