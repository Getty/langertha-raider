# ADR 0017 — Public API inventory and the internal marker

- Status: accepted
- Date: 2026-09-29
- Tags: api, stability, naming, distribution

## Context

The redesign recuts internal modules in small slices (`Application`, the CLI classes,
`Hall`, `Raider.pm` itself). Before that starts, it must be clear which names other
distributions and users may rely on and which ones a slice may change freely. Until now
nothing said so. POD exists for almost every module, and so POD alone does not separate
public from internal.

The code at `ef7dd92` already carries one signal. Fifteen modules open their DESCRIPTION
with `B<Internal module.> Its interface may change without notice.` and start their
`# ABSTRACT` with `Internal`. Several other modules are just as internal but carry no
such marker.

Known outside consumers: `langertha-knarr` (`Handler::Raider`: `Langertha::Raider->new`,
`raid_f`, `Langertha::Raider::Result`) and core's two soft references (ADR 0001). The
packages `Langertha::Raider`, `Langertha::Raider::Result` and `Langertha::Raid*` were
indexed on CPAN as part of `Langertha` up to 0.502. The six `App::Raider*` names were
indexed as part of `App-Raider`.

## Decision

### The rule

1. **A package is public** when it appears in the public list below. A package whose
   `# ABSTRACT` starts with `Internal` and whose DESCRIPTION opens with
   `B<Internal module.>` is internal. Its POD is documentation for maintainers, not a
   promise. A reserved stub (ADR 0001) is neither: it has no API.
2. **Inside a public package, a name is public** when it is not `_`-prefixed and the
   package's own POD documents it: an `=attr` / `=method` / `=func` entry, or a mention
   by name in SYNOPSIS or DESCRIPTION. Moose-generated predicates, clearers and writers
   are public only where the POD names them. A `_`-prefixed name is private even when
   the attribute it belongs to is public.
3. **Inherited contracts stay with their owner.** Names a public package gets from core,
   such as `plugins` / `plugin_args` (`Role::PluginHost`), `run_f` (`Role::Runnable`) and
   the plugin hooks (`Langertha::Plugin`), are public under core's documentation.
4. **Everything else is internal** and may change in any slice without deprecation: every
   name in an internal package, every undocumented name, and every `_` name.
5. **Changing a public name is deliberate.** `Changes` says so. A public package that
   was ever indexed and is then renamed leaves a stub behind (ADR 0001).
6. **New packages start internal.** They carry the internal marker until an ADR adds them
   to the public list.
7. **Wire and file formats are public no matter where they are implemented.** An internal
   module does not make its format internal. These are public: the `raider` command line
   and exit status, the machine output (ADR 0013), the session journal (ADR 0015), the
   config files (`.raider.yml` / `.raider.md` legacy, `.raider/`, ADR 0011;
   `.raider-hall.yml`, `Hall` POD "CONFIG FILE"; `pack.yml`, ADR 0012), the tool names the
   model sees, and the environment variables raider reads.

### Public packages

| Package | Public surface (documented, not `_`) |
|---|---|
| `Langertha::Raider` | The engine and `main_module`. Attributes: `engine`, `mission`, `history`, `max_iterations`, `max_context_tokens`, `context_compress_threshold`, `compression_prompt`, `compression_engine`, `session_history`, `on_iteration`, `metrics`, `langfuse_trace_name` / `_user_id` / `_session_id` / `_tags` / `_release` / `_version` / `_metadata`, `raider_mcp`, `on_ask_user`, `on_pause`, `on_wait_for`, `cancel_requested`, `tools`, `mcp_catalog`, `engine_catalog`, `embedding_engine`, `no_session_embeddings`, `plugins`. Methods: `raid` / `raid_f`, `respond` / `respond_f`, `cancel`, `clear_cancel`, `clear_history`, `clear_session_history`, `add_history`, `add_session_history`, `inject`, `reset`, `active_engine`, `active_engine_name`, `switch_engine`, `reset_engine`, `override_engine` (ADR 0030), `engine_info`, `list_engines`, `add_engine`, `remove_engine`, `compress_history` / `compress_history_f`, `register_session_history_tool`; `run_f` through `Role::Runnable`. Plugin hooks `plugin_before_raid`, `plugin_build_conversation`, `plugin_after_raid` (contract in core's `Langertha::Plugin`). A tool result.s `_meta` key `raider/messages` (user messages after the tool results, ADR 0026). |
| `Langertha::Raider::Result` | `type`, `text`, `content`, `options`, `data`, `context`; `is_final`, `is_question`, `is_pause`, `is_abort`, `is_cancelled`, `has_text`, `as_hash`, `with_context`; constructors `final`, `question`, `pause`, `abort`, `cancelled`; `""` overload to `text`, `bool` always true. |
| `Langertha::Raid` | `steps`, `name`, `run_f`. |
| `Langertha::Raid::Sequential` | `run_f`. |
| `Langertha::Raid::Parallel` | `merge_slot`, `run_f`. |
| `Langertha::Raid::Loop` | `max_loops`, `max_iterations`, `continue_while`, `run_f`. |
| `Langertha::Raider::CLI` | The CLI as a Perl class (ADR 0001). Its own: `trace`, `trace_out`, `source_labels`, `persona_intro`, `persona_turn_end`, `ignored_agent_files`, `trace_plugin`, `token_stats`, `default_model_for_engine`. Also the names documented in `Langertha::Raider::Application`, **when called on a `Langertha::Raider::CLI`**, because the CLI POD promises them (see Consequences). |
| `Langertha::Raider::FileTools` | `build_file_tools_server` (`@EXPORT_OK`); tools `list_files`, `read_file`, `write_file`, `edit_file`. |
| `Langertha::Raider::WebTools` | `build_web_tools_server` (`@EXPORT_OK`); tools `web_search`, `web_fetch` (with `answer` for its `prompt`, ADR 0026). |
| `Langertha::Raider::PerlTools` | `build_perl_tools_server` (`@EXPORT_OK`); tools `perl_eval`, `perl_check`, `perl_cpanm`. |
| `Langertha::Raider::HallTools` | `build_hall_tools_server` (`@EXPORT_OK`); tools `telegram_reply`, `hall_status`, `hall_spawn`. |
| `Langertha::Raider::Plugin::Situation` | The plugin itself (no attributes). |
| `Langertha::Raider::Plugin::Trace` | `color`, `out`, `max_value_length`, `token_stats`, `loop`. |
| `Langertha::Raider::Plugin::Events` | `on_event`. |
| `Langertha::Raider::Skill` | `app`, `name`, `description`; `markdown`, `claude_skill`, `write_markdown`, `write_claude_skill`, `legacy_claude_skill`. |
| `Langertha::Raider::Packs` | `build_packs` (`@EXPORT_OK`). |
| `Langertha::Raider::Packs::Collection` | `sources`, `switched_off`, `detections`, `skipped_packs`; `enable`, `disable`, `toggle`, `enable_detected`, `activation_report`, `skill_texts`, `requested_tools`, `active_pack_names`, `is_active`, `pack_info`. |
| `Langertha::Raider::Packs::Pack` | `origin` (the only documented name). |
| `Langertha::Raider::Hall` | `new(root => ...)` and `run` (SYNOPSIS); `session_store`, `session_bindings`, `singleton_queues`, `binding_queues`, `keep_events`, `max_log_size`, `lib_target`, `cancel_grace`; `session_for`, `unbind_session`, `reset_session`, `drop_queued`, `cancel_raider`, `logs`. |
| `Langertha::Raider::ACP::Client` | `new`, `initialize`, `new_session`, `prompt_stream`, `cancel`. ADR 0010 reshapes ACP; see Consequences. |

The self-tool names behind `raider_mcp` are public as well (langertha ADR 0008, kept by
ADR 0001): `raider_ask_user`, `raider_pause`, `raider_abort`, `raider_wait`,
`raider_wait_for`, `raider_switch_engine`, `raider_manage_mcps`, `raider_session_history`.

The executables `raider` and `raider-hall` keep their names (ADR 0001). `raider`'s POD
(machine output, sessions, exit status) and `raider --help` describe the public command
line.

### Internal packages

Marked internal today:
`Langertha::Raider::Application`, `::Config`, `::Detect`, `::EngineResolver`,
`::Session`, `::Session::Journal`, `::SessionStore`, `::CLI::Main`, `::CLI::REPL`,
`::CLI::Runner`, `::CLI::Commands`, `::CLI::Output`, `::CLI::Machine`,
`::CLI::PromptBuilder`, `::CLI::Sessions`.
Added since (rule 6, marked from the start): `::CLI::Provider`, `::Provider::Fetch`,
`::Provider::Activation`, `::Provider::Change`, `::ToolArgs`, `::Approval`,
`::ToolEffects`, `::Home`, `::Instructions`, `::Config::Migrate`.

Internal by this ADR, still without the marker:
`Langertha::Raider::Hall::ACP`, `::Hall::ACP::SubStream`, `::Hall::CLI`, `::Hall::Cron`,
`::Hall::MCP`, `::Hall::Protocol`, `::Hall::Raider`, `::Hall::Telegram`, `::ACP::CLI`.
These are the Hall's parts and the dispatchers behind `raider hall` / `raider acp`. Under
ADR 0002 surfaces are thin adapters, not APIs of their own.

### Reserved stubs

`App::Raider`, `App::Raider::FileTools`, `App::Raider::WebTools`, `App::Raider::Skill`,
`App::Raider::Plugin::Situation`, `App::Raider::Plugin::Trace`. They have no API, and no
code goes back under these names (ADR 0001). Their successors (`Langertha::Raider::CLI`,
`::FileTools`, `::WebTools`, `::Skill`, `::Plugin::Situation`, `::Plugin::Trace`) are
public. Renaming one again would start another round of stubs. `Langertha::Raider::ACP`
is reserved for the stdio ACP server of ADR 0010.

## Consequences

Slices may recut every internal package freely. Each inconsistency below is a follow-up
and becomes its own ticket. None of them is fixed by this ADR:

1. **The public CLI inherits an internal class.** `Langertha::Raider::CLI` extends
   `Langertha::Raider::Application`, and its POD says "all the attributes and methods
   documented there … apply here". `Config`'s POD also sends users to the CLI. Until the
   Application is recut, its documented names are public through the CLI, and the class
   itself is not public to construct directly. The recut has to decide one of two ways:
   the CLI POD names its own list, or those names move into the CLI.
2. **Missing internal markers.** Nine packages are internal by this ADR but carry no
   marker (see the list above). Adding the marker is a docs-only follow-up.
3. **Undocumented names on public packages.** These names look public but are
   undocumented, so they are internal until documented:
   - `Langertha::Raider`: `run_f` is used in Raid steps but not documented in the Raider
     POD. `has_continuation` / `clear_continuation`, `has_inline_mcp` and
     `has_last_prompt_tokens` are public-named accessors of private attributes, and tests
     and `CLI::Runner` call them. Undocumented predicates: `has_mission`,
     `has_max_context_tokens`, `has_compression_engine`, `has_langfuse_*`, `has_raider_mcp`,
     `has_on_*`, `has_embedding_engine`.
   - `Langertha::Raider::Result`: `has_content`, `has_options`, `has_data`, `has_context`
     (only `has_text` is named).
   - `Langertha::Raid`: a subclass needs `_coerce_context`, `_run_steps_sequentially_f` and
     `_normalize_result`, which the three shipped subclasses call. That leaves no
     documented contract for writing a Raid subclass outside this distribution.
   - `Langertha::Raider::Packs::Pack`: `name`, `path`, `skill_text`, `exclusive_group`,
     `enabled_by_default`, `tools`, `detect`. `Packs::Collection`: `packs_by_name`,
     `exclusive_groups`, `enabled_pack_names`, `all_pack_names`.
   - `Langertha::Raider::Hall`: `spawn`, `ps`, `attach`, `kill_raider`, `shutdown`, and
     the attributes `root`, `loop`, `config`, `socket_path`, `state_dir`, `raiders`,
     `telegram`, `acp_adapter` and the other adapters.
   - `Langertha::Raider::CLI`: `env_var_for_engine`. Also, `default_model_for_engine` is
     documented as `=method` but is a plain function in a Moose class that dispatches
     through `__PACKAGE__`.
   - `*_class` resolver methods are nowhere documented: `Application`, `CLI::Main` (eight
     of them), `CLI::Commands`, `Config`, `Session`, `SessionStore`, `Hall`. They are the
     house override points. Whether an override point counts as public needs a decision.
     Until then they are internal.
4. **Private calls across classes.** Where these calls cross into a public class, they
   show API that is missing:
   - `CLI::Runner` reads `Langertha::Raider->_last_prompt_tokens`.
   - `Application` calls `Langertha::Raider->_set_mission`. Nothing public sets the
     mission after construction.
   - Internal to internal: `CLI::Commands` / `CLI::PromptBuilder` call `$app->_engine`,
     `CLI::Main` calls `$app->_engine_class`, `Hall::Protocol` / `Hall::MCP` call
     `$hall->_register_cmd` / `_running_slots`, `Hall::Telegram` / `Hall::ACP` /
     `Hall::Cron` call `$hall->_emit`, and `Hall::CLI` calls `$hall->_write_pidfile`.
5. **Naming split.** `Langertha::Raid*` sits in `Langertha::` but ships here. Everything
   else is `Langertha::Raider::*`, and `Langertha::Raider::Result` serves Raid too. The
   `Raid*` names were indexed from core. Renaming them now would mean stubs, so they stay
   unless an ADR decides otherwise. Other splits: tool builders are exported functions
   while the Hall parts are classes, and "pack" and "persona" name the same thing (see
   CONTEXT.md).
6. **Not Moose.** `ACP::Client` (public) and `Hall::ACP::SubStream` are hand-blessed
   classes. `ACP::Client` has its own `new` and `DESTROY`. `ACP::CLI` and `Hall::CLI` are
   plain function modules, and they report errors with `die`. ADR 0010 already moves the
   ACP client role to `raider acp connect` / `raider NAME@HOST`. So `ACP::Client` is public
   only until that ADR's slices land, and `Changes` will announce its replacement.
7. **Gaps in the docs of public surfaces.**
   - `raider`'s options are described only in the `usage` text of the internal
     `CLI::Main`. `bin/raider` has no `=opt` POD.
   - No module uses `=env`. The environment variables appear in prose in scattered places
     (`RAIDER_PACK_DIRS` in `Packs`, the search keys in `WebTools`, `*_API_KEY` in `raider`).
     `RAIDER_HALL_RAIDER_BIN`, `RAIDER_HALL_ACP_PORT` and `RAIDER_HALL_ACP_HOST` are not
     documented at all.
   - `bin/raider-hall` has no POD.
   - `raider`'s DESCRIPTION calls it the front-end of `Langertha::Raider::CLI`. It actually
     runs `Langertha::Raider::CLI::Main`, which builds a `Langertha::Raider::CLI`.

## Source

karr #96 (from #22, item "Oeffentliche API inventarisieren"). Inventory taken from
`lib/` and `bin/` at `ef7dd92`: every package's `# ABSTRACT`, POD entries against
`sub` / `has`, internal markers, cross-class `->_` calls and the object system used.
Outside consumers checked in `langertha-knarr` and `langertha` core.

## Addendum 1 — the modules of the Claude Code flow (karr #160, 2026-10-19)

The night of 2026-10-19 (streams K, K2, T, P, P2, H, A, L; ADRs 0018 to 0022) added
about thirty packages and a few dozen documented names. This addendum sorts them by the
rules above. Nothing in it changes the rules.

### New packages: all internal

Every package the Claude Code flow added carries the internal marker (rule 6), and this
addendum adds none of them to the public list:

- Context: `::Context`, `::Context::Layout`, `::Context::Memory`, `::Context::Settings`,
  `::Context::Plugins`, `::Context::Skills`, `::Context::Agents`,
  `::Context::Frontmatter`.
- Skills and subagents: `::SkillTools`, `::SkillResolver`, `::SkillResolver::Catalog`,
  `::SkillResolver::Skilletor`, `::AgentTools`, `::Subagent`, `::Briefing`.
- Tools: `::SearchTools`, `::TodoTools`, `::AskTools`, `::PlanTools`, `::ToolNames`,
  `::Loadguard`.
- Permissions: `::Permissions`, `::Permissions::Rule`, `::Permissions::ReadOnlyBash`,
  `::PermissionChannel`, `::Hall::PermissionChannel`.
- Hooks and plugins: `::Hooks`, `::Hooks::Result`, `::Plugin::ClaudeHooks`,
  `::Plugin::NestedMemory`.

Already internal and marked, but missing from the lists above: `::Binary`,
`::ConnectCheck`, `::Provider::Binding`.

Why none of them goes public: their contract is the behaviour of Claude Code, which the
tool-parity stream (karr #159) is still aligning, and every one of them is driven by
`Application` state (the context, the run's todo list, the REPL's questions, the hall's
permission channel). A tool builder like `build_skill_tools_server` (`SkillTools`
exports it) is not usable without that state, unlike `build_file_tools_server`. The two
plugins only make sense wired by `Application`; `Plugin::Situation`, `Trace` and `Events`
stay the public plugins. An ADR that wants one of them public later adds it to the list
(rule 6).

The nine `Hall::*` and `ACP::CLI` packages of "Internal by this ADR, still without the
marker" carry the marker now; consequence 2 is done.

### What the flow made public

Public, by rule 7 (formats) and rule 2 (documented names of public packages):

- **Tool names the model sees:** `skill`, `agent`, `glob`, `grep`, `todo_write`,
  `ask_user`, `exit_plan_mode`. Their argument names follow Claude Code (ADR 0018,
  karr #159) and are fixed with the first release that ships them.
- **Command line:** `--permission-mode MODE`, `--dangerously-skip-permissions`,
  `raider config explain` with the layout, settings, skills, agents, permissions and
  hooks it reports. The hidden `--permission-channel` is the hall's private wire to its
  raiders, not part of the command line.
- **Files raider reads:** the Claude Code layout as ADR 0019 describes it (the
  `CLAUDE.md` hierarchy, `CLAUDE.local.md`, `@imports`, `AGENTS.md`,
  `.claude/settings.json` / `settings.local.json` / `~/.claude/settings.json` with
  `permissions`, `env`, `enabledPlugins`, `hooks`; skill directories; plugins), agent
  files (ADR 0020: `.claude/agents/**/*.md`, `~/.claude/agents`, plugin agents,
  `.raider/agents/<name>.md`), `skilletor.json` sources for `briefing.skills`. raider's
  promise is "as Claude Code reads it"; where Claude Code changes, raider follows.
- **Config keys:** `claude`, `permissions` (`allow`, `ask`, `deny`, `default_mode`,
  `additional_directories`), `max_agent_depth`, `agent_models` in `.raider/config.yml`;
  `permission_timeout` in `.raider-hall.yml`.
- **Hook protocol:** Claude Code's JSON on stdin and stdout and its exit codes (ADR 0022);
  raider sets `CLAUDE_PROJECT_DIR`, and for plugin hooks `CLAUDE_PLUGIN_ROOT` and
  `CLAUDE_PLUGIN_DATA`.
- **Environment variables:** `LOADGUARD_THROTTLE`, `LOADGUARD_PSI_FULL`,
  `LOADGUARD_SWAP_USED`, `LOADGUARD_HEAVY_SLOTS`, `LOADGUARD_CONFINE`,
  `LOADGUARD_MEMORY_HIGH`, `LOADGUARD_MEMORY_MAX`, `LOADGUARD_MEMORY_SWAP_MAX`,
  `LOADGUARD_CPU_WEIGHT` (loadguard's names, ADR 0018); `CLAUDE_CONFIG_DIR` (read as
  Claude Code reads it). `LOADGUARD_CONFINED` is the restart's own marker, not an input.
- **`Langertha::Raider::Hall`:** `permission_timeout`, `register_permission_handler` and
  `unregister_permission_handler` (documented in its POD).
- **`Langertha::Raider` (the engine):** no new public name. Its tool hook is
  `_tool_hook`, private; used as a library without a gate every call runs (ADR 0021).

### Consequence 1 narrowed: what `Application` gained is not public through the CLI

Under consequence 1 every name documented in `Application` is public through
`Langertha::Raider::CLI`. Since the inventory `Application` gained 31 documented names:
`agent_models`, `build_subagent_engine`, `claude`, `claude_base_text`,
`claude_persona_off`, `compile_mission`, `context`, `hooks`, `instructions`,
`is_journal_type`, `loadguard`, `max_agent_depth`, `note_history_cleared`,
`on_ask_user`, `on_permission_request`, `on_plan_review`, `permission_mode`,
`permissions`, `provider`, `reload_context`, `reload_permissions`, `run_cancelled`,
`run_plugins`, `set_permission_mode`, `shutdown_hooks`, `skip_permissions`,
`stop_hook_limit`, `subagent_class`, `todos`, `tool_gate`, `tool_hook`. Most of them
are plumbing between `Application`, the REPL, the Hall and the new internal packages;
making them public by inheritance would freeze exactly the code the redesign recuts.

Decision: public through the CLI are only the names the inventory found, plus the
constructor arguments that mirror a public option or config key: `claude`,
`permission_mode`, `skip_permissions`, `max_agent_depth`, `agent_models`. Every other
name `Application` gains is internal, documented or not, until the recut of
consequence 1 gives the CLI its own list. The CLI POD says so. This is the first half of
that recut's choice ("the CLI POD names its own list"), applied to new names only.

### Follow-ups (not fixed here)

- The path confinement exists twice, in `FileTools` and in `SearchTools` (glob, grep).
  Folding it into one place waits for the tool-parity stream (karr #159), which owns
  both files now.
- `Hall`'s `register_permission_handler` is public by rule 2 only because its POD names
  it; it is the hall's wire to its ACP adapter, like the private `_register_cmd`. The
  Hall recut should decide whether surface adapters get a public registration API.

Source: karr #160. Inventory from `lib/` at `c828f0d`: `# ABSTRACT` and marker of every
package, `=attr` / `=method` of `Application` at `ef7dd92` against `c828f0d`, `$ENV{…}`
reads, `bin/raider` POD.

## Update (2026-10-25, hall bus)

Rule 7 also covers the hall's event bus and its control-socket protocol (ADR 0033): both are
public wire formats, documented in the POD of `Langertha::Raider::Hall`.
