#!/usr/bin/env bash
# Builds the BipuuCore and BipuuSQLite Swift modules (as static libraries) with plain swiftc, for the
# standalone tests and the dev app bundle. SwiftPM/Xcode build the same sources for the real app.
#   scripts/build-core-modules.sh OUTDIR   ->  OUTDIR/{BipuuCore,BipuuSQLite}.swiftmodule + libBipuu*.a
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; mkdir -p "$OUT"
source scripts/_sdk.sh
COMMON=(-swift-version 6 -O -parse-as-library -emit-library -static -target "$SWIFT_TARGET" -sdk "$SDK")
swiftc "${COMMON[@]}" -module-name BipuuCore -emit-module -emit-module-path "$OUT/BipuuCore.swiftmodule" \
    BipuuCore/Sources/BipuuCore/*.swift -o "$OUT/libBipuuCore.a"
swiftc "${COMMON[@]}" -module-name BipuuSQLite -I "$OUT" -emit-module -emit-module-path "$OUT/BipuuSQLite.swiftmodule" \
    BipuuCore/Sources/BipuuSQLite/*.swift -o "$OUT/libBipuuSQLite.a"
