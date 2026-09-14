# Fronting the Azure AI Stack with Azure API Management

A one-page chat app that demonstrates the gateway pattern from the talk, built twice —
once in **.NET 10 Razor Pages**, once in **Python / FastAPI** — against the same JSON
contract and the same front end.

The point it makes: **the application code does not change when you put a gateway in
front of your AI services.** Direct Azure OpenAI, a classic APIM instance and the AI
Gateway tier all need the same three things - an endpoint, a deployment and a key - so
there is exactly one connection in config. Point `AI_ENDPOINT` at whichever you like;
nothing else changes. The page works out which of the three that endpoint is **from the
URL itself** and shows it, so the badge can never disagree with what is really happening.

```
                          ┌─────────────────────────┐
  Browser  ──────────────▶│  Razor app  /  FastAPI   │
  one page, no build      │  identical wwwroot/app.js│
                          └────────────┬─────────────┘
                                       │  AI_ENDPOINT + AI_KEY
                                       │  (the only thing that differs;
                                       │   the mode is read off the URL)
              ┌───────────────────────┼──────────────────────┐
              ▼                        ▼                        ▼
   *.openai.azure.com        *.azure-api.net/x        *.azure-api.net/x/models
      -> "direct"               -> "apim"                -> "aigateway"
      app holds the key         app holds a              routing by model
      no throttling, no         revocable sub key        name in the body
      shared cost view          policies, metrics        (public preview)
              └───────────────────────┼──────────────────────┘
                                       ▼
            Azure OpenAI  ·  Content Safety  ·  Document Intelligence
```

## What the demo shows

| Slide | In the app |
|---|---|
| One governed entry point | One connection in config; the header badge names what that endpoint actually is |
| Auth & the header gotcha | Inspector shows the exact key header the endpoint expects |
| Model differences | `max_tokens` vs `max_completion_tokens` and temperature resolved per model, shown in the inspector |
| AI gateway policies | Token usage and remaining-budget headers per turn |
| Guardrails (text **and** image) | Every prompt, attached image and completion scored 0–6 per category, blocked at ≥ 4 before the model is called, plus custom blocklists and Prompt Shields |
| Beyond chat: Document Intelligence | Upload a PDF → 202 + `Operation-Location` → poll → markdown → chunk → embed → in-memory semantic index |
| The `Operation-Location` rewrite | The app reports which host it was told to poll, so a missing rewrite policy is visible |
| Observability | Per-turn correlation id, guardrail / retrieval / model latency split out; the inspector names the turn it describes and shows the pipeline order |
| Troubleshooting | `04-test-gateway.ps1` reproduces the 404 and the 401 on purpose |

## Layout

Two independent stacks. Each has its own backend, its own copy of the UI, its own
launcher and its own port - nothing is shared at runtime.

```
.env.example              Shared configuration template (copy to .env at the root)
start.cmd  start.sh       Dispatcher - saves a cd, nothing more

dotnet/
  start.cmd  start.sh     Runs the .NET stack        http://localhost:5080
  AiGatewayDemo/          Razor Pages + minimal API + wwwroot (its own UI)

python/
  start.cmd  start.sh     Runs the Python stack      http://localhost:8080
  app.py  services/       FastAPI + static/ (its own UI)

scripts/                  Azure only: provision → configure → configure locally → test
                          PowerShell + az throughout; nothing here runs Python
  policies/               The APIM policy XML, commented
tools/
  mock-azure-ai.py        Offline stand-in for all three Azure services, used by --mock
tests/
  verify-apps.py          Runs both stacks against the mock and compares them
  test-mode-detection.py  Both stacks must derive the same mode from the same URL
  test-model-params.py    max_tokens vs max_completion_tokens, per model
```

### Ports

Nothing overlaps, so you can have both stacks and every test suite running at once.

| | .NET | Python |
|---|---|---|
| App | **5080** (7080 https) | **8080** |
| `verify-apps.py` | 5181 | 8181 |
| `test-model-params.py` | 5182 | 8182 |
| `test-mode-detection.py` | 5183 | in-process |
| Mock Azure AI | — | 5290 |

Override an app port with `--port`.

Each stack serves its own copy of the UI - there is no shared web server. The files are
byte-identical: `python/static/` is the source of truth, `dotnet/.../wwwroot/` holds the
copies, and `Pages/Index.cshtml` is the same markup with a two-line Razor header.
`scripts/sync-frontend.ps1` copies and verifies them.

## Quick start

Clone it and run one command. With no configuration present, both launchers fall back
to the offline mock automatically, so the demo works before any Azure resource exists.

**Windows**

```bat
cd dotnet  &  .\start.cmd          :: .NET stack      http://localhost:5080
cd python  &  .\start.cmd          :: Python stack    http://localhost:8080

.\start.cmd                        :: or from the root: same as dotnet
.\start.cmd python                 ::                   same as python
.\start.cmd both                   :: both at once, on their own ports
.\start.cmd verify                 :: run the test suite against the mock
```

> Call it as `.\start.cmd`. A bare `start` runs cmd's built-in START command — internal
> commands win over files of the same name. Double-clicking it in Explorer is fine.

**macOS / Linux / WSL**

```bash
chmod +x start.sh dotnet/start.sh python/start.sh   # once

cd dotnet && ./start.sh     # .NET stack      http://localhost:5080
cd python && ./start.sh     # Python stack    http://localhost:8080

./start.sh                  # or from the root: same as dotnet
./start.sh python           #                   same as python
./start.sh both             # both at once, on their own ports
./start.sh verify           # run the test suite against the mock
```

Every launcher accepts `--mock`, `--port N` and `--no-browser`; the Python one also
takes `--reload`. The root `start.cmd` / `start.sh` only forward to the stack launchers,
so there is nothing in them you would miss by running a stack directly. The `.sh` files
are written for the bash 3.2 that macOS ships.

### Rehearse offline — no Azure, no spend

`--mock` (or no configuration at all) starts `tools/mock-azure-ai.py`, which imitates
Azure OpenAI, Content Safety and Document Intelligence closely enough to drive the whole
demo. The words *bomb*, *attack*, *kill* or *weapon* in a prompt trip the guardrail, and
any upload that is not plain text goes through the full 202-and-poll Document
Intelligence path.

Each stack falls back to the mock on its own when it finds no configuration, so a
fresh clone runs either way:

```powershell
cd dotnet  &  .\start.cmd --mock
cd python  &  .\start.cmd --mock
```

### Against real Azure

```powershell
az login

# ~5 min for the AI services; APIM Developer SKU takes 30-45 min in the background.
.\scripts\01-provision-azure.ps1 -Prefix nashuaug-demo -PublisherEmail you@contoso.com

# Waits for APIM, then creates named values, backends, APIs, operations,
# policies and one subscription key.
.\scripts\02-configure-apim.ps1

# Writes python\.env and dotnet\AiGatewayDemo\appsettings.Development.json,
# keeping any previous copy as .bak. -Mode picks the endpoint.
.\scripts\03-set-local-env.ps1 -Mode apim

# Proves the gateway on its own, before an app touches it.
.\scripts\04-test-gateway.ps1

cd dotnet; .\start.cmd             # or: cd python; .\start.cmd
```

Tear down with `.\scripts\99-cleanup.ps1 -Purge`.

## Configuration

One flat set of keys drives both stacks. `03-set-local-env.ps1` generates both files
from the same values, into the place each app actually reads:

| Stack | File | Read by |
|---|---|---|
| Python | `python/.env` | `python-dotenv` |
| .NET | `dotnet/AiGatewayDemo/appsettings.Development.json` | the configuration chain |

They go in the stack folders rather than the repo root because a root file is silently
shadowed: Python takes `python/.env` first, and .NET ranks `appsettings.Development.json`
above every `.env`. A root `.env` is still read by both as a last resort, so a hand-made
shared file works when no stack-local one exists — but it can never override one.
Environment variables and `dotnet user-secrets` win over everything. Whatever wins, the
page's Connection panel names it. See `.env.example` for the full list.

Re-running the script replaces both files and keeps the previous copy as `<name>.bak`,
so a hand-edited config survives. `.gitignore` covers the generated files and the
backups — they hold real keys.

Direct Azure OpenAI, a classic APIM instance and the AI Gateway tier each need an
endpoint, a deployment and a key - nothing more, and nothing different. So there is
**one connection**, not one block per flavour:

```ini
AI_ENDPOINT=https://my-apim.azure-api.net/aoai   # or the resource, or the AI Gateway
AI_KEY=...
AI_KEY_HEADER=api-key         # not Ocp-Apim-Subscription-Key
AI_CHAT_MODEL=gpt-4o          # deployment, or the model asset name on the AI Gateway
AI_EMBEDDING_MODEL=text-embedding-3-small

# Point these at the resources, or at the gateway's paths for them.
CONTENT_SAFETY_ENDPOINT=...   CONTENT_SAFETY_KEY=...
DOC_INTEL_ENDPOINT=...        DOC_INTEL_KEY=...
```

There is deliberately **no `AI_MODE`**. How you are connected is derived from the
endpoint, so a stale or mistyped label can never mislead an audience:

| `AI_ENDPOINT` | Reported as |
|---|---|
| `*.openai.azure.com`, `*.cognitiveservices.azure.com`, `*.services.ai.azure.com`, `api.openai.com` | `direct` |
| `*.azure-api.net/<suffix>` | `apim` |
| `*.azure-api.net/<workspace>/models` | `aigateway` |
| anything else (self-hosted, OpenAI-compatible, the demo mock) | `custom` |
| empty | `unconfigured` |

The header badge shows the derived mode next to the endpoint, and the inspector's
Connection block names the part of the URL the decision was made on. To show the
contrast in a talk, re-run `03-set-local-env.ps1 -Mode direct` and restart; the app
code is untouched, which is the whole argument.

`tests/test-mode-detection.py` checks both implementations against that table case
by case, since the logic exists in two languages and would otherwise drift.

### Request parameters differ by model

Older chat models take `max_tokens`. The newer reasoning families reject it outright:

```
400: Unsupported parameter: 'max_tokens' is not supported with this model.
     Use 'max_completion_tokens' instead.
```

and several of them also accept only their default temperature. So the payload is
assembled from a resolved parameter set, in four layers - most specific first:

1. `AI_MODEL_PARAMS` - an explicit per-model map, always wins
2. `AI_TOKEN_PARAM` / `AI_TEMPERATURE` / `AI_MAX_TOKENS` - global defaults
3. a name heuristic: `o1*`, `o3*`, `o4*`, `gpt-5*` get `max_completion_tokens` and no temperature
4. the provider itself - a 400 naming the right parameter is acted on, remembered for
   the process, and the call retried (up to twice, since a model that rejects
   `max_tokens` usually rejects the temperature too)

```ini
AI_TOKEN_PARAM=max_tokens      # or max_completion_tokens
AI_MAX_TOKENS=800
AI_TEMPERATURE=0.2             # `omit` sends no temperature at all

# Per-model, beats everything above. Compact or JSON, one line either way:
AI_MODEL_PARAMS=gpt-5.6-terra=max_completion_tokens/omit, gpt-4o=max_tokens/0.2
```

Layer 4 means an unrecognised deployment name costs one wasted round trip and then
works; layers 1-3 mean it need not cost even that. The inspector's **Request
parameters** block shows what was sent and which layer decided it.

`tests/test-model-params.py` covers all four layers in both apps.

`/openai/v1` is appended automatically if the endpoint does not already end with it, so
the same value works for a bare resource and for an APIM suffix. The key header for
Content Safety and Document Intelligence is inferred from their endpoints - a
`*.azure-api.net` host takes `AI_KEY_HEADER`, anything else takes
`Ocp-Apim-Subscription-Key` - and either can be overridden with
`CONTENT_SAFETY_KEY_HEADER` / `DOC_INTEL_KEY_HEADER`.

**Precedence**, lowest to highest: `appsettings.json` → `appsettings.Development.json`
→ user-secrets → environment variables. The `.env` file fills in only what is still
empty after all of those, so it never silently overrides something you set deliberately.

`appsettings.Development.json` is **git-ignored** — it is the natural place to drop a
local `AI_ENDPOINT` and `AI_KEY`, and the app reads it, so it is treated as a secret
file. Copy the tracked `appsettings.Development.example.json` over it to get the
development defaults (verbose logging, detailed errors, and `HttpClient` logging so the
console shows each outbound call).

`Properties/launchSettings.json` **is** tracked — no secrets in it, and it is what puts
the app in the Development environment at all, which is also what makes
`dotnet user-secrets` load. Its `http` profile deliberately sets no `applicationUrl`, so
`--port` and `ASPNETCORE_URLS` still win.

Whichever layer supplies `AI_ENDPOINT`, the page's **Connection** panel names it — so a
value you did not expect to win is visible rather than mysterious.

Anything unconfigured degrades honestly rather than failing: with no endpoint the page
says so and names the missing variable, missing Content Safety shows *not checked* instead
of a false *allowed*, and with no embedding model the index falls back to a local hashed
term-frequency vector and says so in the inspector.

## How a turn works

1. **Guardrail the prompt.** `text:analyze`, plus `image:analyze` when an image is
   attached, plus `text:shieldPrompt` when Prompt Shields is on. Severity ≥ 4 in any
   category, a custom blocklist hit, or a detected jailbreak returns a refusal — the
   model is never called, so a blocked request costs nothing at the provider.

   **What the four categories do not cover.** They are Hate, SelfHarm, Sexual and
   Violence. A prompt like *"how to loot a bank"* scores **0 on all four** — criminal
   facilitation is not one of those harms, so no threshold catches it, and what stops
   it is the model's own refusal. To block it at the gateway instead, put the terms in
   a Content Safety custom blocklist and set `CONTENT_SAFETY_BLOCKLISTS`: a blocklist
   hit blocks regardless of severity. The inspector says all this inline when it sees
   four zeros, so it reads as a designed boundary rather than a broken guardrail.
2. **Retrieve.** The question is embedded over the same connection and cosine-matched
   against the in-memory chunk index; the top 4 hits become grounding context.
3. **Call the model.** One payload shape, sent to whichever base URL the route carries.
4. **Guardrail the completion.** The reply is screened too, before it reaches the page.

Every stage reports its own latency, and the whole turn carries one `x-correlation-id`
so a gateway log line ties back to the app trace.

## Document Intelligence and the `Operation-Location` trap

`.txt`, `.md`, `.csv` and `.json` are parsed locally — no reason to spend a page on them.
Everything else (PDF, images, Office documents) goes to `prebuilt-layout` with
`outputContentFormat=markdown`.

The 202 response carries an `Operation-Location` built from the **resource's** hostname.
A client that follows it verbatim leaves the gateway and gets a 401, because it holds a
gateway key rather than the resource key. `scripts/policies/docintel-api.xml` rewrites
the host back to the gateway on the way out; the app reports which host it was actually
handed, so you can show the policy working — or show the 401 by removing it.

## Guardrails: app-side or policy-side

The app calls Content Safety itself so the per-category severities can be shown in the
UI. Production usually wants the other option: `llm-content-safety` in the APIM policy,
enforced on every request with no client code and no way for a client to skip it.

```powershell
.\scripts\02-configure-apim.ps1 -EnableContentSafetyPolicy
```

Running both means paying for two checks — pick one.

## Verifying

```powershell
python tools\mock-azure-ai.py            # terminal 1
python tests\verify-apps.py              # terminal 2
```

Starts both apps against the mock and asserts 30 behaviours each — routing, extraction,
polling, retrieval, token accounting, both guardrail stages, blocking before the model —
then compares the two JSON contracts key by key. All checks pass on the committed code.

## Notes

- The index is in-memory and per-process: a restart clears it. That is deliberate — the
  demo is about the gateway, not about a vector database.
- The AI Gateway tier is in public preview; its portal, model asset names and
  capabilities may change. A model name is a public contract — clients send it in the
  request body — so set names correctly at import.
- `.env` and `scripts/.deploy.json` hold secrets and are git-ignored. Prefer managed
  identity for backend auth in anything beyond a demo, and back named values with Key
  Vault so rotation is automatic.

---

Built for the talk *Fronting the Azure AI Stack with Azure API Management* —
Udaiappa Ramachandran ([udai.io](https://udai.io) · [Nashua Cloud .NET User Group](https://meetup.com/nashuaug)).
