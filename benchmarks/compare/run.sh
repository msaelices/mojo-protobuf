#!/usr/bin/env bash
# Cross-implementation decode/encode comparison on two messages: a packed
# numeric array (packed.bin) and a string-heavy record (person.bin), on the
# same wire bytes. Run inside the pixi env with Go + Rust on PATH:
#   pixi run bash benchmarks/compare/run.sh
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

echo "decode / encode, ns per op (lower is better):"
echo "                        decode    encode"
mojo run -I "$ROOT/src" -I gen mojo_bench.mojo 2>/dev/null | awk -F'|' '
  /^\| (packed|person)_/{gsub(/ /,"",$2);v=$3+0;if(!(($2)in b)||v<b[$2])b[$2]=v}
  END{printf "  mojo            packed  %8.0f  %8.0f\n",b["packed_decode"]*1e6,b["packed_encode"]*1e6;
      printf "  mojo            person  %8.0f  %8.0f\n",b["person_decode"]*1e6,b["person_encode"]*1e6}'
fmt() { awk '{printf "  %-15s %-7s %8.0f  %8.0f\n",$1,$2,$4,$6}'; }
python3 py_bench.py 2>/dev/null | fmt
(cd go && go run . 2>/dev/null) | fmt
(cd rust && PROTOC="$PROTOC" cargo run --release -q 2>/dev/null) | fmt
