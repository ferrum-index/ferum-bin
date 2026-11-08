
#!/usr/bin/env bash
set -euo pipefail
VERSION="v26.11.9"
URL="https://github.com/Ferrumec/ferum/releases/download/$VERSION/ferum-$VERSION-linux-x86_64.tar.gz"
ARCHIVE="ferum-$VERSION-linux-x86_64.tar.gz"
DEST_DIR="."

# Download the archive
if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar "$URL" -o "$ARCHIVE"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$ARCHIVE" "$URL"
else
    echo "Error: curl or wget is required." >&2
    exit 1
fi

# Create destination directory
mkdir -p "$DEST_DIR"

# Extract the archive
tar -xzf "$ARCHIVE" -C "$DEST_DIR"

echo "Download and extraction complete."
echo "Files extracted to: $DEST_DIR/"

# Optional: remove the downloaded archive
rm -f "$ARCHIVE"

