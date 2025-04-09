#!/bin/bash

# Exit on error
set -e

# Run the modpack download script
npm i --no-package-lock --omit=dev
node "$(dirname "${BASH_SOURCE[0]}")/setup/download/download_modpack.js"
