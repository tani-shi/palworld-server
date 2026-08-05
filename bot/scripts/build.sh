#!/usr/bin/env bash
set -euo pipefail

BOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR="$BOT_DIR/build"

rm -rf "$BUILD_DIR"

# PyNaCl ships a compiled extension, so the wheel has to be resolved for the
# Lambda runtime rather than for this host. boto3 comes with the runtime.
uv pip install --quiet \
  --python-platform aarch64-manylinux2014 \
  --python-version 3.13 \
  --target "$BUILD_DIR" \
  pynacl

cp -R "$BOT_DIR/src/palworld_bot" "$BUILD_DIR/"

echo "built $BUILD_DIR"
