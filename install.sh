#!/bin/bash
# Installs Utter on this Mac, from this clone: ./install.sh
# Afterwards Utter keeps itself up to date from this clone's git remote.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Apple's Command Line Tools are required. Opening the installer…"
    xcode-select --install || true
    echo "When the installation finishes, run ./install.sh again."
    exit 1
fi

if ! command -v cmake >/dev/null; then
    if command -v brew >/dev/null; then
        echo "Installing cmake (needed once, to build whisper.cpp)…"
        brew install cmake
    else
        echo "cmake is required: install Homebrew (https://brew.sh), then run: brew install cmake"
        exit 1
    fi
fi

./build.sh install

echo
echo "Done! Utter is in your menu bar; the setup window walks you through the rest."
echo "It updates itself from this folder's git remote, so keep this folder where it is."
