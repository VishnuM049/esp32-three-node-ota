(() => {
  "use strict";
  let current = null;
  let filter = "all";
  const byId = (id) => document.getElementById(id);
  const displayTime = (value) => {
    if (!value) return "—";
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "—" : date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" });
  };
  const number = (value, unit = "") => Number.isFinite(value) ? `${value.toLocaleString()}${unit}` : "—";

  function drawNode(name, node, connected) {
    const root = document.querySelector(`[data-node="${name}"]`);
    if (!root) return;
    const field = (name) => root.querySelector(`[data-field="${name}"]`);
    root.classList.toggle("stale", !connected);
    field("version").textContent = Number.isFinite(node?.version) ? `v${node.version}` : "—";
    field("heap").textContent = number(node?.min_heap, " B");
    field("stack").textContent = number(node?.stack_margin, " B");
    const state = field("state");
    const verified = node?.ota === "valid" && (name === "controller" ? node.noise : node.secure);
    state.classList.toggle("valid", Boolean(verified && connected));
    if (!node) state.textContent = "No observation yet";
    else if (!connected) state.textContent = `Last observed: ${node.ota || node.state || "unknown"} · currently offline`;
    else if (name === "controller") state.textContent = `Boot ${node.ota} · Noise ${node.noise ? "ready" : "unavailable"} · upload TLS ${node.tls ? "reported" : "not reported"}`;
    else if (node.secure) state.textContent = `Authenticated · boot ${node.ota} · ${number(node.rtt_ms, " ms")}`;
    else state.textContent = node.state || "Unregistered";
  }

  function drawEvents(events) {
    const tbody = byId("event-rows");
    tbody.replaceChildren();
    const visible = events.filter((event) => filter === "all" ||
      (filter === "upload" ? ["upload", "version", "confirmed"].includes(event.kind) : event.kind === "connection"));
    if (!visible.length) {
      const row = document.createElement("tr");
      const cell = document.createElement("td");
      cell.colSpan = 4;
      cell.className = "empty";
      cell.textContent = filter === "all" ? "No events recorded yet. The log never invents past activity." : "No events in this category yet.";
      row.append(cell);
      tbody.append(row);
      return;
    }
    for (const entry of visible.slice(0, 120)) {
      const row = document.createElement("tr");
      for (const value of [displayTime(entry.at), entry.node, entry.kind, entry.detail]) {
        const cell = document.createElement("td");
        cell.textContent = String(value ?? ""); // no HTML from device output or local log
        row.append(cell);
      }
      tbody.append(row);
    }
  }

  function draw(data) {
    current = data;
    const connection = byId("connection");
    connection.classList.toggle("connected", Boolean(data.connected));
    byId("connection-text").textContent = data.connected ? "Controller reachable · edge status observed" :
      (data.error || "Waiting for the demo AP");
    byId("last-seen").textContent = data.last_seen ? `Last observed ${displayTime(data.last_seen)}${data.connected ? "" : " · stale"}` : "No controller observation yet";
    const snapshot = data.snapshot;
    const scope = byId("transport-scope");
    if (!snapshot?.controller) scope.textContent = "Waiting for a controller observation; upload transport is not established by this page.";
    else if (snapshot.controller.tls) scope.textContent = `Controller ${data.connected ? "reports" : "last reported"} HTTPS firmware upload on port 443; the one-shot Mac sender must verify its certificate. Controller ↔ edge uses pinned Noise KK. Read-only /status is still plaintext HTTP.`;
    else scope.textContent = `Controller ${data.connected ? "does not report" : "last did not report"} HTTPS: Mac → controller firmware upload is plaintext HTTP. Controller ↔ edge uses pinned Noise KK.`;
    drawNode("controller", snapshot?.controller, data.connected);
    drawNode("edge1", snapshot?.edges?.edge1, data.connected);
    drawNode("edge2", snapshot?.edges?.edge2, data.connected);
    drawEvents(Array.isArray(data.events) ? data.events : []);
  }

  async function refresh() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch("/api/state", { cache: "no-store", signal: controller.signal });
      if (!response.ok) throw new Error(`Local log HTTP ${response.status}`);
      draw(await response.json());
    } catch (_error) {
      byId("connection").classList.remove("connected");
      byId("connection-text").textContent = "Local log unavailable; check the Mac server";
      if (current) drawNode("controller", current.snapshot?.controller, false);
      if (current) drawNode("edge1", current.snapshot?.edges?.edge1, false);
      if (current) drawNode("edge2", current.snapshot?.edges?.edge2, false);
    } finally {
      clearTimeout(timer);
    }
  }

  for (const button of document.querySelectorAll("[data-filter]")) {
    button.addEventListener("click", () => {
      filter = button.dataset.filter;
      for (const peer of document.querySelectorAll("[data-filter]")) {
        const selected = peer === button;
        peer.classList.toggle("active", selected);
        peer.setAttribute("aria-pressed", String(selected));
      }
      if (current) drawEvents(Array.isArray(current.events) ? current.events : []);
    });
  }
  refresh();
  setInterval(() => { if (!document.hidden) refresh(); }, 3000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
})();
