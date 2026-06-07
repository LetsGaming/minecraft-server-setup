export function terminal() {
  try {
    const term = new Terminal({
      fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
      fontSize: 14,
      cursorBlink: true,
      theme: {
        background: "#0f172a",
        foreground: "#4ade80",
        cursor: "#4ade80",
        selection: "rgba(74, 222, 128, 0.3)",
      },
    });

    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(document.getElementById("terminal"));
    fitAddon.fit();

    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const token = localStorage.getItem("token");
    const socket = new WebSocket(`${proto}//${location.host}/ws/terminal?token=${token}`);

    socket.addEventListener("open", () => term.writeln("Connected to server.\r\n"));
    socket.addEventListener("message", (e) => term.write(e.data));
    socket.addEventListener("close", () => term.writeln("\r\n[Connection closed]"));
    socket.addEventListener("error", () => term.writeln("\r\n[WebSocket error]"));

    let buf = "";
    term.onData((data) => {
      if (data === "\r") {
        socket.send(buf + "\n");
        term.write("\r\n");
        buf = "";
      } else if (data === "\u007f") {
        if (buf.length) { buf = buf.slice(0, -1); term.write("\b \b"); }
      } else {
        buf += data;
        term.write(data);
      }
    });

    window.addEventListener("resize", () => fitAddon.fit());
  } catch (err) {
    console.error("Terminal error:", err);
  }
}
