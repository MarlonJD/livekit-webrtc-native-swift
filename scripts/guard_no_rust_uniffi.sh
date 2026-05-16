#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

blocked_files="$(find . \
  -path './.git' -prune -o \
  -path './.build' -prune -o \
  -name '*.rs' -print -o \
  -name 'Cargo.toml' -print -o \
  -name 'Cargo.lock' -print -o \
  -name 'rust-toolchain' -print -o \
  -name 'rust-toolchain.toml' -print -o \
  -name 'LiveKitWebRTC.xcframework' -print -o \
  -name 'BoringSSL*' -print -o \
  -name 'libopus*' -print -o \
  -name 'libvpx*' -print)"

if [[ -n "$blocked_files" ]]; then
  echo "Forbidden runtime artifacts are not allowed in this repository:"
  echo "$blocked_files"
  exit 1
fi

blocked_dependency_pattern='RustLiveKitUniFFI|livekit-uniffi|livekit/webrtc-xcframework|webrtc-xcframework|LiveKitWebRTC|BoringSSL|libopus|libvpx'

if command -v rg >/dev/null 2>&1; then
  bridge_matches="$(rg --hidden \
    --glob '!.git/**' \
    --glob '!.build/**' \
    --glob '!scripts/guard_no_rust_uniffi.sh' \
    --glob '!README.md' \
    "$blocked_dependency_pattern" \
    Package.swift Package.resolved Sources Tests Benchmarks .github scripts || true)"
else
  bridge_matches=""
  while IFS= read -r file; do
    case "$file" in
      "scripts/guard_no_rust_uniffi.sh" | "./scripts/guard_no_rust_uniffi.sh" | "README.md" | "./README.md")
        continue
        ;;
    esac

    matches="$(grep -I -n -E "$blocked_dependency_pattern" "$file" || true)"
    if [[ -n "$matches" ]]; then
      bridge_matches+="${file}:${matches}"$'\n'
    fi
  done < <(find Package.swift Package.resolved Sources Tests Benchmarks .github scripts \
    -path './.git' -prune -o \
    -path './.build' -prune -o \
    -type f -print 2>/dev/null)
fi

if [[ -n "$bridge_matches" ]]; then
  echo "$bridge_matches"
  echo "Blocked runtime dependency reference found."
  exit 1
fi

echo "No forbidden runtime dependency artifacts found."
