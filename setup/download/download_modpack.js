const axios = require('axios');
const fs = require('fs');
const path = require('path');

// Load pack_id and api_key from variables.txt
const variablesFilePath = path.join(__dirname, 'variables.txt');
let packID, curseforgeAPIKey;

fs.readFile(variablesFilePath, 'utf8', (err, data) => {
    if (err) {
        console.error('Error reading variables.txt:', err);
        return;
    }

    // Parse the variables.txt file
    const lines = data.split('\n');
    lines.forEach(line => {
        const [key, value] = line.split('=');
        if (key === 'pack_id') {
            packID = value.trim();
        } else if (key === 'api_key') {
            curseforgeAPIKey = value.trim();
        }
    });

    // Check if pack_id or api_key are missing or set to 'none'
    if (!packID || !curseforgeAPIKey || packID === 'none' || curseforgeAPIKey === 'none') {
        console.error('Error: pack_id or api_key is missing or set to "none". Please check the "variables.txt" file.');
        return;
    }

    // Now call the API with the loaded values
    fetchModPackInfo();
});

function fetchModPackInfo() {
    axios.get(`https://api.curseforge.com/v1/mods/${packID}`, {
        headers: {'x-api-key': curseforgeAPIKey}
    })
    .then(response => {
        const mainFileId = response.data.data.mainFileId;
        axios.get(`https://api.curseforge.com/v1/mods/${packID}/files/${mainFileId}`, {
            headers: {'x-api-key': curseforgeAPIKey}
        }).then(response => {
            axios.get(`https://api.curseforge.com/v1/mods/${packID}/files/${response.data.data.serverPackFileId}`, {
                headers: {'x-api-key': curseforgeAPIKey}
            }).then(response => {
                console.log(`Downloading server pack (${formatBytes(Number(response.data.data.fileLength))})...`);
                downloadServerPack(response.data.data.downloadUrl, Number(response.data.data.fileLength));
            }).catch(err => console.error(err));
        }).catch(err => console.error(err));
    }).catch(err => console.error(err));
}

function downloadServerPack(downloadUrl, totalSize) {
    axios.get(downloadUrl, {
        responseType: 'stream'
    }).then(response => {
        const writer = fs.createWriteStream('server-pack.zip');
        
        let downloaded = 0;
        let lastProgress = 0; // To track last shown progress
        let startTime = Date.now();
        let downloadSpeed = 0; // In bytes per second

        response.data.pipe(writer);

        response.data.on('data', chunk => {
            downloaded += chunk.length;
            let progress = (downloaded / totalSize * 100).toFixed(2);

            // Update progress every 10%
            if (progress >= lastProgress + 1) {
                let elapsedTime = (Date.now() - startTime) / 1000; // Time in seconds
                downloadSpeed = downloaded / elapsedTime; // Calculate download speed in bytes per second
                let remainingTime = (totalSize - downloaded) / downloadSpeed; // Remaining time in seconds
                let remainingTimeFormatted = formatTime(remainingTime);

                process.stdout.write(`Downloading... ${progress}% | Remaining time: ${remainingTimeFormatted} \r`);
                lastProgress = Math.floor(progress); // Update to the next 10% step
            }
        });

        writer.on('finish', () => {
            console.log('\nDownload completed!');
        });

        writer.on('error', err => {
            console.error('Error during download:', err);
        });

    }).catch(err => console.error('Download error:', err));
}

// Function to format the remaining time in a human-readable format (e.g., 1m 20s)
function formatTime(seconds) {
    let minutes = Math.floor(seconds / 60);
    seconds = Math.floor(seconds % 60);
    return `${minutes}m ${seconds}s`;
}

function formatBytes(bytes, decimals = 2) {
    if (!+bytes) return '0 Bytes';
    const k = 1024;
    const dm = decimals < 0 ? 0 : decimals;
    const sizes = ['Bytes', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB', 'ZiB', 'YiB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`;
}
