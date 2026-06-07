import {
  login, logout, sendCommand, confirmAction, sendRconCommand,
  loadBackups, getStatus, pollLogs,
  LOG_INTERVAL_MS, STATUS_INTERVAL_MS, isAuthed,
} from "./api.js";

import { showToast, showTab, setTheme, initTheme, loadTerminal } from "./ui.js";
import { updateAuthState, setLogView } from "./utils.js";

// ── Expose to HTML onclick handlers ──
Object.assign(window, {
  showTab, setTheme, login, logout, sendCommand,
  confirmAction, sendRconCommand,
  reloadAll,
});

async function reloadAll() {
  await Promise.all([loadBackups(), getStatus(), pollLogs()]);
  showToast("Reloaded!");
}

// ── Auto-scroll ──

function setupAutoScroll(logOutput, checkbox) {
  let auto = true;
  checkbox.addEventListener("change", (e) => { auto = e.target.checked; });
  logOutput.addEventListener("scroll", () => {
    const atBottom = logOutput.scrollHeight - logOutput.scrollTop <= logOutput.clientHeight + 10;
    checkbox.checked = atBottom;
    auto = atBottom;
  });
  return () => auto;
}

// ── Form handlers ──

function setupForms() {
  document.getElementById("backup-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const archive = document.getElementById("archive-option").checked;
    try {
      const token = localStorage.getItem("token");
      await fetch("/backup", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ archive }),
      });
      showToast("Backup created!");
    } catch (err) {
      showToast("Error: " + err.message);
    }
  });

  document.getElementById("restore-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const file = document.getElementById("backup-select").value;
    if (!file) return showToast("Select a backup first.");
    if (!confirm("Restore this backup? The server will be stopped.")) return;
    const token = localStorage.getItem("token");
    try {
      await fetch("/restore", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ file }),
      });
      showToast("Backup restored!");
    } catch (err) {
      showToast("Error: " + err.message);
    }
  });

  document.getElementById("download-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const file = document.getElementById("download-file").value;
    if (!file) return showToast("Select a backup first.");
    const token = localStorage.getItem("token");

    const progressContainer = document.getElementById("download-status");
    const progressBar = document.getElementById("download-progress");
    const statusText = document.getElementById("download-text");

    try {
      const res = await fetch(`/download?file=${encodeURIComponent(file)}`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) throw new Error(res.statusText);

      const total = +res.headers.get("Content-Length") || 0;
      const reader = res.body.getReader();
      const chunks = [];
      let received = 0;

      progressContainer.style.display = "block";
      progressBar.value = 0;
      statusText.textContent = "Starting...";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        received += value.length;
        if (total) {
          const pct = (received / total) * 100;
          progressBar.value = pct;
          const mb = n => (n / 1048576).toFixed(1);
          statusText.textContent = `${mb(received)} / ${mb(total)} MB (${pct.toFixed(1)}%)`;
        }
      }

      const blob = new Blob(chunks);
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = file.split("/").pop();
      a.click();
      URL.revokeObjectURL(a.href);

      statusText.textContent = "Complete!";
      setTimeout(() => { progressContainer.style.display = "none"; }, 2000);
      showToast("Download complete!");
    } catch (err) {
      showToast("Download failed: " + err.message);
      statusText.textContent = "Failed.";
    }
  });
}

// ── Init ──

document.addEventListener("DOMContentLoaded", async () => {
  initTheme();

  const logOutput = document.getElementById("log-output");
  const scrollCheckbox = document.getElementById("auto-scroll-checkbox");
  const getAutoScroll = setupAutoScroll(logOutput, scrollCheckbox);

  // Auth state
  const authed = await isAuthed();
  updateAuthState(authed);
  if (authed) showTab("control");

  // Log/terminal toggle
  document.getElementById("log-toggle-button").addEventListener("change", (e) => {
    if (e.target.checked) {
      loadTerminal();
    } else {
      setLogView(true);
    }
  });

  // Log length change
  document.getElementById("log-length").addEventListener("change", () => pollLogs(getAutoScroll()));

  setupForms();

  // Initial data load
  await Promise.all([loadBackups(), getStatus(), pollLogs(getAutoScroll())]);

  // Polling loops (non-overlapping)
  (async function logLoop() {
    try { await pollLogs(getAutoScroll()); } catch { /* */ }
    setTimeout(logLoop, LOG_INTERVAL_MS);
  })();

  (async function statusLoop() {
    try { await getStatus(); } catch { /* */ }
    setTimeout(statusLoop, STATUS_INTERVAL_MS);
  })();
});
