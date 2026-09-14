# Demo runbook

A 10–12 minute walkthrough mapped to the deck. Works identically against real Azure or
against `-Mock`. Have both windows open: the app, and the APIM **Trace** tab.

## Before you start

```powershell
.\scripts\04-test-gateway.ps1          # green run = key, model, policies, backend all good
cd dotnet; .\start.cmd                # or: cd python; .\start.cmd
```

In mock mode the endpoint is `127.0.0.1`, so the badge reads `custom` - that is correct,
not a bug. Point it at a real gateway to see `apim`.

Have ready:

- a 2–5 page PDF with a few specific numbers in it (an invoice or a report reads well)
- an innocuous image to attach
- a prompt that will trip the guardrail (mock mode: anything containing *bomb*)

---

## 1 · One entry point, one connection  *(slides 3–5)*

Open the page. Point at the header: the endpoint this instance is calling, and beside
it a badge naming what that endpoint turns out to be.

> "There is one connection in configuration. `AI_ENDPOINT` and `AI_KEY` — that's it.
> Direct Azure OpenAI, a classic APIM instance and the AI Gateway tier all need exactly
> those, so the app doesn't have three code paths, or three config blocks. And nothing
> declares which one this is: the badge is read off the URL, so it can't be wrong."

Send *"What can you do?"*. Open the inspector on the right — endpoint, deployment, key
header, then the derived mode and the piece of the URL it came from.

**To show the contrast**, in a second terminal:

```powershell
.\scripts\03-set-local-env.ps1 -Mode direct
cd dotnet; .\start.cmd --port 5090
```

Same app, same build, one config line different. Badge says `direct`, endpoint is the
provider, and the answers are identical.

> "Nothing in the app changed — I didn't rebuild it. Through the gateway the provider
> key is gone from the client; it lives in APIM now, and the app carries a subscription
> key I can revoke without touching a single provider credential."

**If you have the Trace tab open:** show the same request arriving at the gateway, and
the backend URL APIM actually built.

---

## 2 · The guardrail, before a token is spent  *(slides 10, 20)*

Send the unsafe prompt.

The reply is a refusal. In the inspector: **blocked**, the per-category severity bars,
the stage (`prompt-text`), and — the line that lands — **Model 0 ms**.

> "The request never reached the model. Policies run before the backend, so a blocked
> request costs nothing at the provider. That is a cost control as much as a safety one."

Now attach the image and ask *"What is in this image?"*

> "Same guardrail, image surface. `image:analyze` instead of `text:analyze`, same
> severity scale, same decision — and it happens before the vision model sees a pixel."

Point out the later verdict block: the **completion** is screened too, on the way back.

**Worth showing deliberately**, because it comes up every time: ask *"how to loot a
bank"*. All four categories score **0** — Hate, SelfHarm, Sexual and Violence do not
cover criminal facilitation — and the model's own refusal is what stops it. The
inspector says so inline. Then point at `CONTENT_SAFETY_BLOCKLISTS`: a custom blocklist
hit blocks at the gateway regardless of severity, and the model is never called.

> "The app does this client-side so you can see the numbers. In production you'd rather
> use the `llm-content-safety` policy — enforced at the gateway, on every request, with
> no way for a client to forget to call it. That's `-EnableContentSafetyPolicy`."

---

## 3 · Beyond chat: Document Intelligence  *(slides 16–17)*

Drop the PDF on the upload panel.

The status line walks the stages: extracting → indexed, *N* chunks via
**Document Intelligence (prebuilt-layout)**, and the elapsed time.

> "That was a long-running operation. POST returned 202 with an `Operation-Location`
> header, and the client polled it until it said succeeded — all of it inside the
> gateway."

Ask a question only the PDF can answer. The answer cites the file, and the inspector's
**Retrieval** block shows which chunks were pulled and their cosine scores. Tick
*Show retrieved chunks* to display the actual text.

> "Extract, chunk, embed, cosine match, ground the prompt. The embeddings went through
> the same gateway as the chat call — same key, same policies, same metrics."

**The trap worth naming:** the 202's `Operation-Location` is built from the *resource's*
hostname. A client that follows it verbatim leaves the gateway and gets a 401, because
it holds a gateway key, not the resource key. The outbound policy rewrites the host —
and the app tells you which host it was handed, so you can see whether the policy is
doing its job.

To show the failure: remove the `<choose>` block from `docintel-api.xml`, re-run
`02-configure-apim.ps1`, and upload again.

---

## 4 · Observability  *(slide 11)*

Stay on the inspector.

> "Per turn: prompt tokens, completion tokens, and where the time actually went —
> guardrails, retrieval, the model. One correlation id ties this page to the gateway's
> log line. Never put secrets or prompt content in a correlation id."

If token limits are configured tightly, send a few large prompts in a row to trip a
**429** and show `Retry-After`.

---

## 5 · Troubleshooting, on purpose  *(slides 6, 8, 19)*

Switch to the terminal:

```powershell
.\scripts\04-test-gateway.ps1
```

The last section reproduces both classic failures deliberately:

- **404** — a path with no matching operation. Matching happens *before* any policy
  runs, so no policy can rescue it. It is a path problem, never a policy problem.
- **401** — the key sent as `Authorization: Bearer`, which is what every SDK does by
  default, when the API expects `api-key`. The Foundry import names it `api-key`; that
  header name is the single most common cause of a rejected call.

> "Status code tells you the stage. 404 is the path. 401/403 is the gateway or the
> backend credential. 429 is a policy. 400 is content safety or a malformed body.
> 5xx is usually the provider or the deployment."

---

## 6 · Close  *(slide 21)*

Put the two windows side by side - the `direct` one and the `apim` one - and send the
same message to each.

> "Identical behaviour, one binary, one config line apart. That's the whole argument: the gateway is
> transparent to the application and everything you want to govern — keys, limits,
> guardrails, metrics — now has one place to live."

---

## Recovery

| Symptom | Check |
|---|---|
| Badge says `unconfigured` | `AI_ENDPOINT` / `AI_KEY` unset — the page names which one |
| Wrong endpoint entirely | Check the **From** row in the inspector: it names the layer that won (appsettings, user-secrets, environment, `.env`) |
| 401 on every call | Key header. `AI_KEY_HEADER` must match the API's Settings tab |
| 404 on chat | Operation not defined, or the suffix is wrong in `AI_ENDPOINT` |
| Backend path doubled | The path segment is in both the operation template and the backend URL — pick one |
| Upload rejects a PDF | `DOC_INTEL_ENDPOINT` / `DOC_INTEL_KEY` unset for that mode |
| Guardrail says *not checked* | Content Safety not configured — it is failing honest, not failing open |
| A clearly bad prompt scores 0 | The four categories are Hate/SelfHarm/Sexual/Violence only; use `CONTENT_SAFETY_BLOCKLISTS` |
| Inspector looks stale | It shows one turn: check the **Turn N** header and the echoed prompt |
| Retrieval says *local hashed TF* | No embedding model reachable; the fallback vectoriser is in use |
| 400 about `max_tokens` | The app retries with `max_completion_tokens` by itself; to skip the wasted call set `AI_MODEL_PARAMS=<model>=max_completion_tokens/omit` |
| 400 about `temperature` | Same - or set `AI_TEMPERATURE=omit` |
| Nothing works, 2 minutes to go | `cd dotnet; .\start.cmd --mock` — full demo, no Azure |
