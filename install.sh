#!/bin/sh
set -e

# LIR Language Installer
# Usage: run from a checkout with `sh install.sh`, or pipe this script from a trusted source

echo "Installing LIR Language..."

INSTALL_DIR="${LIR_INSTALL_DIR:-/usr/local/bin}"
USER_BIN="$HOME/.lir/bin"

LIR_BIN=""
if [ -f "./zig-out/bin/lir" ]; then
    LIR_BIN="./zig-out/bin/lir"
elif [ -f "./lir" ]; then
    LIR_BIN="./lir"
fi

if [ -n "$LIR_BIN" ]; then
    echo "Found local LIR binary at $LIR_BIN"
    if [ -w "$INSTALL_DIR" ]; then
        cp "$LIR_BIN" "$INSTALL_DIR/lir"
        chmod +x "$INSTALL_DIR/lir"
        echo "LIR installed successfully to $INSTALL_DIR/lir"
    else
        mkdir -p "$USER_BIN"
        cp "$LIR_BIN" "$USER_BIN/lir"
        chmod +x "$USER_BIN/lir"
        echo "LIR installed successfully to $USER_BIN/lir"
        if ! echo "$PATH" | grep -q "$USER_BIN"; then
            echo "Please add $USER_BIN to your PATH:"
            echo "  export PATH=\"\$HOME/.lir/bin:\$PATH\""
        fi
    fi
else
    # Outside a source directory — check for zig or git clone
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    echo "Fetching LIR repository..."
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 https://github.com/sswweett00/ziglir.git "$TMP_DIR/lir"
        cd "$TMP_DIR/lir"
    else
        echo "Error: git is required to clone LIR source repository."
        exit 1
    fi

    if command -v zig >/dev/null 2>&1; then
        echo "Building LIR from source with Zig..."
        zig build -Doptimize=ReleaseFast
        LIR_BIN="./zig-out/bin/lir"
        if [ -w "$INSTALL_DIR" ]; then
            cp "$LIR_BIN" "$INSTALL_DIR/lir"
            chmod +x "$INSTALL_DIR/lir"
            echo "LIR built and installed to $INSTALL_DIR/lir"
        else
            mkdir -p "$USER_BIN"
            cp "$LIR_BIN" "$USER_BIN/lir"
            chmod +x "$USER_BIN/lir"
            echo "LIR built and installed to $USER_BIN/lir"
            if ! echo "$PATH" | grep -q "$USER_BIN"; then
                echo "Please add $USER_BIN to your PATH:"
                echo "  export PATH=\"\$HOME/.lir/bin:\$PATH\""
            fi
        fi
    else
        echo "Error: Zig compiler required to build LIR from source."
        echo "Please install Zig (0.13.0+) and run this script again."
        exit 1
    fi
fi

echo "Installation complete. Run 'lir version' to verify."
