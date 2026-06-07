import { isAuthed } from "./api.js";
import { terminal } from "./terminal.js";
import { setLogView } from "./utils.js";

// ── Theme ──

export function setTheme(name) {
  document.documentElement.setAttribute("data-theme", name);
  localStorage.setItem("pref-theme", name);
  const sel = document.getElementById("theme-select");
  if (sel) sel.value = name;
}

export function initTheme() {
  setTheme(localStorage.getItem("pref-theme") || "emerald");
}

// ── Toast queue ──

const toastQueue = [];
let toastActive = false;

export function showToast(message) {
  toastQueue.push(message);
  if (!toastActive) drainToasts();
}

function drainToasts() {
  if (!toastQueue.length) { toastActive = false; return; }
  toastActive = true;

  const msg = toastQueue.shift();
  const el = document.createElement("div");
  el.className = "toast";
  el.textContent = msg;
  document.body.appendChild(el);

  requestAnimationFrame(() => el.classList.add("show"));

  setTimeout(() => {
    el.classList.remove("show");
    setTimeout(() => { el.remove(); drainToasts(); }, 400);
  }, 3000);
}

// ── Tabs ──

let terminalLoaded = false;

export async function showTab(tabId) {
  document.querySelectorAll(".tab-content").forEach(el => el.classList.remove("active"));
  document.querySelectorAll(".tab-button").forEach(el => el.classList.remove("active"));

  document.getElementById(tabId)?.classList.add("active");
  document.querySelector(`.tab-button[onclick="showTab('${tabId}')"]`)?.classList.add("active");

  if (tabId === "log") {
    const authed = await isAuthed();
    if (authed && !terminalLoaded) {
      const toggle = document.getElementById("log-toggle-button");
      if (toggle?.checked) {
        loadTerminal();
      }
    }
  }
}

export function loadTerminal() {
  if (terminalLoaded) return;
  setLogView(false);
  terminal();
  terminalLoaded = true;
}

/**
 * Opens the sudo modal and resolves with the entered password.
 * Returns null if the user cancels.
 */
export function requestSudoPassword() {
  return new Promise((resolve) => {
    const modal = document.getElementById("sudo-modal");
    const input = document.getElementById("sudo-password");
    const confirmBtn = document.getElementById("confirm-sudo-button");
    const cancelBtn = document.getElementById("cancel-sudo-button");

    modal.classList.add("active");
    input.value = "";
    input.focus();

    const cleanup = () => {
      modal.classList.remove("active");
      input.value = "";
      confirmBtn.removeEventListener("click", onConfirm);
      cancelBtn.removeEventListener("click", onCancel);
      input.removeEventListener("keypress", onKey);
    };

    const onConfirm = () => { const pass = input.value; cleanup(); resolve(pass); };
    const onCancel = () => { cleanup(); resolve(null); };
    const onKey = (e) => { if (e.key === "Enter") onConfirm(); };

    confirmBtn.addEventListener("click", onConfirm);
    cancelBtn.addEventListener("click", onCancel);
    input.addEventListener("keypress", onKey);
  });
}
