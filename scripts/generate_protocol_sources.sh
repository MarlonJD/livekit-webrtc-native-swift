#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
protocol_revision="$(tr -d '[:space:]' < "$repo_root/Sources/LiveKitNativeProtocol/Generated/livekit-protocol-revision.txt")"
work_dir="${LIVEKIT_PROTOCOL_WORK_DIR:-/private/tmp/livekit-native-protocol}"
protocol_dir="$work_dir/protocol"
swift_protobuf_dir="${SWIFT_PROTOBUF_DIR:-}"
generated_dir="$repo_root/Sources/LiveKitNativeProtocol/Generated"

if [[ -z "$protocol_revision" ]]; then
  echo "Missing LiveKit protocol revision."
  exit 1
fi

if [[ -z "$swift_protobuf_dir" ]]; then
  if [[ -d "$repo_root/.build/checkouts/swift-protobuf" ]]; then
    swift_protobuf_dir="$repo_root/.build/checkouts/swift-protobuf"
  else
    swift_protobuf_dir="$(find /private/tmp -path '*/checkouts/swift-protobuf' -type d -print -quit 2>/dev/null || true)"
  fi

  if [[ -z "$swift_protobuf_dir" ]]; then
    swift package resolve --package-path "$repo_root"
    if [[ -d "$repo_root/.build/checkouts/swift-protobuf" ]]; then
      swift_protobuf_dir="$repo_root/.build/checkouts/swift-protobuf"
    fi
  fi
fi

if [[ -z "$swift_protobuf_dir" || ! -d "$swift_protobuf_dir" ]]; then
  echo "Set SWIFT_PROTOBUF_DIR to a swift-protobuf checkout."
  exit 1
fi

mkdir -p "$work_dir" "$generated_dir"

if [[ ! -d "$protocol_dir/.git" ]]; then
  git clone https://github.com/livekit/protocol.git "$protocol_dir"
fi

git -C "$protocol_dir" fetch --tags origin
git -C "$protocol_dir" checkout "$protocol_revision"

swift build --package-path "$swift_protobuf_dir" --product protoc --configuration release
swift build --package-path "$swift_protobuf_dir" --product protoc-gen-swift --configuration release

protoc_bin="$swift_protobuf_dir/.build/release/protoc"
plugin_bin="$swift_protobuf_dir/.build/release/protoc-gen-swift"

find "$generated_dir" -name '*.pb.swift' -delete

proto_files=(
  "$protocol_dir/protobufs/logger/options.proto"
  "$protocol_dir/protobufs/livekit_metrics.proto"
  "$protocol_dir/protobufs/livekit_models.proto"
  "$protocol_dir/protobufs/livekit_rtc.proto"
)

"$protoc_bin" \
  --plugin="protoc-gen-swift=$plugin_bin" \
  --proto_path="$protocol_dir/protobufs" \
  --proto_path="$swift_protobuf_dir/Protos/Sources/SwiftProtobuf" \
  --swift_opt=Visibility=Public \
  --swift_out="$generated_dir" \
  "${proto_files[@]}"

echo "Generated LiveKit protocol Swift sources at revision $protocol_revision."
