const fs = require("fs");
const axios = require("axios");

function createDownloadDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function formatTime(seconds) {
  const minutes = Math.floor(seconds / 60);
  seconds = Math.floor(seconds % 60);
  return `${minutes}m ${seconds}s`;
}

function formatBytes(bytes, decimals = 2) {
  if (!+bytes) return "0 Bytes";
  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = ["Bytes", "KiB", "MiB", "GiB", "TiB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`;
}

function downloadFile(url, fileName, totalSize) {
  return new Promise((resolve, reject) => {
    axios
      .get(url, { responseType: "stream" })
      .then((response) => {
        const writer = fs.createWriteStream(fileName);
        let downloaded = 0;
        let lastProgress = 0;
        const startTime = Date.now();

        response.data.pipe(writer);

        response.data.on("data", (chunk) => {
          downloaded += chunk.length;
          const progress = ((downloaded / totalSize) * 100).toFixed(2);

          if (progress >= lastProgress + 1) {
            const elapsed = (Date.now() - startTime) / 1000;
            const speed = downloaded / elapsed;
            const eta = (totalSize - downloaded) / speed;
            process.stdout.write(
              `Downloading... ${progress}% | Remaining: ${formatTime(eta)}\r`
            );
            lastProgress = Math.floor(progress);
          }
        });

        writer.on("finish", () => {
          console.log("\nDownload complete!");
          resolve();
        });

        writer.on("error", (err) => {
          console.error("Error writing file:", err);
          reject(err);
        });
      })
      .catch((err) => {
        console.error("Download error:", err.response?.data || err.message);
        reject(err);
      });
  });
}

module.exports = {
  createDownloadDir,
  formatTime,
  formatBytes,
  downloadFile,
};
