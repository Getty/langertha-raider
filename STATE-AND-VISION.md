# Langertha-Raider — Zustand & Vision (Input für den Neuentwurf)

Stand: 2026-09-24. Zweck dieses Dokuments: einer planenden KI **alles** geben, was sie
braucht, um einen Umbau von Raider zu entwerfen — was heute existiert, wo es kaputt oder
chaotisch ist, welche Vision-Fetzen es gibt (mit Status), und was entschieden bzw. offen ist.
Es ist **kein** Plan. Es beschreibt Ausgangslage und Zielrichtung.

Ehrliche Zusammenfassung: Raider ist in Slices gewachsen (CLI → Perl-Tools → Packs → Hall
→ Telegram/Cron → ACP), jeweils ohne Gesamtentwurf. Die ursprüngliche Identität („ein
Terminal, eine Konversation, kein Daemon, kein SaaS, kein IDE-Plugin“) ist längst überholt,
eine neue wurde nie formuliert. Dieses Dokument ist der Versuch, sie zu formulieren.

---

## 1. Die Vision (Maintainer, 2026-09-24)

### 1.1 Kern-These: Perl ist der Glue des Internets — Raider ist der Glue für KI

Raider soll das zentrale KI-Werkzeug sein, das „einfach überall reingeht“: in jedes
Projekt, jede Umgebung, an jeden Provider, jedes Tool. Perl ist dafür die richtige Sprache,
weil es historisch genau das ist — Glue. Raider ist der Perl-Agent.

### 1.2 Hermes Agent **und** Claude Code — zwei Ziele, ein Werkzeug

- **Hermes-Agent-Seite:** ein persönlicher Assistent, der im Home-Verzeichnis lebt,
  überall erreichbar ist (CLI, Messaging, Cron, Server), sich an den Nutzer erinnert.
- **Claude-Code-Seite:** ein Coding-/Projekt-Agent, der in einem Projekt arbeitet und dort
  den Projekt-Kontext respektiert.
- Beide verfolgen **unterschiedliche Ziele**. Der Entwurf muss diese Spannung explizit
  auflösen, nicht verwischen.

### 1.3 Kontext-Disziplin: effektiver Kontext, keine Pollution

- Raider soll **genau den Kontext haben, der zählt** — und sich nicht zumüllen lassen.
- **Schichtung:** Home (global, persönlich) → Projekt. Im Projekt zählt Projekt-Kontext
  **mehr**: `.raider` (Projekt-Config), `CLAUDE.md`, `AGENTS.md` sollen automatisch
  gelten, sobald Raider sie sieht (heute: opt-in per Flag, s. §3.2).
- Home-Kontext darf nicht ungefiltert in jedes Projekt bluten; Projekt-Kontext nicht in
  den persönlichen Assistenten.

### 1.4 Oberflächen

- Kommandozeile (REPL + One-Shot + `--json`) bleibt zentral.
- Daemon/Hall mit Messaging (Telegram), Cron, Multi-Agent.
- ACP (Editor-Integration, Zed-Protokoll).
- **Webserver** — „wenn wir eh dabei sind, warum nicht“. Ernst gemeint als Option.

### 1.5 Provider-Discovery: `raider --provider host.tld`

- Ein Anbieter soll sagen können: „macht einfach
  `raider --provider raider.provider.de` (Alias z.B. `provider-agent`), und er weiß, was
  zu tun ist.“
- Mechanismus-Idee: Raider holt `https://host/.well-known/raider.json` (Name offen, evtl.
  generischer `langertha.json`). Das Manifest beschreibt z.B.: Engines/Modelle +
  Endpunkte (OpenAI-/Anthropic-kompatibel …), Auth-Verfahren, MCP-Server (Tools), ggf.
  Packs/Skills, Default-Mission, Limits.
- Aliase werden lokal (Home-Config) gespeichert.
- Ziel: **alles sehr leicht anschließbar**.

### 1.6 Ökosystem-Rollen für das Provider-Manifest

| Dist | Rolle |
|---|---|
| **langertha** (Core) | Zentrales Konzept: Schema/Datenmodell des Manifests, Parser+Validierung, Builder (aus Engine-/Modell-Config ein Manifest erzeugen). Einmal, von allen genutzt. |
| **langertha-knarr** (Universal LLM Hub/Proxy) | Liefert das Manifest **automatisch** aus, mit der kompletten Modell-Liste seiner Engines. Dann reicht `raider --provider mein-knarr` — „passt wie Arsch auf Eimer“. |
| **langertha-skeid** (Routing-Control-Plane) | Hat das Konzept auch, aber **weniger automatisch**: in der Skeid-Config ist konfigurierbar, was an Raider (oder andere Clients) exponiert wird. |
| **langertha-raider** | Client: Manifest lesen, Provider-Aliase verwalten, verbinden. |

Abhängigkeitsrichtung bleibt: knarr/skeid/raider → langertha, nie umgekehrt.
Arbeit in knarr/skeid/langertha läuft über deren jeweilige karr-Boards.

### 1.7 Abo-Backends anbinden (Codex, Claude)

Maintainer-Wunsch (2026-09-24): Wenn Raider „alles anbinden“ soll, dann auch
Abo-Zugänge. Vorbild ist der claude-code-proxy, der Codex auf diese Weise anbindet (§1a).
Alles andere decken ohnehin die Langertha-Engines ab.

Recherche-Stand vom 2026-09-24. Das ist eine Web-Recherche eines Subagenten. Vor der
Umsetzung müssen die Primärquellen erneut geprüft werden.

**OpenAI / Codex (ChatGPT-Abo)**
- **Verträge:** Die Terms of Use (gültig ab 2026-01-01, EU-Fassung gleichlautend)
  erwähnen fremde Clients **weder erlaubend noch verbietend**. Kritisch zu lesen sind:
  - „Automatically or programmatically extract data or Output“
  - Reverse Engineering
  - Account-Sharing
  - Umgehen von Rate-Limits
- **Nicht-vertragliche, aber explizite Aussagen von OpenAI:**
  - Altman, 2026-05-02: ChatGPT-Login in OpenClaw „use your subscription there“.
  - Codex-Lead Sottiaux, ca. 2026-05-23: „you can use your ChatGPT account in a
    flourishing set of other tools“.
  - Die Programmseite „Codex for Open Source“ nennt OpenCode, Cline, pi und OpenClaw.
- **Offizieller Integrationspfad:** `codex app-server`, also JSON-RPC über stdio.
  - Codex verwaltet dabei selbst den ChatGPT-OAuth und das Token-Refresh.
  - Es gibt einen experimentellen Modus `chatgptAuthTokens` für Host-Apps.
  - `clientInfo.name` soll den Client ehrlich benennen, hier `raider`.
  - Alternativ gibt es `codex exec --json` für Headless-Einsätze.
  - `codex mcp-server` wurde **entfernt**.
  - OpenClaw ist im Mai 2026 genau auf diesen Pfad umgestiegen.
- **Einordnung:**

  | Weg | Einordnung |
  |---|---|
  | API-Key | klar ok |
  | `codex app-server` oder `codex exec` als Subprozess | ok, der sanktionierte Weg |
  | Eigener PKCE-OAuth mit Codex-client_id und direkter Aufruf von `chatgpt.com/backend-api/codex/responses` (so macht es heute der claude-code-proxy) | Grauzone, wird geduldet: undokumentiertes Backend, jederzeit widerrufbar |
  | `~/.codex/auth.json` direkt auslesen | grau bis riskant |
  | Ein Abo für mehrere Nutzer, Weiterverkauf, Umgehen von Limits | verboten |

**Anthropic / Claude (Pro/Max-Abo)**
- Stand der Doku vom 2026-08-21:
  - OAuth ist für Claude Code und native Anthropic-Apps gedacht.
  - Drittentwickler dürfen **keine** Claude.ai-Anmeldung anbieten.
  - Sie dürfen **keine** Tokens sammeln, speichern oder vermitteln.
- Erlaubt seit 2026-05-13: das **unveränderte** `claude`-Binary, also `claude -p`, bzw.
  das Agent SDK auf dem eigenen Abo.
- Direkte Token-Weiterverwendung gegen `api.anthropic.com` ist verboten und wird
  serverseitig geblockt.

**Entschieden (Maintainer, 2026-09-24): Der Subprozess-Weg ist ok.**
- Abo-Zugänge werden über die offiziellen Binaries angebunden: Codex über
  `codex app-server` (stdio), Claude über `claude -p` bzw. das Agent SDK. Die Binaries
  besitzen dabei die Anmeldung.

**Idee: `--use-codex` / `--use-claude` als „Extra-KI“**
- Die Flags hängen eine zusätzliche KI als **Tool** an, nicht als Haupt-Engine. Raider
  kann ihr Anfragen stellen, etwa „frag Codex“ oder „lass Claude das reviewen“.
- Vorbild ist dieses Setup hier: Claude Code hat Codex als MCP-Server und fragt ihn bei
  Bedarf.
- Umsetzungs-Idee: Der jeweilige Subprozess wird als MCP-Tool oder Self-Tool eingehängt
  (`ask_codex`, `ask_claude`). Die Haupt-Engine bleibt, was per `--engine` bzw. Provider
  gewählt ist.
- **Namenskonflikt:** `--codex` bzw. `--openai` und `--claude` existieren heute schon und
  bedeuten „lade `AGENTS.md` bzw. `CLAUDE.md`“. Das muss der Planer mit auflösen,
  zusammen mit dem Wunsch, diese Dateien künftig automatisch zu laden (§1.3).
- Offen:
  - Sieht die Extra-KI den Kontext der Haupt-Session oder nur die Anfrage? Das berührt
    die Kontext-Disziplin.
  - Welches Arbeitsverzeichnis und welche Rechte bekommt sie (Sandbox, Approvals über
    app-server)?
  - Soll sie auch Haupt-Engine sein können?

**Weitere Designfragen**
- Direkte Backend-OAuth-Wege höchstens opt-in und klar als „inoffiziell“ markiert.
- Offene Frage für den Planer: Wo lebt so ein Subprozess-Engine-Typ? Als Engine in Core
  (`Langertha::Engine::CodexAppServer`?), obwohl er keine HTTP-Engine ist, oder in
  Raider? Wie passt es zusammen, dass Codex und Claude Code selbst Agenten mit eigenem
  Tool-Loop sind, Raider also einen Agenten steuert statt eines Modells?
- Quellen: openai.com/policies/row-terms-of-use, /eu-terms-of-use, /service-terms;
  developers.openai.com/codex/app-server; learn.chatgpt.com/docs/codex-sdk;
  developers.openai.com/community/codex-for-oss; code.claude.com/docs/en/legal-and-compliance;
  support.claude.com/en/articles/15036540.

### 1.8 Ältere, weiter gültige Anforderungen

- **„Async UND rundenbasiert“** (2026-09-20): Raider muss beides können. Nirgends
  entworfen.
- **Agenten in anderen Verzeichnissen/auf anderen Hosts starten und aktiv mit ihnen
  reden** (2026-09-05, Kontext Claude/Codex-Skills): z.B. per ACP über stdio-über-SSH;
  Remote-Account kann jemand anderem gehören.
- **ACP gehört an den Agenten**, nicht generisch in Core und nicht an die Hall:
  Ziel `Langertha::Raider::ACP` (ein Raider über stdio), Hall als ein Konsument
  (2026-09-20, vom Maintainer selbst so revidiert).
- **Perl-native Tools** (`perl_eval`, `perl_cpanm` mit privatem local::lib,
  auto-install fehlender Module) sind die konkrete Form von „Perl als Glue“.

---

## 1a. Das Langertha-Ökosystem (Kontext für den Planer)

Raider ist eine von vier Dists. Alle hängen von Core ab, Core von keiner.

### Langertha (Core) — `~/dev/langertha`, v0.503 (unreleased; 0.502 auf CPAN)

Provider-Abstraktion auf Moose + IO::Async + Future::AsyncAwait.

- **Engines** (`Langertha::Engine::*`, ~35): Vererbung = Wire-Dialekt (ADR 0006),
  Rollen = Fähigkeiten (ADR 0002).
  - Anthropic-Dialekt: Anthropic, MiniMax-/Moonshot-/AKI-/LMStudioAnthropic.
  - OpenAI-Dialekt: OpenAI (+Responses), DeepSeek, Groq, XAI, Mistral, MiniMax,
    Moonshot, NousResearch (Hermes-`<tool_call>`), Cerebras, OpenRouter, Replicate,
    HuggingFace, AKIOpenAI, TSystems, Scaleway, Hetzner, OllamaOpenAI, vLLM, SGLang,
    LlamaCpp, LMStudioOpenAI.
  - Nativ: Gemini, Ollama, AKI, LMStudio, Perplexity, Whisper.
  - Erweiterbar über `LangerthaX::Engine::*`.
- **Fähigkeiten:** `engine_capabilities`, `supports($cap)`, abgeleitet aus den Rollen, mit
  modellspezifischen Korrekturen und Ausschlüssen (ADRs 0019/0021/0024). `chat_f`
  schreibt Requests passend zur Fähigkeit um (ADR 0005).
- **Tool-Calling:** `Role::Tools` mit MCP-Loop `chat_with_tools_f`. `mcp_servers` ist
  duck-typed (Net::Async::MCP-kompatibel). Tool-Wertobjekte gibt es für alle Wire-Formate
  (openai, anthropic, gemini, ollama, responses, hermes).
- **Modelle:**
  - `Role::Models` bietet `models` (lazy, gecacht, TTL 3600s) und `list_models` pro
    Engine, bei OpenAI-kompatiblen über `/models`.
  - Engines ohne Listen-API liefern über `Role::StaticModels` eine feste Liste.
- **Discovery (nur lokal):**
  - `Langertha->available_engine_classes` und `available_engine_ids` findet Engines per
    Module::Pluggable.
  - `Langertha->new_engine($name, %args)` baut eine Engine per Name.
  - API-Keys kommen per Konvention aus `LANGERTHA_<ENGINE>_API_KEY`.
  - **Es gibt kein Manifest und kein Config-Dateiformat in Core.** An dieser Stelle würde
    das Provider-Manifest-Konzept (§1.6) andocken, als Serialisierung genau dieser Daten:
    Engine-ID, URL, Modelle, Fähigkeiten, Auth.
- **Weitere Bausteine:**
  - Plugin-System (`Langertha::Plugin` mit async Hooks, `Role::PluginHost`).
  - Langfuse (Rolle und Plugin).
  - Usage/Pricing/Cost, Streaming, Embedding, Transkription, Bildgenerierung, Reasoning-
    Profile, Prompt-Cache.
  - `RunContext` und `Role::Runnable` als generische Orchestrierungs-Primitive.
  - `Langertha::Chat` als einfacher Wrapper.
- **Sugar:** `use Langertha 'Raider'` bzw. `'Plugin'` setzt die Superklasse und importiert
  Moose und AsyncAwait. Raider wird dabei lazy aus langertha-raider geladen.
- Details: `CLAUDE.md` (Engine-Baum, Rollen), `CONTEXT.md`, `docs/adr/0001–0026`.

### Knarr — `~/dev/langertha-knarr`, v1.102 (1.101 auf CPAN)

„Universal LLM Hub“: ein IO::Async-Proxy, Server und Übersetzer.

- **Nimmt an:**
  - OpenAI (`/v1/chat/completions`, `GET /v1/models`)
  - Anthropic (`/v1/messages`)
  - Ollama (`/api/chat`, `/api/tags` …)
  - Agenten-Protokolle A2A (Google), ACP (BeeAI/IBM) und AG-UI (CopilotKit)
  - PSGI
- **Handler:**
  - `Router` routet nach Modell zu einer Langertha-Engine und fällt sonst auf rohes
    1:1-`Passthrough` upstream zurück (Mixed Mode).
  - `Raider` erzeugt einen Raider pro Session per Factory und bietet ihn als „Modell“
    `langertha-raider` an.
  - `A2AClient` und `ACPClient` konsumieren entfernte Agenten.
  - Dekoratoren: `Tracing` (Langfuse) und `RequestLog` (JSONL).
- **Config:** YAML mit `listen`, `models: {name → engine, model, api_key(_env), url …}`,
  `default`, `auto_discover` (fragt die Modell-Listen der Engines ab), `passthrough`
  und `proxy_api_key`.
  - CLI: `knarr start|models|check|init|container`. `init` scannt env/.env nach API-Keys.
- **Auth:** eingehend ein optionaler Shared Secret. Beim Passthrough werden die
  Client-Header (`authorization`, `x-api-key`) weitergereicht.
  - Doku-Use-Case: `ANTHROPIC_BASE_URL=http://localhost:8080 claude` für Tracing.
- **Bezug zur Vision:**
  - Knarr hat schon `/v1/models`, Auto-Discovery und `Handler::Raider`. Damit ist es der
    natürliche Auslieferer von `/.well-known/raider.json` (automatisch aus der eigenen
    Modell-Liste).
  - Mit `Handler::Raider` ist es außerdem schon heute „Raider als Server“. Das überlappt
    mit Hall-ACP und der Webserver-Idee.

### Skeid — `~/dev/langertha-skeid`, v0.003 (0.002 auf CPAN)

„Routing Control Plane“: ein Mojolicious-Prozess vor vielen LLM-Nodes, gedacht für den
Betrieb (eigene GPU-Nodes, vLLM/SGLang, Kunden-Keys).

- **Frontends:** OpenAI (`/v1/chat/completions`, `/v1/embeddings`, `/v1/models`),
  Anthropic, Ollama. Intern gibt es nur eine Upstream-Form, alle Client-Formate werden
  übersetzt (ADR 0001). Dazu Admin-API `/skeid/nodes|metrics|usage`.
- **Config:** YAML, bei jedem Dispatch neu geladen.
  - `nodes[] {id, url, model, engine, weight, max_conns, api_key_ref}`
  - `pricing`
  - `usage_store` (jsonlog, sqlite oder postgresql)
  - `keys:` (Routing-Policy pro Kunde)
  - `admin`
- **Routing:** gewichtet. Eignung und Admission werden getrennt entschieden, `max_conns`
  ist über Worker aufgeteilt, `CapacityProbe` fragt Prometheus ab.
- **Keys:** `KeyBroker::OpenBao` hält Secrets nur im Speicher.
- **Usage/Cost:** Usage-Events sind die Abrechnungseinheit.
- **Bezug zur Vision:** Skeid ist das Gegenstück für Anbieter. Welche Modelle und Routen
  an Raider (oder andere Clients) exponiert werden, ist bewusst **konfigurierbar statt
  automatisch**, etwa pro Kunden-Key.

### Nicht-Langertha-Baustein: claude-code-proxy

- `~/dev/claude-code-proxy` ist Gettys Fork von raine/claude-code-proxy (Rust).
- Claude Code ist dort der *Client* (`ANTHROPIC_BASE_URL=http://127.0.0.1:18765`). Der
  Proxy übersetzt Anthropic-Messages auf andere **Abo-Backends**: Codex (ChatGPT
  Plus/Pro), Kimi, Grok, OpenCode Go und Cursor Agent.
- **Codex-Auth dort:**
  - eigener OpenAI-OAuth mit der `client_id` des Codex-CLI, als PKCE-Login im Browser
    oder per Device-Code
  - Tokens in `~/.config/claude-code-proxy/codex/auth.json`
  - Upstream ist `chatgpt.com/backend-api/codex/responses`
- Auf der Perl-Seite nutzt heute **nichts** Abo- oder OAuth-Auth. Raider, Knarr und Skeid
  arbeiten nur mit API-Keys.

---

## 2. Historie & Entscheidungen

### 2.1 Werdegang

- 2026-04 (0.001–0.004, Dist `App-Raider`, github.com/Getty/raider): CLI → Perl-Tools →
  Packs → Hall (Multi-Agent-Daemon) → Telegram/Cron → ACP-Prototyp.
- Die Engine `Langertha::Raider` lebte parallel in `langertha`-Core.
- 2026-09-17: Entscheidung, Engine + App in Sibling-Dist `langertha-raider`
  zusammenzuführen (Muster knarr/skeid). Auslöser: „warum zieht Net::Async::MCP Langertha
  rein?“ Maintainer zu App::Raider: „oh je … aber du hast recht, ich sollte das alles
  wegwerfen“.
- 2026-09-20: Core-Seite erledigt (ADR 0026 in langertha). `RunContext` und
  `Role::Runnable` bleiben in Core (generisch, abhängigkeitsfrei).
- 2026-09-24: Dist zusammengebaut (`b3ae744`), Multi-Package-Dateien gesplittet
  (`9fbd74d`), neues Repo **github.com/Getty/langertha-raider**, altes `Getty/raider`
  archiviert. Version **0.503**. Ziel dieser Runde: nur minimal wieder lauffähig
  machen — der eigentliche Umbau kommt danach, auf Basis dieses Dokuments.

### 2.2 Entschieden

- Dist `Langertha-Raider`, main_module `Langertha::Raider` (Engine).
- `App::Raider` → `Langertha::Raider::CLI`, `App::Raider::X` → `Langertha::Raider::X`.
  Binaries `raider`, `raider-hall` bleiben.
- Hall, Telegram, Cron, ACP bleiben **in** langertha-raider (keine eigene Dist).
- MCP-Client nur als `Langertha::Raider::MCP` (nicht in Core).
- Engine-Designs (langertha ADRs, weiter gültig):
  - **ADR 0007** Zwei-Ebenen-History: komprimierte Arbeits-`history` + nie komprimierte
    `session_history` mit Embeddings/Cosine-Recall (Fallback grep).
  - **ADR 0008** Kontrollfläche als virtuelle „Self-Tools“ (`raider_ask_user`, `pause`,
    `abort`, `wait`, `wait_for`, `session_history`, `manage_mcps`, `switch_engine`),
    per `raider_mcp` gated, default aus.
  - **ADR 0026** Extraktion in Sibling-Dist, Einweg-Abhängigkeit.

### 2.3 Widersprüche / verworfene Richtungen

1. Alte README-Identität („no daemon, no SaaS, no IDE plugin“) vs. gebaute Hall/Telegram/
   Cron/ACP vs. neue Hermes-Vision → alte Identität ist tot.
2. `CLAUDE.md`/`AGENTS.md` heute opt-in per Flag vs. Wunsch „zählt automatisch“.
3. Keine Home-Config vs. „lebt überall von deinem Home aus“.
4. ACP: erst „generisch in Core“, dann „`Langertha::Raider::ACP`“ — Code bindet ACP
   noch an die Hall, über TCP statt stdio.
5. **App::Raider auf CPAN — entschieden 2026-09-24.** „Aus CPAN löschen“ geht nicht:
   BackPAN und Archive behalten alles. Deshalb gilt:
   - Die höchste indexierte Version jedes veröffentlichten Packages muss immer ein
     Stub sein, der sagt „tot, gibt's hier nicht mehr“.
   - Diese Dist liefert Reserve-Stubs für die 6 indexierten `App::Raider*`-Packages
     (Stand `02packages`: alle 0.003).
   - Erst nach diesem Stub-Release dürfen die Stubs später wegfallen.
6. „ACP“ = zwei Protokolle im Ökosystem: knarr nutzt BeeAI/IBM *Agent Communication
   Protocol* (REST `/runs`), Raider Zeds *Agent Client Protocol*.
7. Version: 0.502 → 0.504 → final **0.503** (2026-09-24, Maintainer).

---

## 3. Ist-Zustand des Codes (Commit 079f335)

~14.2k Zeilen gesamt, ~9.3k in `lib/`. `prove -lr t`: 19 Dateien, 268 Tests, grün
(Live-Tests skippen ohne Keys). `dzil build`/`dzil test` sauber.

### 3.1 Modulkarte

**Engine** (aus langertha-Core):

| Datei | Zeilen | Zweck |
|---|---|---|
| `Langertha/Raider.pm` | 2214 | Alles: Tool-Loop, History, Kompression, Session-Embeddings + Cosine, Self-Tools, MCP-Katalog, Engine-Katalog, Langfuse, Continuations (`respond_f`), `run_f` |
| `Raider/Result.pm` | 257 | final/question/pause/abort |
| `Raider/MCP.pm` | 243 | Net::Async::MCP-Subklasse für Protokoll 2026-07-28 — laut eigener POD „temporärer Workaround“ |
| `Raid.pm`, `Raid/{Sequential,Parallel,Loop}.pm` | 225+48+154+139 | Orchestrierung über `Role::Runnable`/`RunContext` |
| `Raider/Plugin/{Trace,Situation}.pm` | 262+94 | ANSI-Trace/Spinner; Zeit/Host/User-Block |

**CLI:**

| Datei | Zeilen | Zweck |
|---|---|---|
| `bin/raider` | 865 | **Die eigentliche App** steckt im Script: Optionen, REPL, Slash-Commands, Banner, `.raider.yml`-Writer, Prompt-Builder-Subagent — untestbar |
| `Raider/CLI.pm` | 882 | Eigentlich „App/Session-Builder“: Engine-Autodetect, Modell-Defaults, Mission-Assembly, MCP-Server-Aufbau, Raider-Konstruktion |
| `Raider/Skill.pm` | 306 | Exportiert „wie benutzt man raider“-Markdown / Claude-Code-SKILL.md |

**Tools** (je ein In-Process-`MCP::Server`, als Exporter-Funktionen `build_*_server`):
`FileTools` (list/read/write/edit, root-confined), `WebTools` (search via
Net::Async::WebSearch, fetch), `PerlTools` (eval/check/cpanm → `.raider/lib`),
`HallTools` (telegram_reply, hall_status, hall_spawn), plus `bash` via `MCP::Run::Bash`.

**Packs:** `Packs.pm` + `Packs/{Pack,Collection}.pm`; `share/packs/` enthält caveman,
polite, teacher (Personas), git-guru, perl-hacker, testing-fu (Power). Exklusive Gruppen.

**Hall:** `Hall.pm` (755: Socket-Server, Pub/Sub, Prozess-Supervision, Queue,
Pidfile), `Hall/CLI.pm` (669: Subcommands + systemd-Templates), `Hall/{Protocol,Cron,
Telegram,MCP,Raider,ACP,ACP/SubStream}.pm`.
**ACP-Client:** `ACP/{Client,CLI}.pm`.

**Sonstiges:** `plugins/claude-code/SKILL.md` (Claude Code ↔ Hall-MCP-Socket —
dokumentiert ein Feature, das nicht funktioniert, s. §4), `examples/multi-raider-hall/`,
`Dockerfile` (multi-stage, `runtime-root`/`runtime-user`), `maint/release-after.pl`
(GitHub-Release + Docker-Push `raudssus/raider`).

### 3.2 Config- und Kontext-Discovery heute

- **Alles projekt-relativ zu `--root` (default cwd). Keine Home-/globale Config.** Home
  nur für `~/.raider_history` (readline) und systemd-User-Units.
- `<root>/.raider.yml`: flach, oder `default:` + `<engine>:`-Blöcke; Keys u.a. `skills`,
  `packs`, `perl`, `preferred_lib_target`, Engine-Optionen. **An fünf Stellen separat
  geparst** (CLI.pm ×3, bin/raider ×2 schreibend/lesend), leicht unterschiedliche Semantik.
- Engine-Args-Präzedenz: yml < `-o KEY=VALUE` < explizite CLI-Flags.
- Engine-Wahl: `--engine`, sonst erstes gesetztes `*_API_KEY` (Anthropic, OpenAI,
  DeepSeek, Groq, Mistral, Gemini …), sonst anthropic. Nur API-Keys, keine
  Subscription/OAuth-Nutzung.
- **Mission-Assembly:** hartkodierte „Langertha, viking shield-maiden“-Basis (listet Tools
  statisch, unvollständig) → `<root>/.raider.md` → geladene Skills → aktive Packs.
- **CLAUDE.md / AGENTS.md: opt-in.** `--claude` (CLAUDE.md + `.claude/skills/*/SKILL.md`),
  `--openai`/`--codex` (AGENTS.md), `--skills DIR`; Wahl wird in `.raider.yml` gespeichert.
  Nur Root-Ebene, kein Parent-Walk, kein `~/.claude`. Banner meldet „seeing X, ignoring“.
- Packs: ShareDir → Pfad relativ zu `$INC{CLI.pm}` → `$RAIDER_PACK_DIRS`. **Keine
  Projekt- oder Home-Pack-Verzeichnisse.**
- Hall: `<hall-root>/.raider-hall.yml`; jeder gespawnte Raider ist ein **frischer
  One-Shot-Subprozess** `raider --json --root <hall-root> -- <mission>` → alle Raider
  teilen einen Kontext (`.raider.md` der Hall), **keine Konversations-Persistenz** pro
  Slot zwischen Missionen.

### 3.3 Laufzeit-Oberflächen

- `raider [opts] [prompt]`: REPL (TTY), One-Shot (argv/stdin), `--json`. Slash-Commands:
  `/help /clear /metrics /stats /reload /prompt /skill /skill-claude /model /packs /pack
  /quit`.
- `raider hall …` / `raider-hall`: init, add-raider, start [--daemon], stop, status, ps,
  spawn, attach, logs, kill, install (systemd, nativ/Docker).
- Hall-Control: JSONL über UNIX-Socket; Events `hall.*`, `raider.*`, `telegram.*`.
- Telegram: Multi-Bot Long-Poll, Allowlist, Routing; Text wird komplett zur Mission,
  Raider soll selbst `telegram_reply` aufrufen.
- Cron: Schedule::Cron nur zur Zeitberechnung, IO::Async-Timer, Coalesce.
- ACP-Server (in Hall): JSON-RPC über **TCP**, nur `initialize`, `session/new`,
  `session/prompt` (nur Text), `session/cancel`. **Nicht spec-konform** (echtes ACP = stdio;
  kein `fs/*`, `terminal/*`, Permissions). Zed kann so nicht andocken.
- knarr `Handler::Raider` stellt bereits Raider-pro-Session hinter
  OpenAI/Anthropic/Ollama/A2A/ACP/AG-UI bereit (Model-ID `langertha-raider`) — der
  existierende „Raider als Server“-Weg, überlappt mit Hall-ACP und der Webserver-Idee.

### 3.4 Kopplung an langertha-Core

- Genutzt: `Role::{PluginHost,Runnable,Embedding}`, `Plugin`, `RunContext`, 10
  `Engine::*` (via CLI-Map), Engine-API (`build_tool_chat_request`, `parse_response`,
  `response_tool_calls`, `format_tool_results`, …).
- **Privat-Zugriffe:** `_async_http` (4×), `_langfuse_timestamp` (9×). Provider-spezifisches
  Usage-Parsing dreifach selbst gemacht (Raider.pm ×2, Plugin::Trace).
- Core behält weichen `use Langertha 'Raider'`-Sugar und `->isa('Langertha::Raider')`
  in `Plugin.pm`.

### 3.5 Abhängigkeiten (cpanfile)

Langertha 0.503 (noch nicht auf CPAN — muss vor Raider released werden), Net::Async::MCP
0.004, MCP::Server, MCP::Run::Bash 0.106, Net::Async::WebSearch 0.003, Net::Async::HTTP,
IO::Async, Future(::AsyncAwait), Moose, YAML::PP, JSON::MaybeXS, Schedule::Cron,
HTML::TreeBuilder, IPC::Run, Path::Tiny, File::ShareDir, Term::ANSIColor,
IO::Prompt::Tiny u.a.

---

## 4. Chaos-Inventar (mit Belegen)

**Bugs / tote Verdrahtung**
- ~~`--claude`/`--openai`/`--codex` crashten~~ (Rename-Regression, gefixt in `079f335` + Regressionstest `t/26_cli_profiles.t`).
- Hall-MCP-Adapter tot: `_setup_mcp_socket` leer (`Hall.pm`), `.raider-hall.mcp` wird nie
  erzeugt; `Hall::MCP` nur im Test instanziiert. `plugins/claude-code/SKILL.md` und
  Example dokumentieren ein nicht existierendes Feature.
- Hall-Raider-Config: `persona` wird geschrieben, nie gelesen; `mcp`, `isolated` gelesen
  und ignoriert; `preferred_lib_target` nie gelesen.
- Pack-Felder `extra_mcp`, `add_allowed_commands`, `engine_options` geladen, nie genutzt.
- Plugin-Self-Tools möglicherweise doppelt gelistet (inline-MCP + direkt; ungeprüft).
- `hall start --daemon DIR` nimmt cwd statt DIR (Args vor GetOptions ausgewertet).
- `reload_mission` schreibt am Moose-Read-Only-Accessor vorbei in den Hash.
- Pack-Discovery hängt an `$INC{'Langertha/Raider/CLI.pm'}`.

**Duplikation**
- Zwei MCP-Client-Klassen parallel (`Raider::MCP`-Subklasse vs. plain `Net::Async::MCP`);
  installiertes Net::Async::MCP 0.005 spricht das Protokoll bereits selbst → Subklasse
  vermutlich obsolet (karr k9).
- `.raider.yml` fünfmal geparst, kein Config-Objekt.
- Zwei „CLIs“: `bin/raider` (App-Logik) und `Raider::CLI` (Builder).
- Skill-Quellen-Auflösung zweimal; Tool-Liste im Prompt vs. echte MCP-Server getrennt
  gepflegt; drei Engine-Tabellen (Model/Env/Klasse) getrennt.

**Große Dateien, gemischte Verantwortung:** `Raider.pm` (2214), `Hall.pm` (755),
`Hall/CLI.pm` (669), `bin/raider` (865).

**Naming-Reste:** MCP-Server `app-raider-{files,web,perl,hall}`, Skill-Default
`app-raider` (+ Pfad `.claude/skills/app-raider/`), Docker `raudssus/raider` (karr k6,
k10). `Langertha::Raid*` vs. `Langertha::Raider::*` in zwei Namespaces. Tools sind
Funktionen, Hall-Teile Klassen. Personas heißen im Code „packs“, in Hall/README
„persona“. Default-Persona-Text in CLI.pm hartkodiert.

**Testlücken:** `bin/raider` gar nicht getestet (REPL, Slash-Commands, Profile, `--json`);
keine Tests für Situation, Trace, HallTools, ACP::CLI, Hall::CLI; Telegram/Cron nicht
end-to-end; `Raider::MCP` nur im (geskippten) Live-Test.

---

## 5. Offene Fragen für den Planer

**Produkt & Architektur**
1. Wie werden Assistent (Home, persistent, überall erreichbar) und Projekt-Agent
   (Projekt-Kontext, Coding) sauber getrennt und doch ein Werkzeug? Ein Prozess mit
   Modi? Ein Daemon (Hall-Nachfolger) + dünne Clients?
2. Kontext-Modell: Schichten (Home → Projekt → Session), Präzedenz, Isolation („keine
   Pollution“), automatisches Laden von `CLAUDE.md`/`AGENTS.md`/`.raider` inkl.
   Parent-Walk? Wie verhält sich Home-Gedächtnis (Hermes-artig) zu Projekt-Gedächtnis?
3. Config-Modell: ein Config-Objekt, Dateinamen/-orte (`~/.raider/`,
   `~/.config/raider/`, `<proj>/.raider/`?), Migration von `.raider.yml`/`.raider.md`.
4. Persistenz: Hall-Raider sind heute One-Shot-Subprozesse ohne Gedächtnis — soll der
   Assistent langlebige Sessions haben? Wie passt ADR 0007 (zwei History-Ebenen) dazu?
5. „Async UND rundenbasiert“ — was genau, und wie im Loop-Design?
6. Oberflächen-Schnitt: CLI, Daemon, Messaging, Cron, ACP (stdio, spec-konform, am
   Agenten), Webserver — wie teilen sie sich einen Kern? Verhältnis zu knarr
   `Handler::Raider` (Raider-als-Server existiert dort schon).
7. Remote-/Sub-Agenten: Agenten in anderen Verzeichnissen/Hosts starten und über ACP
   (stdio-über-SSH) steuern.
8. Engine-Schnitt: `Raider.pm` zerlegen (Loop, History/Kompression, Recall, Katalog,
   Self-Tools, Langfuse). Was braucht Core an öffentlicher API, damit Privat-Zugriffe
   (`_async_http`, `_langfuse_timestamp`) und dreifaches Usage-Parsing verschwinden?
   (→ Tickets auf dem langertha-Board.)
9. Tools/Packs/Skills vereinheitlichen: Personas vs. Packs vs. Skills; Home- und
   Projekt-Pack-Verzeichnisse; tote Pack-Felder entweder umsetzen oder streichen.

**Provider-Discovery**
10. Manifest-Schema (`raider.json` vs. generisch `langertha.json`), Versionierung.
11. Vertrauen/Sicherheit: ein Remote-Manifest, das Tools (MCP) und Prompts einspeist, ist
    ein Angriffsvektor — Signierung? Bestätigung beim ersten Verbinden? Scopes?
12. Bezug zu bestehenden Standards (MCP-Server-Discovery, OAuth-Metadata unter
    `.well-known`, OpenAI-kompatibles `/v1/models`).
13. Sollen knarr/skeid Raider-spezifisches (Packs/Skills/Mission) ausliefern oder nur
    Engines/Modelle/MCP? Wo genau liegt das Schema in Core?

**Public API & Distribution**
14. Was ist öffentliche API (Engine-Klasse, Raid, Plugins, Tool-Builder) vs.
    App-Interna? (Maintainer 2026-09-20: „schauen wir mal, erstmal reden“.)
15. Namen: `app-raider-*`-Identifier, Docker-Image, `Langertha::Raid*`-Namespace.

---

## 6. Randbedingungen

- Perl, Moose, IO::Async/Future(::AsyncAwait), MCP (MCP::Server, Net::Async::MCP),
  `[@Author::GETTY]`-Dist, Test2::V0. Tests ohne Live-Keys/-Server.
- Einweg-Abhängigkeit: langertha-raider → langertha, nie zurück. Generisches Tool-Calling-
  Fundament (`Role::Tools`, `Plugin`, `Chat`, …) bleibt in Core.
- Cross-Repo-Arbeit (langertha, knarr, skeid) = Tickets auf deren karr-Boards.
- Releases nur mit expliziter Freigabe des Maintainers.

## 7. Quellen

- Dieses Repo: `TODO.md`, `MIGRATION-FROM-LANGERTHA.md`, `README.md`, `Changes`,
  karr-Board (`karr list`).
- Altes Repo (archiviert): `~/dev/raider` / github.com/Getty/raider.
- langertha: `docs/adr/0007-raider-two-tier-history.md`,
  `0008-raider-control-surface-as-virtual-self-tools.md`,
  `0026-raider-extracted-to-sibling-distribution.md`.
- knarr: `lib/Langertha/Knarr/Handler/Raider.pm`. skeid: README.
- Claude-Code-Sessions: Definitions-Diskussion 2026-09-20/21 (Projekt raider,
  Session 28e40132), Split-Entscheidung 2026-09-17 (perl-developer, 4bd165bd),
  ACP/Remote-Hosts-Idee 2026-09-05 (perl-developer, e642cdc6), diese Session
  2026-09-24 (a9b4621a).
