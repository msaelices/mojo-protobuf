#!/usr/bin/env bash
# Cross-implementation decode/encode comparison on a packed repeated int64
# message (2000 small values). Run from inside the pixi env, with the Go and
# Rust toolchains on PATH:  pixi run bash benchmarks/compare/run.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
PROTOC="$ROOT/.pixi/envs/default/bin/protoc"
export PATH="$PATH:$(go env GOPATH 2>/dev/null)/bin"

mkdir -p gen go/pb
"$PROTOC" -I . --plugin=protoc-gen-mojo="$ROOT/codegen/protoc-gen-mojo" \
  --mojo_out=gen bench.proto
"$PROTOC" -I . --go_out=go/pb \
  --go_opt=Mbench.proto=cmpbench/pb,paths=source_relative bench.proto

echo "decode / encode, ns per op (2000 small packed int64; lower is better):"
mojo run -I "$ROOT/src" -I gen mojo_bench.mojo 2>/dev/null \
  | awk -F'|' '/^\| (decode|encode)/{gsub(/ /,"",$2);v=$3+0;if(!(($2)in b)||v<b[$2])b[$2]=v} END{printf "  mojo            decode %7.0f   encode %7.0f\n",b["decode"]*1e6,b["encode"]*1e6}'
python3 py_bench.py 2>/dev/null \
  | awk '{printf "  python(upb)     decode %7.0f   encode %7.0f\n",$3,$6}'
(cd go && go run . 2>/dev/null) \
  | awk '{printf "  go(protobuf-go) decode %7.0f   encode %7.0f\n",$3,$6}'
(cd rust && PROTOC="$PROTOC" cargo run --release -q 2>/dev/null) \
  | awk '{printf "  rust(prost)     decode %7.0f   encode %7.0f\n",$3,$6}'
