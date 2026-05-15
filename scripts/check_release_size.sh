#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

product="${LIVEKIT_NATIVE_SIZE_GATE_PRODUCT:-LiveKitNativeBenchmarks}"
max_compressed_bytes="${LIVEKIT_NATIVE_MAX_COMPRESSED_BYTES:-5242880}"

swift build -c release --product "$product"

binary_path=".build/release/$product"
if [[ ! -x "$binary_path" ]]; then
  binary_path="$(find .build -path "*/release/$product" -type f -perm -111 | head -n 1)"
fi

if [[ -z "$binary_path" || ! -x "$binary_path" ]]; then
  echo "Unable to find release binary for $product."
  exit 1
fi

compressed_bytes="$(gzip -c "$binary_path" | wc -c | tr -d '[:space:]')"

echo "Compressed $product release binary size: $compressed_bytes bytes"
echo "Limit: $max_compressed_bytes bytes"

if (( compressed_bytes > max_compressed_bytes )); then
  echo "Size gate failed."
  exit 1
fi

echo "Size gate passed."
