#!/bin/bash
# Builds whisper.cpp as static libraries into vendor/whisper. They're linked into the app binary,
# so Utter runs without Homebrew. build.sh runs this when the libraries are missing or outdated.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="v1.9.4"
OUT="vendor/whisper"
if [[ -f "$OUT/lib/libwhisper.a" && "$(cat "$OUT/VERSION" 2>/dev/null)" == "$VERSION" ]]; then
    exit 0
fi
command -v cmake >/dev/null || { echo "cmake is required: brew install cmake"; exit 1; }

SRC=".build/whisper.cpp-$VERSION"
[[ -d "$SRC" ]] || git -c advice.detachedHead=false clone --depth 1 --branch "$VERSION" -q https://github.com/ggml-org/whisper.cpp.git "$SRC"

echo "Building whisper.cpp $VERSION (once)…"
rm -rf "$SRC/build" "$OUT"
# GGML_NATIVE=OFF: don't tune for this Mac's chip, so the app also runs on older Apple Silicon.
# GGML_METAL_EMBED_LIBRARY: the GPU shaders go inside the binary instead of a separate file.
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_USE_SYSTEM_GGML=OFF >/dev/null
cmake --build "$SRC/build" --config Release -j "$(sysctl -n hw.ncpu)" >/dev/null
cmake --install "$SRC/build" --prefix "$OUT" >/dev/null
echo "$VERSION" > "$OUT/VERSION"
echo "OK: $OUT"
