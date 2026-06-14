#!/usr/bin/env bash
# Fetches whisper.cpp + ggml source files from github.com/ggml-org/whisper.cpp
# and populates Sources/whisper_cpp/ so the whisper_cpp SPM target can build.
# Run this once after cloning. Re-run to update to a newer tag.
set -euo pipefail

TAG="v1.7.5"
REPO="ggml-org/whisper.cpp"
DEST="$(cd "$(dirname "$0")" && pwd)/Sources/whisper_cpp"
ARCHIVE_URL="https://github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz"
TMP=$(mktemp -d)

echo "Fetching ${REPO} ${TAG}..."

# Download to a file so we can verify before extracting.
ARCHIVE="$TMP/whisper.tar.gz"
curl -fL --progress-bar "$ARCHIVE_URL" -o "$ARCHIVE"

# Sanity-check: first two bytes of a gzip file are 0x1f 0x8b.
if ! file "$ARCHIVE" | grep -q "gzip\|compressed"; then
    echo "ERROR: download does not look like a gzip archive."
    echo "       Check that ${TAG} exists at github.com/${REPO}/releases"
    cat "$ARCHIVE" | head -3
    rm -rf "$TMP"
    exit 1
fi

tar -xzf "$ARCHIVE" -C "$TMP" --strip-components=1

# Remove stub — real sources replace it from here on.
rm -f "$DEST/whisper_stub.c"
rm -f "$DEST/include/whisper.h"   # replaced by the real header below

echo "Copying core files..."

# Whisper main source + header
cp "$TMP/src/whisper.cpp"  "$DEST/"
cp "$TMP/include/whisper.h" "$DEST/include/"

# ggml tensor library (layout changed in newer whisper.cpp)
for f in \
    ggml.c ggml.h \
    ggml-alloc.c ggml-alloc.h \
    ggml-backend.cpp ggml-backend.h ggml-backend-impl.h \
    ggml-common.h ggml-impl.h \
    ggml-cpu.c ggml-cpu.h ggml-cpu-impl.h \
    ggml-quants.c ggml-quants.h \
    ggml-threading.cpp ggml-threading.h; do

    # Try ggml/src/, ggml/include/, src/, then root
    for search in "$TMP/ggml/src" "$TMP/ggml/include" "$TMP/src" "$TMP"; do
        if [ -f "$search/$f" ]; then
            # Headers go into include/, sources into the C target root
            case "$f" in
                *.h) cp "$search/$f" "$DEST/include/" ;;
                *)   cp "$search/$f" "$DEST/" ;;
            esac
            break
        fi
    done
done

# Metal GPU backend (needed for ANE/GPU acceleration on Apple Silicon)
for mf in ggml-metal.m ggml-metal.metal; do
    for search in "$TMP/ggml/src" "$TMP/src" "$TMP"; do
        [ -f "$search/$mf" ] && cp "$search/$mf" "$DEST/" && break
    done
done
for mh in ggml-metal.h; do
    for search in "$TMP/ggml/include" "$TMP/ggml/src" "$TMP/include" "$TMP"; do
        [ -f "$search/$mh" ] && cp "$search/$mh" "$DEST/include/" && break
    done
done

# CoreML encoder stubs (improves iOS inference speed via ANE, optional)
if [ -d "$TMP/bindings/ios/CoreML" ]; then
    mkdir -p "$DEST/coreml"
    cp -r "$TMP/bindings/ios/CoreML/"* "$DEST/coreml/"
elif [ -d "$TMP/coreml" ]; then
    mkdir -p "$DEST/coreml"
    cp -r "$TMP/coreml/"* "$DEST/coreml/"
fi

rm -rf "$TMP"

echo ""
echo "Done. C sources in $DEST"
echo ""
echo "Models (GGUF format, English-only variants recommended for field use):"
echo "  Download from:  https://huggingface.co/ggerganov/whisper.cpp"
echo "  tiny.en   ~39 MB  — fastest, iPhone SE / low-RAM devices"
echo "  base.en   ~74 MB  — good balance, recommended default"
echo "  small.en  ~244 MB — better accuracy on accented speech"
echo ""
echo "WhisperModelManager.download() handles this automatically at runtime."
