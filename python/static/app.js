/* AI Gateway demo - shared front end (.NET Razor app and Python FastAPI app).
   Both backends expose the same JSON contract, so this file is byte-identical in both. */
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const el = {
    modeBadge: $("modeBadge"), connHost: $("connHost"), connModel: $("connModel"),
    messages: $("messages"), prompt: $("prompt"), send: $("send"),
    clearChat: $("clearChat"), imageInput: $("imageInput"), attachPreview: $("attachPreview"),
    attachThumb: $("attachThumb"), attachRemove: $("attachRemove"), fileInput: $("fileInput"),
    dropzone: $("dropzone"), uploadStatus: $("uploadStatus"), docList: $("docList"),
    indexStats: $("indexStats"), clearIndex: $("clearIndex"),
    useRag: $("useRag"), showRetrieval: $("showRetrieval"),
    inspector: $("inspector"),
  };

  // Turns are kept whole - {user, assistant, sources, nodes} - rather than as a flat
  // message list, so that removing a document can drop exactly the turns it grounded.
  const state = { config: null, turns: [], attachment: null, busy: false, turn: 0 };

  // What actually goes to the model: the last few turns, flattened, minus anything
  // whose source document has since been removed.
  const modelHistory = () =>
    state.turns.slice(-5).flatMap((t) => [
      { role: "user", content: t.user },
      { role: "assistant", content: t.assistant },
    ]);

  // Deleting a document has to do two things: drop its chunks from the index (the
  // server side), and stop replaying answers built from it back to the model. Without
  // the second the model keeps "remembering" a document you just removed.
  function forgetDocuments(names) {
    const doomed = state.turns.filter((t) => t.sources.some((src) => names.includes(src)));
    state.turns = state.turns.filter((t) => !doomed.includes(t));
    for (const turn of doomed) {
      // Left on screen - the transcript is the demo - but marked as no longer sent.
      for (const node of turn.nodes || []) node.classList.add("forgotten");
    }
    return doomed.length;
  }

  /* ── helpers ──────────────────────────────────────────────────── */
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const bytes = (n) => n < 1024 ? `${n} B`
    : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(1)} MB`;

  async function api(path, options = {}) {
    const res = await fetch(path, options);
    const text = await res.text();
    let body = null;
    try { body = text ? JSON.parse(text) : null; } catch { body = { error: text }; }
    if (!res.ok) throw new Error(body?.error || body?.detail || `${res.status} ${res.statusText}`);
    return body;
  }

  /* ── connection chip ────────────────────────────────── */
  // Nothing here is configured. The mode is derived from AI_ENDPOINT, so the badge
  // cannot disagree with what the app is actually talking to.
  function renderConnection(c) {
    el.modeBadge.textContent = c.mode;
    el.modeBadge.className = `mode-badge ${c.mode}`;
    el.modeBadge.title = `${c.label} - derived from ${c.evidence}\n\n${c.note}`;

    el.connHost.textContent = c.enabled ? c.chatBaseUrl : "not configured";
    el.connHost.title = c.enabled ? c.chatBaseUrl : c.reason;
    el.connModel.textContent = c.enabled
      ? `${c.model} \u00b7 ${c.keyHeader}`
      : c.reason;
  }

  /* ── documents ────────────────────────────────────────────────── */
  async function refreshDocs() {
    const data = await api("/api/documents");
    el.docList.innerHTML = "";
    for (const d of data.documents) {
      const li = document.createElement("li");
      li.innerHTML =
        `<div class="grow"><div class="name">${esc(d.name)}</div>` +
        `<div class="meta">${d.chunks} chunks &middot; ${bytes(d.sizeBytes)} &middot; ${esc(d.extractedVia)}` +
        (d.pages ? ` &middot; ${d.pages} page${d.pages === 1 ? "" : "s"}` : "") + `</div></div>`;
      const x = document.createElement("button");
      x.className = "x"; x.type = "button"; x.innerHTML = "&times;";
      x.title = "Remove from index";
      x.onclick = async () => {
        await api(`/api/documents/${d.id}`, { method: "DELETE" });
        const dropped = forgetDocuments([d.name]);
        await refreshDocs();
        announce(`Removed ${d.name}.`, dropped);
      };
      li.appendChild(x);
      el.docList.appendChild(li);
    }
    el.indexStats.textContent = data.documents.length
      ? `${data.totalChunks} chunks indexed - vectors from ${data.embeddingMode}`
      : "Index is empty - questions go straight to the model.";
    el.clearIndex.hidden = data.documents.length === 0;
  }

  // Says what removing a document actually changed, since half of it is invisible.
  function announce(what, droppedTurns) {
    el.uploadStatus.hidden = false;
    el.uploadStatus.innerHTML = esc(what) + (droppedTurns
      ? ` ${droppedTurns} grounded turn${droppedTurns === 1 ? "" : "s"} dropped from the ` +
        `conversation, so the next question goes straight to the model.`
      : " The next question goes straight to the model.");
    setTimeout(() => { el.uploadStatus.hidden = true; }, 9000);
  }

  el.clearIndex.onclick = async () => {
    const data = await api("/api/documents");
    const names = data.documents.map((d) => d.name);
    for (const doc of data.documents) {
      await api(`/api/documents/${doc.id}`, { method: "DELETE" });
    }
    const dropped = forgetDocuments(names);
    await refreshDocs();
    announce(`Cleared ${names.length} document${names.length === 1 ? "" : "s"}.`, dropped);
  };

  async function uploadFiles(files) {
    for (const file of files) {
      el.uploadStatus.hidden = false;
      el.uploadStatus.innerHTML = `<span class="spin"></span>Extracting <b>${esc(file.name)}</b>...`;
      try {
        const fd = new FormData();
        fd.append("file", file);
        const doc = await api("/api/upload", { method: "POST", body: fd });
        el.uploadStatus.innerHTML =
          `Indexed <b>${esc(doc.name)}</b> - ${doc.chunks} chunks via ${esc(doc.extractedVia)} in ${doc.elapsedMs} ms`;
        await refreshDocs();
      } catch (e) {
        el.uploadStatus.innerHTML = `<span style="color:var(--bad)">Upload failed: ${esc(e.message)}</span>`;
      }
    }
    setTimeout(() => { el.uploadStatus.hidden = true; }, 8000);
  }

  el.fileInput.onchange = (e) => { uploadFiles([...e.target.files]); e.target.value = ""; };
  ["dragenter", "dragover"].forEach((ev) =>
    el.dropzone.addEventListener(ev, (e) => { e.preventDefault(); el.dropzone.classList.add("over"); }));
  ["dragleave", "drop"].forEach((ev) =>
    el.dropzone.addEventListener(ev, (e) => { e.preventDefault(); el.dropzone.classList.remove("over"); }));
  el.dropzone.addEventListener("drop", (e) => uploadFiles([...e.dataTransfer.files]));

  /* ── image attachment ─────────────────────────────────────────── */
  el.imageInput.onchange = (e) => {
    const file = e.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      state.attachment = reader.result;          // data: URL
      el.attachThumb.src = reader.result;
      el.attachPreview.hidden = false;
    };
    reader.readAsDataURL(file);
    e.target.value = "";
  };
  function clearAttachment() {
    state.attachment = null;
    el.attachPreview.hidden = true;
    // Drop the data: URL too - an <img> left with no src renders as a broken image.
    el.attachThumb.removeAttribute("src");
  }
  el.attachRemove.onclick = clearAttachment;

  /* ── chat rendering ───────────────────────────────────────────── */
  function addMessage(role, text, { image = null, blocked = false, citations = null } = {}) {
    const div = document.createElement("div");
    div.className = `msg ${role}${blocked ? " blocked" : ""}`;
    const cites = citations?.length
      ? `<div class="cites">Sources: ${citations.map((c) => esc(c)).join(", ")}</div>` : "";
    div.innerHTML =
      `<div class="avatar">${role === "user" ? "You" : "AI"}</div>` +
      `<div><div class="bubble">${image ? `<img class="att" src="${image}" alt="attachment" />` : ""}` +
      `${esc(text)}${cites}</div></div>`;
    el.messages.appendChild(div);
    el.messages.scrollTop = el.messages.scrollHeight;
    return div;
  }

  function addTyping() {
    const div = document.createElement("div");
    div.className = "msg assistant";
    div.innerHTML = `<div class="avatar">AI</div><div class="bubble typing"><span></span><span></span><span></span></div>`;
    el.messages.appendChild(div);
    el.messages.scrollTop = el.messages.scrollHeight;
    return div;
  }

  /* ── inspector ────────────────────────────────────────────────── */
  const sevClass = (s) => s >= 6 ? "s6" : s >= 4 ? "s4" : s >= 2 ? "s2" : "";

  function safetyBlock(title, verdict) {
    if (!verdict || !verdict.checked) {
      return `<div class="insp-section"><h3>${title}</h3>` +
        `<span class="pill info">not checked</span>` +
        `<div class="note">${esc(verdict?.reason || "Content Safety is not configured.")}</div></div>`;
    }
    if (verdict.error) {
      return `<div class="insp-section"><h3>${title}</h3><span class="pill warn">error</span>` +
        `<div class="note">${esc(verdict.error)}</div></div>`;
    }
    const rows = verdict.categories.map((c) =>
      `<div class="sev-row"><span class="cat">${esc(c.category)}</span>` +
      `<span class="sev-bar"><i class="${sevClass(c.severity)}" style="width:${(c.severity / 6) * 100}%"></i></span>` +
      `<span class="val">${c.severity}</span></div>`).join("");

    const hits = verdict.blocklistHits || [];
    const allZero = verdict.categories.length > 0 && verdict.categories.every((c) => c.severity === 0);

    let note = `Severity 0-6; blocked at &ge; ${verdict.threshold}.`;
    if (hits.length) {
      note = `Matched custom blocklist: <b>${hits.map((h) => esc(h)).join(", ")}</b>. ` +
             `A blocklist hit blocks regardless of severity.`;
    } else if (allZero && !verdict.blocked) {
      // The single most confusing result in a live demo: a clearly unwanted prompt
      // that scores 0. Say why, rather than letting it look broken.
      note += ` All four scored 0 - these categories cover Hate, SelfHarm, Sexual and ` +
              `Violence only. Requests like "how to do &lt;crime&gt;" are not one of them; ` +
              `use a custom blocklist (CONTENT_SAFETY_BLOCKLISTS) or rely on the model's ` +
              `own refusal, which is what you are seeing if the reply declined.`;
    } else if (verdict.reason && !verdict.categories.length) {
      note = esc(verdict.reason);
    }

    return `<div class="insp-section"><h3>${title}</h3>` +
      `<span class="pill ${verdict.blocked ? "bad" : "ok"}">${verdict.blocked ? "blocked" : "allowed"}</span> ` +
      `<span class="pill info">${esc(verdict.via)}</span> ` +
      `<span class="pill info">${verdict.latencyMs} ms</span>` +
      (hits.length ? ` <span class="pill bad">blocklist</span>` : "") +
      `<div style="margin-top:8px">${rows}</div>` +
      `<div class="note">${note}</div></div>`;
  }

  // The inspector always describes exactly one turn - the most recent. Nothing
  // accumulates. Two turns in a row can produce identical verdicts, so the header
  // states the turn number and the prompt: that is how you tell "unchanged" from
  // "not updated".
  function inspectorHeader(turn, promptLabel, outcome, outcomeClass) {
    const stamp = new Date().toLocaleTimeString();
    return `<div class="insp-section turn-head">` +
      `<h3>Turn ${turn} &middot; ${esc(stamp)}</h3>` +
      `<div class="turn-prompt">${esc(promptLabel || "(image only)")}</div>` +
      `<span class="pill ${outcomeClass}">${esc(outcome)}</span></div>`;
  }

  function setInspectorBusy(turn, promptLabel) {
    el.inspector.className = "insp-busy";
    el.inspector.innerHTML = inspectorHeader(turn, promptLabel, "running", "info") +
      `<div class="insp-section"><div class="note">Screening the prompt with Content Safety, ` +
      `before anything is sent to the model...</div></div>`;
  }

  function renderInspectorError(turn, promptLabel, message) {
    el.inspector.className = "";
    el.inspector.innerHTML = inspectorHeader(turn, promptLabel, "request failed", "bad") +
      `<div class="insp-section"><h3>Error</h3><div class="note">${esc(message)}</div>` +
      `<div class="note">The turn never completed, so there are no verdicts to show ` +
      `for it. This panel is not showing a previous turn.</div></div>`;
  }

  function renderInspector(r, turn, promptLabel) {
    const usage = r.usage || {};
    const t = r.timings || {};
    const c = r.connection;
    const outcome = r.blocked ? `blocked at ${r.blockedStage}` : "answered";
    let html = inspectorHeader(turn, promptLabel, outcome, r.blocked ? "bad" : "ok");

    // The order guardrails actually ran in, and whether the model was reached at all.
    const reachedModel = !r.blocked || r.blockedStage === "completion";
    html += `<div class="insp-section"><h3>Pipeline</h3>` +
      `<ol class="pipeline">` +
      `<li>Content Safety &mdash; prompt</li>` +
      (r.safety.promptImage ? `<li>Content Safety &mdash; image</li>` : "") +
      ((r.safety.promptShield && r.safety.promptShield.checked) ? `<li>Prompt Shields</li>` : "") +
      `<li>${r.retrieval?.used ? "Retrieval from the index" : "Retrieval (nothing matched)"}</li>` +
      `<li class="${reachedModel ? "" : "skipped"}">Model${reachedModel ? "" : " &mdash; never called"}</li>` +
      `<li>Content Safety &mdash; completion</li>` +
      `</ol>` +
      `<div class="note">Every prompt is screened before the model is called.</div></div>`;

    html += `<div class="insp-section"><h3>Connection</h3><dl class="kv">` +
      `<dt>Endpoint</dt><dd>${esc(c.chatBaseUrl)}/chat/completions</dd>` +
      `<dt>Deployment</dt><dd>${esc(c.model)}</dd>` +
      `<dt>Key</dt><dd>${esc(c.keyHeader)}: ***</dd>` +
      `<dt>From</dt><dd>${esc(c.configSource || "unknown")}</dd>` +
      `<dt>Mode</dt><dd><span class="pill ${c.isGateway ? "info" : "warn"}">${esc(c.mode)}</span> ${esc(c.label)}</dd>` +
      `<dt>Guardrails</dt><dd>${esc(c.safetyVia)}</dd>` +
      `<dt>Documents</dt><dd>${esc(c.docIntelVia)}</dd>` +
      `<dt>Correlation</dt><dd>${esc(r.correlationId)}</dd></dl>` +
      `<div class="note">Mode derived from <b>${esc(c.evidence)}</b> - nothing declares it. ` +
      `${esc(c.note)}</div></div>`;

    html += safetyBlock("Guardrail - prompt text", r.safety.promptText);
    if (r.safety.promptImage) html += safetyBlock("Guardrail - prompt image", r.safety.promptImage);
    if (r.safety.promptShield) html += safetyBlock("Guardrail - prompt shields", r.safety.promptShield);
    if (r.safety.completion) html += safetyBlock("Guardrail - completion", r.safety.completion);

    if (r.retrieval?.used) {
      const chunks = (r.retrieval.chunks || []).map((c) =>
        `<div class="chunk"><div class="src"><span>${esc(c.docName)}</span>` +
        `<span>${c.score.toFixed(3)}</span></div>` +
        (el.showRetrieval.checked ? `<div class="txt">${esc(c.text.slice(0, 260))}</div>` : "") +
        `</div>`).join("");
      html += `<div class="insp-section"><h3>Retrieval</h3>` +
        `<span class="pill info">${esc(r.retrieval.mode)}</span> ` +
        `<span class="pill info">${r.retrieval.chunks.length} chunks</span>` +
        `<div style="margin-top:8px">${chunks}</div></div>`;
    }

    const req = r.request || {};
    if (req.tokenParam) {
      const temp = req.temperature === null || req.temperature === undefined
        ? "not sent" : req.temperature;
      html += `<div class="insp-section"><h3>Request parameters</h3><dl class="kv">` +
        `<dt>Tokens</dt><dd>${esc(req.tokenParam)}: ${req.maxTokens}</dd>` +
        `<dt>Temperature</dt><dd>${esc(String(temp))}</dd></dl>` +
        `<div class="note">Chosen by: ${esc(req.source)}. Models differ on ` +
        `<b>max_tokens</b> vs <b>max_completion_tokens</b>, and some accept only their ` +
        `default temperature.</div></div>`;
    }

    if (!r.blocked) {
      html += `<div class="insp-section"><h3>Usage &amp; latency</h3><dl class="kv">` +
        `<dt>Prompt</dt><dd>${usage.promptTokens ?? "-"} tokens</dd>` +
        `<dt>Completion</dt><dd>${usage.completionTokens ?? "-"} tokens</dd>` +
        `<dt>Total</dt><dd>${usage.totalTokens ?? "-"} tokens</dd>` +
        `<dt>Guardrails</dt><dd>${t.safetyMs ?? 0} ms</dd>` +
        `<dt>Retrieval</dt><dd>${t.retrievalMs ?? 0} ms</dd>` +
        `<dt>Model</dt><dd>${t.modelMs ?? 0} ms</dd>` +
        `<dt>Round trip</dt><dd>${t.totalMs ?? 0} ms</dd></dl></div>`;
    } else {
      html += `<div class="insp-section"><h3>Outcome</h3><span class="pill bad">blocked at ${esc(r.blockedStage)}</span>` +
        `<div class="note">The request never reached the model - a blocked request costs nothing at the provider.</div></div>`;
    }
    el.inspector.className = "";
    el.inspector.innerHTML = html;
  }

  /* ── send ─────────────────────────────────────────────────────── */
  async function send() {
    const text = el.prompt.value.trim();
    if ((!text && !state.attachment) || state.busy) return;

    state.busy = true;
    el.send.disabled = true;
    const image = state.attachment;
    const userNode = addMessage("user", text, { image });
    el.prompt.value = "";
    el.prompt.style.height = "auto";
    clearAttachment();

    const turn = ++state.turn;
    setInspectorBusy(turn, text);

    const typing = addTyping();
    try {
      const r = await api("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          message: text,
          imageDataUrl: image,
          useRag: el.useRag.checked,
          history: modelHistory(),
        }),
      });
      typing.remove();
      const sources = r.retrieval?.used
        ? [...new Set(r.retrieval.chunks.map((c) => c.docName))] : [];
      const replyNode = addMessage("assistant", r.reply, {
        blocked: r.blocked,
        citations: sources.length ? sources : null,
      });
      if (!r.blocked) {
        // sources: which documents this answer was built from, so it can be dropped
        // from the model's memory if one of them is removed.
        state.turns.push({ user: text, assistant: r.reply, sources,
                           nodes: [userNode, replyNode] });
      }
      renderConnection(r.connection);
      renderInspector(r, turn, text);
    } catch (e) {
      typing.remove();
      addMessage("assistant", `Request failed: ${e.message}`, { blocked: true });
      // Without this the panel would keep showing the previous turn while the chat
      // shows an error - which reads as "the inspector stopped updating".
      renderInspectorError(turn, text, e.message);
    } finally {
      state.busy = false;
      el.send.disabled = false;
      el.prompt.focus();
    }
  }

  el.send.onclick = send;
  el.prompt.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
  });
  el.prompt.addEventListener("input", () => {
    el.prompt.style.height = "auto";
    el.prompt.style.height = Math.min(el.prompt.scrollHeight, 160) + "px";
  });
  el.clearChat.onclick = () => {
    state.turns = [];
    state.turn = 0;
    el.messages.innerHTML = "";
    el.inspector.className = "insp-empty";
    el.inspector.textContent = "Send a message to see the connection, guardrail verdicts, token usage and latency.";
    greet();
  };

  function greet() {
    const cfg = state.config;
    const c = cfg.connection;
    addMessage("assistant",
      `Ready. Talking to ${c.chatBaseUrl}, deployment "${c.model}", authenticating with ` +
      `the ${c.keyHeader} header.\n\n` +
      `That endpoint came from ${c.configSource}, and is a "${c.mode}" connection - worked ` +
      `out from ${c.evidence}, not from any setting. ${c.note}\n\n` +
      `Guardrails ${cfg.safetyConfigured ? "on" : "off (Content Safety not configured)"}, ` +
      `document extraction via ${cfg.docIntelConfigured ? "Document Intelligence" : "local text parsing only"}.`);
  }

  /* ── boot ─────────────────────────────────────────────────────── */
  (async function init() {
    try {
      state.config = await api("/api/config");
      renderConnection(state.config.connection);
      await refreshDocs();
      greet();
      el.prompt.focus();
    } catch (e) {
      el.messages.innerHTML =
        `<div class="msg assistant"><div class="avatar">!</div><div class="bubble">` +
        `Could not load configuration: ${esc(e.message)}</div></div>`;
    }
  })();
})();
