import { showTab, showToast, requestSudoPassword } from "./ui.js";
import { updateAuthState } from "./utils.js";

export const STATUS_INTERVAL_MS = 30000;
export const LOG_INTERVAL_MS = 10000;

// ── Fetch wrapper ──

export function apiFetch(url, options = {}) {
  const token = localStorage.getItem("token");
  const headers = { "Content-Type": "application/json", ...options.headers };
  if (token) headers.Authorization = `Bearer ${token}`;

  return fetch(url, { ...options, headers }).then((res) => {
    if (res.status === 401) {
      localStorage.removeItem("token");
      updateAuthState(false);
      showTab("login");
      throw new Error("Session expired");
    }
    return res;
  });
}

// ── Server commands ──

/**
 * Sends a command to the server.
 * If useSudo is true, prompts for the sudo password first.
 */
export async function sendCommand(command, useSudo = false) {
  let password = null;

  if (useSudo) {
    password = await requestSudoPassword();
    if (password === null) return; // User cancelled
  }

  try {
    const res = await apiFetch(`/${command}`, {
      method: "POST",
      body: JSON.stringify(password ? { password } : {}),
    });
    const data = await res.json();
    if (data.error) throw new Error(data.error);
    showToast(`"${command}" executed.`);
  } catch (err) {
    showToast(`Error: ${err.message}`);
  }
}

export async function confirmAction(command) {
  if (!confirm(`Are you sure you want to ${command}? This cannot be undone.`)) return;
  await sendCommand(command, true);
}

export async function sendRconCommand() {
  const input = document.getElementById("rcon-command");
  const output = document.getElementById("rcon-response");
  const cmd = input.value.trim();
  if (!cmd) return;

  try {
    const res = await apiFetch("/command", {
      method: "POST",
      body: JSON.stringify({ command: cmd }),
    });
    const data = await res.json();
    output.textContent = data.output || data.error || "No response.";
    input.value = "";
  } catch (err) {
    output.textContent = `Error: ${err.message}`;
  }
}

// ── Status & Logs ──

export async function getStatus() {
  try {
    const res = await fetch("/status");
    const data = await res.json();
    document.getElementById("status").textContent = data.output || "Status: Unknown";
  } catch {
    document.getElementById("status").textContent = "Status: Connection Error";
  }
}

export async function pollLogs(autoScroll) {
  const logLength = document.getElementById("log-length")?.value || 100;
  const logOutput = document.getElementById("log-output");
  try {
    const res = await fetch(`/log?length=${logLength}`);
    const text = await res.text();
    logOutput.textContent = text;
    if (autoScroll) logOutput.scrollTop = logOutput.scrollHeight;
  } catch { /* silent */ }
}

export async function loadBackups() {
  try {
    const res = await apiFetch("/list-backups");
    const backups = await res.json();
    if (!Array.isArray(backups)) return;

    const restoreSelect = document.getElementById("backup-select");
    const downloadSelect = document.getElementById("download-file");
    const defaultOpt = '<option value="" disabled selected>Choose Backup</option>';
    restoreSelect.innerHTML = defaultOpt;
    downloadSelect.innerHTML = defaultOpt;

    for (const backup of backups) {
      const opt = (sel) => {
        const o = document.createElement("option");
        o.value = backup.path;
        o.textContent = backup.path;
        sel.appendChild(o);
      };
      opt(restoreSelect);
      opt(downloadSelect);
    }
  } catch { /* silent on load */ }
}

// ── Auth ──

export async function isAuthed() {
  const token = localStorage.getItem("token");
  if (!token) return false;
  try {
    const res = await fetch("/isAuthenticated", {
      headers: { Authorization: `Bearer ${token}` },
    });
    return res.ok;
  } catch {
    return false;
  }
}

export async function login() {
  const username = document.getElementById("username").value;
  const password = document.getElementById("password").value;
  try {
    const res = await fetch("/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
    });
    if (!res.ok) throw new Error("Invalid credentials");
    const { token } = await res.json();
    localStorage.setItem("token", token);
    showToast("Login successful!");
    showTab("control");
    updateAuthState(true);
  } catch (err) {
    showToast(err.message);
  }
}

export async function logout() {
  const token = localStorage.getItem("token");
  await fetch("/logout", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  }).catch(() => {});
  localStorage.removeItem("token");
  updateAuthState(false);
  showTab("login");
  showToast("Logged out.");
}
