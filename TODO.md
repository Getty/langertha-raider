# TODO — langertha-raider bootstrap

Entscheidung vom 2026-09-17: das Agenten-Framework aus `langertha`-Core rausziehen
und mit der bisher eigenständigen `raider`-App zu einer Sibling-Distribution
`langertha-raider` verschmelzen — gleiches Muster wie `langertha-knarr` /
`langertha-skeid` (Sibling-Dist, `requires 'Langertha'`, nie umgekehrt).

## Warum

- `Langertha::Raider` (2210 Zeilen, `lib/Langertha/Raider.pm` in `langertha`) ist
  die Autonomous-Agent-Engine (MCP-Tool-Calling, Conversation History, `raid_f`).
  Ihre einzigen harten Abhaengigkeiten liegen innerhalb von `langertha`-Core
  (`Langertha::Raider::Result`, `Langertha::RunContext`, Rollen
  `PluginHost`/`Runnable`) — Core haengt NICHT hart zurueck. Die einzigen zwei
  Stellen in Core sind weich: ein lazy `use_module('Langertha::Raider')`
  Sugar-Pfad in `Langertha.pm` (`use Langertha 'Raider'`) und ein
  Laufzeit-`->isa('Langertha::Raider')`-String-Check in `Plugin.pm`. Alles
  andere sind POD-Querverweise. -> Extraktion aendert nichts am harten
  Abhaengigkeitsgraphen von langertha-Core.
- `~/dev/raider` (`App::Raider`, github.com/Getty/raider) requiret bereits
  `Langertha` >= 0.404 und importiert `Langertha::Raider` schon direkt in 4
  Dateien (`App/Raider.pm`, `App/Raider/Skill.pm`, `Plugin/Situation.pm`,
  `Plugin/Trace.pm`) — plus `langertha-knarr`s `Handler/Raider.pm` (Factory-
  Pattern, Model-ID heisst dort schon `langertha-raider`).
- Verworfene Alternative: `Langertha::Raider` in den *bestehenden* `raider`-Dist
  verschieben, ohne ihn umzubenennen. Waere ein Dist namens `App-Raider`, der
  nicht dem `langertha-<suffix>`-Sibling-Schema folgt und CPAN-seitig ein
  `App::*`-Namespace mit einem `Langertha::*`-Namespace mischt, obwohl es
  strukturell ein Langertha-Sibling ist.

## Was wohin zieht

**Nach `langertha-raider`** (dieses Repo):
- aus `langertha`-Core: `lib/Langertha/Raider.pm`, `lib/Langertha/Raider/Result.pm`,
  `lib/Langertha/MCP/Client.pm`, dazugehoerige `t/7*_raider*.t`, `t/8*_raider*.t`,
  `t/96_raid_orchestration.t`, `t/91_plugin_config.t` (vor dem Verschieben pruefen
  — manche testen evtl. auch generisches Plugin/PluginHost-Verhalten und sollten
  dann bleiben).
- aus `~/dev/raider`: `App::Raider::*` (13 Dateien unter `lib/App/Raider/`) —
  zieht komplett um nach `Langertha::Raider::*`, siehe Namens-Entscheidung unten.
- `Net::Async::MCP`-Requirement wandert aus `langertha`s cpanfile in das von
  `langertha-raider`.

**Bleibt in `langertha`-Core:**
- der lazy `use Langertha 'Raider'` Sugar in `Langertha.pm` (funktioniert
  weiterhin, sobald `Langertha::Raider` ein separat installierter Dist ist —
  `use_module` ist das egal).
- der `->isa('Langertha::Raider')`-Check in `Plugin.pm`.
- `Langertha::Role::Tools`, `Role::PluginHost`, `Role::SystemPrompt`,
  `Role::Runnable`, `Plugin.pm`, `Plugin::Langfuse`, `Role::Langfuse`, `Chat.pm`,
  `Result.pm` — generisches Plugin-/Tool-Calling-Fundament, das auch ohne Raider
  genutzt wird (z.B. simples `Langertha::Chat`-Tool-Calling). NICHT verschieben.

## Namens-Entscheidung noetig vor dem eigentlichen Code-Umzug

`Langertha::Raider` (bare) ist bereits die Engine-Klasse und wird das
`main_module` dieses Dists — genau wie `Langertha::Knarr`/`Langertha::Skeid`
ihre jeweiligen Dists sind. `App::Raider.pm` — der aktuelle CLI-Entry-Point —
haette denselben bare Namen gewollt, kann ihn aber nicht haben. Vorschlag:
`App::Raider.pm` wird zu `Langertha::Raider::CLI` (Analogie: `Langertha::Knarr::CLI`
ist der CLI-Entry neben der `Langertha::Knarr`-Serverklasse). Der Rest ist ein
mechanisches `App::Raider::X` -> `Langertha::Raider::X` Rename. **Vor dem
eigentlichen Rename durch raider-worker bestaetigen** — betrifft `bin/raider`
und jede interne Querreferenz.

## Noch offen / nicht entschieden

- Wird das GitHub-Repo `Getty/raider` zu `Getty/langertha-raider` umbenannt, oder
  entsteht ein neues Repo und das alte wird archiviert? Nicht erledigt — dieses
  Bootstrap hat nur das lokale Verzeichnis angelegt, kein Remote, kein Push.
- Docker-Hub-Image heisst aktuell `raudssus/raider` (siehe altes `dist.ini`
  `run_after_release`) — neuer Image-Name zu entscheiden
  (`raudssus/langertha-raider`?).
- `dist.ini` / `cpanfile` / `lib/`-Skelett fuer dieses Repo existieren noch
  nicht — erste echte Aufgabe fuer `raider-worker`.
- karr-Board ist mit den Punkten oben geseedet (`karr board`).

## Bootstrap in dieser Session erledigt (2026-09-17)

- Verzeichnis angelegt, git lokal initialisiert (kein Remote, kein Push).
- `.claude/agents/raider-{worker,test-writer,release-checker}.md`,
  `.claude/rules/raider-rules.md`, `.claude/settings.json` — getty-agent-team-
  Standard, nach Vorbild `langertha-knarr`/`langertha-skeid`.
- Skills gehardlinkt (nicht kopiert): getty-perl-core, perl-ai-langertha,
  getty-perl-moose, perl-io-async-future, perl-mcp, perl-release-dist-ini,
  getty-git-commit-style, getty-perl-release-author-getty,
  kanban-issues-karr-cli.
- karr-Board initialisiert (`karr init`), Skill gehardlinkt statt per
  `karr skill install`.
