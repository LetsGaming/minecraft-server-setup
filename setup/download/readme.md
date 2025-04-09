# CurseForge Modpack Downloader

This JavaScript script allows you to download a modpack from CurseForge using the CurseForge API. It reads configuration details (like the `pack_id` and `api_key`) from a `variables.txt` file. If these details are missing or incorrect, the script will notify you and exit gracefully.

## Requirements

- Node.js (version 12.x or higher)
- `axios` library (can be installed using `npm install axios`)

## Instructions

### Step 1: Set up your `variables.txt` file

You will need to create a `variables.txt` file to store your CurseForge **pack ID** and **API key**. The file should be in the following format:

```
pack_id=YOUR_pack_id
api_key=YOUR_API_KEY
```

- **pack_id**: This is the numeric ID of the modpack you want to download. To find it:
  1. Go to the [CurseForge website](https://www.curseforge.com/minecraft/modpacks).
  2. Browse to the modpack page you're interested in.
  3. On the left side of the page, under the **About Project** section, you will find the **Project ID** (e.g., `Project ID: 123456`).

- **api_key**: To use the CurseForge API, you'll need an API key. You can obtain your API key by creating an account and logging into the [CurseForge website](https://www.curseforge.com/). Then, go to the [API page](https://console.curseforge.com/) to generate a new key.

**Example `variables.txt` file**:

```
pack_id=123456
api_key=your_api_key_here
```

### Step 2: Download the Modpack

Once you have set up your `variables.txt` file, run the JavaScript script:

```bash
node download_modpack.js
```

### Step 3: Handling Missing or Incorrect Values

If the `pack_id` or `api_key` is missing or incorrect in the `variables.txt` file, the script will print an error message and stop.

Example error message:

```
Error: pack_id or api_key is missing or incorrect. Please check the 'variables.txt' file.
```

### Step 4: Download Location

The modpack will be downloaded as a `.zip` file and saved in the same directory where the script is located. The filename will be `server-pack.zip`.

### Step 5: Progress Bar

The script will display the download progress in the terminal as a percentage and notify you when the download is complete.

## Troubleshooting

- **File not found error**: Make sure that the `variables.txt` file is in the same directory as the script.
- **Invalid pack ID or API key**: Double-check the values in `variables.txt`. Ensure the `pack_id` is correct (find it in the **About Project** section on the CurseForge modpack page) and that the API key is valid.
- **Missing dependencies**: If you haven't installed `axios`, run `npm install axios` to install the required package.

--- 

Now the README correctly mentions the location of the **pack ID** in the **About Project** section.