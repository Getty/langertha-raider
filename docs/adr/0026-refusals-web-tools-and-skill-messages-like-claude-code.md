# ADR 0026 — Refusals, web tools and skill messages like Claude Code

- Status: accepted
- Date: 2026-10-19
- Tags: tools, policy, skills, web, claude-code, sessions
- karr: #159 (stream D, tool parity; items 8, 9 and 10 of the list on #156)

## Context

Stream L replayed real Claude Code sessions against raider (karr #156) and listed where
raider answers differently. Three items are this ADR's:

- **8.** `web_fetch` ignored Claude Code's `prompt` (WebFetch puts a question about the page
  to a small model and returns the answer); `web_search` had no `allowed_domains` /
  `blocked_domains`.
- **9.** Claude Code's Skill tool returns only `Launching skill: NAME`; the skill itself
  arrives as a user message of its own. raider returned the body as the tool result.
- **10.** Refusals were worded by raider ("The user refused this call …", "… was denied:
  …") and a refused plan was a normal result; Claude Code words them differently, and a
  refused plan is an error result.

The words below were taken from the tool results of the local Claude Code sessions
(`~/.claude/projects/*/*.jsonl`, `is_error` included), not guessed; where the logs have no
example the ADR says so.

## Decision

### 1. Refusals

The application's gate (ADR 0021) now words the whole result itself: its verdict carries
`message`, and `Langertha::Raider::_gate_refused_tool_result` uses it as it stands (a gate
without `message` — a library gate, a hook's deny — is worded by the raider as before).
`reason` stays raider's own sentence and is what `permission.denied` reports, except for the
person's no, where it is the text the model got (as before).

| Case | Text (error result in every case) |
|---|---|
| the person says no | `The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.` — exactly Claude Code |
| … with a reason | the same up to `file). ` then `To tell you how to proceed, the user said:\n<reason>` — exactly Claude Code |
| a deny rule, a mode that refuses (plan mode) | `Permission to use <tool>[ with command <cmd>] has been denied.` then ` Reason: <raider's reason>.` |
| an ask nobody can approve | the same sentence, then ` Reason: <reason>; nobody can approve it in this run. To allow it, add a rule such as '…' to … or run raider with --permission-mode …. Do not retry the same call; go on without it or say what you need.` |

**Claude Code's sentence first, raider's reason after.** The model reads first what it
knows from Claude Code — the call did not run — and then what only raider can tell: which
rule from which file, or the rule and file that would allow it. Dropping raider's part would
lose the way out (`_how_to_allow`); putting it first would make the start of every refusal
differ from Claude Code's. `Permission to use Bash with command … has been denied.` is the
form of all 42 refusals of that kind in the logs (every one a Bash call); for other tools the
`with command` part is left out — the logs have no example of them. None of these texts has
the `<tool_use_error>` frame, in the logs or here; the frame belongs to Claude Code's input
checks (ADR 0023), which §2, §5 and §6 use where Claude Code does.

### 2. `exit_plan_mode`

| Case | Text | isError |
|---|---|---|
| approved | `User has approved your plan. You can now start coding. Start with updating your todo list if applicable\n\nThe permission mode is now default.\n\n## Approved Plan:\n<plan>` | no |
| refused (with or without feedback) | the person's no of §1, with the feedback as the reason | **yes** |
| nobody can review | `Permission to use exit_plan_mode has been denied. Reason: nobody can approve the plan in this run. Stay in plan mode and give the plan as your final answer.` | **yes** |
| not in plan mode | `<tool_use_error>You are not in plan mode. To enter plan mode, call the enter_plan_mode tool first. If your plan was already approved, continue with implementation.</tool_use_error>` — Claude Code's, frame included | yes |

The approval keeps Claude Code's first paragraph and its `## Approved Plan:` block word for
word; Claude Code's `Your plan has been saved to: …` paragraph is replaced by the mode line,
since raider does not save plans to a file. A refused plan is an error result as in Claude
Code (it uses the general rejection for every tool, ExitPlanMode included; the logs show no
refused plan, the general text is in them).

**Nobody can review: an error result.** The call did not do what it asks for — leave plan
mode — and every other call that needs someone's approval and finds nobody is an error
result too (§1). The text still tells the model what to do (give the plan as the final
answer), so the run ends the same way as before; only the flag is now consistent.

**Not in plan mode** names `enter_plan_mode`, which ADR 0025 mounts always.

### 3. Tool names in the texts

The texts name raider's tools — `bash`, `write_file`, `exit_plan_mode`, `web_fetch` — in
every layout. Those are the names the model sees and can call; Claude Code's names
(`Bash`, `WebFetch`) would name tools that do not exist in the request. Rule *syntax* keeps
Claude Code's names (`Bash(rm:*)`), as ADR 0021 decided.

### 4. `web_fetch(url, prompt?, as_html?)`

- **`prompt`.** With a prompt the page (HTML flattened to text, or raw with `as_html`), cut
  at `max_prompt_chars` (100 000 characters, Claude Code's limit) with a note, goes between
  `---` lines, followed by the prompt and a short instruction to answer from the content
  only, as **one user message** to a model call of its own; the tool returns that answer and
  nothing else. The page never enters the raid's conversation. Without a prompt (or with an
  empty one) the tool answers as before (URL, status, content type, body). `prompt` stays
  optional: raider's model has used `web_fetch` without it, and the raw page is still the
  better answer for some calls.
- **The model.** The run's own engine and model, unless `web_fetch_model` is set (a raider
  key in `.raider/config.yml`, the home config, an engine section, or `-o
  web_fetch_model=`): then the same engine class, provider and key with that model
  (`Application->web_fetch_engine`, the resolver cloned with the model). No automatic
  "small model": a guessed name may not exist on a proxy or a self-hosted server, and
  raider's default models are already the cheap ones (`claude-haiku-4-5`, `gpt-4o-mini`).
- **The loop.** The tool runs the call on the application's loop like its HTTP request (ADR
  0016); the web tools take it as an `answer` callback returning a Future, so
  `Langertha::Raider::WebTools` stays free of engines.
- **Tokens.** Each such call is the event `model.usage` (`purpose` `web_fetch`, `model`,
  `input_tokens`, `output_tokens`), in the journal and on every `on_event`. It is not added
  to the raider's metrics or to the Trace plugin's `/stats` (follow-up).
- **Redirects.** Followed (up to 10) only on the same host (`www.` aside), scheme and port
  and without credentials, as Claude Code does. One that leaves is not fetched; the result
  is Claude Code's `REDIRECT DETECTED: …` text with raider's tool name and the prompt to
  repeat — no error result. The reason is the same as Claude Code's and matters more for
  raider: `WebFetch(domain:…)` rules decide on the URL of the call, and a redirect followed
  behind their back would reach a host no rule was asked about. (It also makes the http →
  https hop of k109 impossible: a scheme change is never followed.)
- **Not a success.** `The server returned HTTP <status line>.\n\nThe response body was not
  retrieved. If this URL requires authentication, use an authenticated tool (e.g. `gh` for
  GitHub, or an MCP-provided fetch tool) instead of web_fetch.` — and, as in Claude Code, no
  error result (all 21 such results in the logs have none). Network failures, timeouts and
  a model call that fails stay error results (`Error: …`).

### 5. `web_search(query, limit?, allowed_domains?, blocked_domains?)`

Lists of domains; a domain covers its subdomains, an entry written as a URL or `*.x` is
reduced to its host. The filter on the results is the guarantee. It also goes into the
query where every provider understands it — `site:` for a single allowed domain, `-site:`
for each blocked one — and three times `limit` results (at most 50) are asked for, so
filtering still leaves some. Both lists at once: the error result `<tool_use_error>Error:
Cannot specify both allowed_domains and blocked_domains in the same request</tool_use_error>`
(Claude Code's wording as its tool states it, in the frame of its input checks; the logs have
no example), and nothing is searched.

### 6. The skill is a user message after the tool results

- **Result.** `skill` returns `Launching skill: NAME` (Claude Code's text). The skill text —
  `Base directory for this skill: DIR`, the body, `$ARGUMENTS` (ADR 0019 §4) — goes under
  the key `raider/messages` of the result's `_meta`, MCP's place for data beside a result.
  An unknown name is `<tool_use_error>Unknown skill: NAME. Available skills: …</tool_use_error>`
  (Claude Code's text and frame, then raider's list of the available skills).
- **A general mechanism of the raider.** `Langertha::Raider` adds every string a result
  hands over this way as `{ role => 'user', content => … }` after the batch's tool results,
  in the order of the calls — in the first run of a batch and on `respond_f` alike. It is
  not skill-specific: any of raider's own tools may use it.
- **Only raider's own sources.** A result of a `catalog:NAME` MCP server loses the key
  before any plugin sees it: a foreign server must not put words in the user's mouth. The
  engine's MCP servers and inline tools are raider's own, as for the permission policy
  (ADR 0021, `source_servers`). This is Claude Code's line too: only its built-in tools
  can add messages, MCP tools cannot.
- **Wire form: a separate user message.** Langertha builds the tool results per wire
  (`format_tool_results`): Anthropic and Gemini one user message with all results, OpenAI,
  Ollama, Hermes and Responses one message or item per result. A text block inside the
  Anthropic tool-result message would be valid there only; a user message of its own after
  the results is valid on every wire — OpenAI-style APIs take a user message after tool
  messages, and Anthropic combines consecutive user turns into one (which is what Claude
  Code sends: its skill message merged after the `tool_result` blocks). It is the form
  `inject` already uses after a tool exchange.
- **Compaction.** The message is not part of its tool exchange: in-raid compaction (k89)
  drops the exchange (`Launching skill: …`) and keeps the message, as it keeps injections —
  the instructions outlive the call that loaded them, as in Claude Code, which re-attaches
  invoked skills after compacting. Nothing is orphaned: the exchange goes as a whole unit,
  the message needs no partner. Between raids the message is in `history` like any user
  message, so `compress_history_f` summarises it with the rest.
- **History.** The message is kept in `history` (with the user input and the answer, where
  injections go) and in `session_history`. Before, the body vanished with the tool results
  at the end of the raid, and the next raid had to load the skill again; now the
  conversation keeps it, as Claude Code's does.
- **Journal and resume.** The Events plugin reports each such message as a `message` event
  (role `user`) right after its `tool.result`, so the journal (ADR 0015) has it there, and
  `history_messages` replays it on resume between the input and the answer — the place it
  has in the live `history`. The machine stream does not show it (user messages are not
  streamed, ADR 0013); `raider sessions show` lists it as a user message.

## Deliberate differences from Claude Code

- **raider's reason after Claude Code's sentence** (§1): the rule and file that refused, or
  how to allow the call. Claude Code says only the sentence.
- **raider's tool names in the texts** (§3).
- **The approved plan names the mode, not a plan file** (§2).
- **`web_fetch` without `prompt` still returns the page** (§4), and with a prompt but no
  answer callback (a library use of the web tools) too. Claude Code requires the prompt.
- **No automatic small model** for `web_fetch` (§4); `web_fetch_model` chooses one.
- **No http → https upgrade, no cache, no preapproved-domain shortcut** in `web_fetch`, and
  HTML is flattened to text, not converted to Markdown.
- **`web_search` keeps its own result format** (numbered title, URL, snippet); only the
  domain filters are Claude Code's.
- **Unknown skill lists the available skills** after Claude Code's sentence.

## Consequences

- **INCOMPATIBLE** for anything that matched the old texts: "The user refused this call",
  "Tool call 'X' was denied: …" from the application's gate, "User approved the plan",
  "The user did not approve the plan", "Nobody can approve the plan" (now an error result),
  "exit_plan_mode: not in plan mode", a `skill` result carrying the body, "Error: unknown
  skill", a `web_fetch` HTTP error as an error result, and a cross-host redirect that was
  followed. ADR 0021 §6 and §8 quote the old texts; they are superseded here.
- A session journal now holds the skill body as a user `message`; a resumed or forked
  session carries the skill on. Older journals (body in `tool.result`) replay as before.
- `model.usage` is a new journal event type (no new journal version, ADR 0015).
- Packing: nothing new is loaded by name; `URI` was already a dependency.
- Tests: t/203 (refusal and plan texts), t/204 (web_fetch prompt, redirects, status texts,
  the engine and `model.usage`), t/205 (web_search domains), t/206 (messages after tool
  results: order, history, compaction, respond, foreign sources, journal and resume);
  scenarios t/scenarios/130–135; `Test::Raider::LocalHTTP` serves pages to scenarios
  (`http:` key) and tests on the application's loop.

## Follow-ups

- `model.usage` in the raider's metrics and in `/stats` (Trace plugin).
- The skill message after compaction *between* raids: Claude Code re-attaches invoked
  skills after a compaction; raider's summary may shorten them.
- A hook's deny (PreToolUse) is still worded by the raider ("Tool call 'X' was denied:
  PreToolUse hook: …"); Claude Code hands the hook's reason through as it stands.

## Source

karr #159 (stream D) and the deviation list of #156 (stream L); the wording from the local
Claude Code session logs. Complements ADR 0019 (skills), ADR 0021 (permissions, plan mode),
ADR 0015 (journal) and ADR 0016 (one loop).
