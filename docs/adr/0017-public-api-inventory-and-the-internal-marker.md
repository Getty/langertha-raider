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
| `Langertha::Raider` | The engine and `main_module`. Attributes: `engine`, `mission`, `history`, `max_iterations`, `max_context_tokens`, `context_compress_threshold`, `compression_prompt`, `compression_engine`, `session_history`, `on_iteration`, `metrics`, `langfuse_trace_name` / `_user_id` / `_session_id` / `_tags` / `_release` / `_version` / `_metadata`, `raider_mcp`, `on_ask_user`, `on_pause`, `on_wait_for`, `cancel_requested`, `tools`, `mcp_catalog`, `engine_catalog`, `embedding_engine`, `no_session_embeddings`, `plugins`. Methods: `raid` / `raid_f`, `respond` / `respond_f`, `cancel`, `clear_cancel`, `clear_history`, `clear_session_history`, `add_history`, `add_session_history`, `inject`, `reset`, `active_engine`, `active_engine_name`, `switch_engine`, `reset_engine`, `engine_info`, `list_engines`, `add_engine`, `remove_engine`, `compress_history` / `compress_history_f`, `register_session_history_tool`; `run_f` through `Role::Runnable`. Plugin hooks `plugin_before_raid`, `plugin_build_conversation`, `plugin_after_raid` (contract in core's `Langertha::Plugin`). |
| `Langertha::Raider::Result` | `type`, `text`, `content`, `options`, `data`, `context`; `is_final`, `is_question`, `is_pause`, `is_abort`, `is_cancelled`, `has_text`, `as_hash`, `with_context`; constructors `final`, `question`, `pause`, `abort`, `cancelled`; `""` overload to `text`, `bool` always true. |
| `Langertha::Raid` | `steps`, `name`, `run_f`. |
| `Langertha::Raid::Sequential` | `run_f`. |
| `Langertha::Raid::Parallel` | `merge_slot`, `run_f`. |
| `Langertha::Raid::Loop` | `max_loops`, `max_iterations`, `continue_while`, `run_f`. |
| `Langertha::Raider::CLI` | The CLI as a Perl class (ADR 0001). Its own: `trace`, `trace_out`, `source_labels`, `persona_intro`, `persona_turn_end`, `ignored_agent_files`, `trace_plugin`, `token_stats`, `default_model_for_engine`. Also the names documented in `Langertha::Raider::Application`, **when called on a `Langertha::Raider::CLI`**, because the CLI POD promises them (see Consequences). |
| `Langertha::Raider::FileTools` | `build_file_tools_server` (`@EXPORT_OK`); tools `list_files`, `read_file`, `write_file`, `edit_file`. |
| `Langertha::Raider::WebTools` | `build_web_tools_server` (`@EXPORT_OK`); tools `web_search`, `web_fetch`. |
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
`::ToolEffects`, `::Home`, `::Instructions`.

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
