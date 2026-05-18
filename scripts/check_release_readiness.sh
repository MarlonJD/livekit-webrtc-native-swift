#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

require_production_ready="${REQUIRE_PRODUCTION_READY:-0}"
run_tests="${LIVEKIT_NATIVE_RELEASE_RUN_TESTS:-1}"
run_benchmarks="${LIVEKIT_NATIVE_RELEASE_RUN_BENCHMARKS:-1}"
run_size_gate="${LIVEKIT_NATIVE_RELEASE_RUN_SIZE_GATE:-1}"
run_platform_builds="${LIVEKIT_NATIVE_RELEASE_RUN_PLATFORM_BUILDS:-0}"
benchmark_samples="${LIVEKIT_NATIVE_BENCHMARK_SAMPLES:-50}"
benchmark_warmup="${LIVEKIT_NATIVE_BENCHMARK_WARMUP:-5}"
benchmark_ops="${LIVEKIT_NATIVE_BENCHMARK_OPS:-50}"

echo "==> Checking forbidden runtime dependencies"
scripts/guard_no_rust_uniffi.sh

echo "==> Checking package shape"
manifest="$(swift package dump-package)"
product_names="$(
  printf '%s\n' "$manifest" |
    awk '
      /"products" : \[/ { in_products = 1; next }
      /"providers" :/ { in_products = 0 }
      in_products && /"name" :/ {
        line = $0
        sub(/^.*"name" : "/, "", line)
        sub(/".*$/, "", line)
        print line
      }
    '
)"
product_count="$(printf '%s\n' "$product_names" | sed '/^$/d' | wc -l | tr -d '[:space:]')"

if [[ "$product_count" != "1" || "$product_names" != "LiveKitNative" ]]; then
  echo "Expected exactly one public product named LiveKitNative."
  echo "Found products:"
  printf '%s\n' "$product_names"
  exit 1
fi

if ! printf '%s\n' "$manifest" | grep -q '"name" : "LiveKitNativeBenchmarks"'; then
  echo "Expected LiveKitNativeBenchmarks executable target to exist."
  exit 1
fi

echo "Package shape passed."

echo "==> Checking production readiness marker"
readiness_file="Sources/LiveKitNative/Core/ProductionReadiness.swift"
if [[ "$require_production_ready" == "1" ]]; then
  if ! grep -q 'status: \.productionReady' "$readiness_file"; then
    echo "Production release gate failed: status is not .productionReady."
    exit 1
  fi

  if ! grep -q 'blockers: \[\]' "$readiness_file"; then
    echo "Production release gate failed: blockers are not empty."
    exit 1
  fi

  if [[ "$run_tests" != "1" ]]; then
    echo "Production release gate failed: tests must run in strict production mode."
    exit 1
  fi

  if [[ "${LIVEKIT_NATIVE_RUN_INTEGRATION:-0}" != "1" ]]; then
    echo "Production release gate failed: set LIVEKIT_NATIVE_RUN_INTEGRATION=1 so LiveKit integration tests run."
    exit 1
  fi

  for required_integration_env in \
    LIVEKIT_NATIVE_LIVEKIT_URL \
    LIVEKIT_NATIVE_API_KEY \
    LIVEKIT_NATIVE_API_SECRET
  do
    if [[ -z "${!required_integration_env:-}" ]]; then
      echo "Production release gate failed: missing $required_integration_env for LiveKit integration tests."
      exit 1
    fi
  done
else
  if grep -q 'status: \.productionReady' "$readiness_file" && ! grep -q 'blockers: \[\]' "$readiness_file"; then
    echo "Readiness marker is inconsistent: productionReady status with non-empty blockers."
    exit 1
  fi

  echo "Production strict gate not requested; current preview status is allowed."
fi

if [[ "$run_tests" == "1" ]]; then
  echo "==> Running tests"
  if [[ "${LIVEKIT_NATIVE_RUN_INTEGRATION:-0}" == "1" ]]; then
    echo "LiveKit integration tests enabled for ${LIVEKIT_NATIVE_LIVEKIT_URL:-<missing-url>}."
  else
    echo "LiveKit integration tests not requested; opt-in tests will skip."
  fi
  swift test --jobs 1
fi

if [[ "$run_benchmarks" == "1" ]]; then
  echo "==> Running benchmark smoke"
  swift run -c release LiveKitNativeBenchmarks \
    --samples "$benchmark_samples" \
    --warmup "$benchmark_warmup" \
    --ops-per-sample "$benchmark_ops"
fi

if [[ "$run_size_gate" == "1" ]]; then
  echo "==> Running release size gate"
  scripts/check_release_size.sh
fi

if [[ "$run_platform_builds" == "1" ]]; then
  echo "==> Running Apple platform builds"
  xcodebuild build -quiet -scheme LiveKitNative -destination 'generic/platform=macOS'
  xcodebuild build -quiet -scheme LiveKitNative -destination 'generic/platform=iOS Simulator'
  xcodebuild docbuild -quiet -scheme LiveKitNative -destination 'generic/platform=macOS'
fi

echo "Release readiness checks passed."
