#!/bin/bash

# Exit on error
set -e

# Run the modpack download script
node "$(dirname "${BASH_SOURCE[0]}")/setup/download/download_modpack.js"
