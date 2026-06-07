/**
 * Single source of truth for auth-dependent UI state.
 * Called on login, logout, and page load.
 */
export function updateAuthState(isLoggedIn) {
  const loginRequired = document.querySelectorAll(".login-required");
  const loginTab = document.getElementById("login-tab-button");
  const logToggle = document.getElementById("log-toggle-container");

  loginRequired.forEach(el => {
    el.style.display = isLoggedIn ? "" : "none";
  });

  if (loginTab) loginTab.style.display = isLoggedIn ? "none" : "";
  if (logToggle) logToggle.style.display = isLoggedIn ? "" : "none";
}

/**
 * Toggle between log view and terminal view.
 */
export function setLogView(showLogs) {
  const logOutput = document.getElementById("log-output");
  const terminalContainer = document.getElementById("terminal-container");
  const logControls = document.querySelectorAll(".log-control-inputs");

  if (logOutput) logOutput.style.display = showLogs ? "block" : "none";
  if (terminalContainer) {
    terminalContainer.style.display = showLogs ? "none" : "block";
    terminalContainer.classList.toggle("terminal-hidden", showLogs);
  }
  logControls.forEach(el => {
    if (el.id !== "log-toggle-container") {
      el.style.display = showLogs ? "" : "none";
    }
  });
}
