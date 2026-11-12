#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Calightra Contributors.
#
# Build the Verilated Caliptra 2.1 Core RTL into WebAssembly (WASM)
# and stage static firmware assets into www/ for browser execution
# and GitHub Pages deployment.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WWW_DIR="${REPO_DIR}/www"
FW_DIR="${REPO_DIR}/fw"

# Activate local emsdk automatically if em++ is not already on PATH
if ! command -v em++ >/dev/null 2>&1; then
    if [[ -n "${EMSDK:-}" && -f "${EMSDK}/emsdk_env.sh" ]]; then
        # shellcheck disable=SC1091
        source "${EMSDK}/emsdk_env.sh" >/dev/null
    elif [[ -f "${HOME}/.cache/calightra-wasm/emsdk/emsdk_env.sh" ]]; then
        # shellcheck disable=SC1091
        source "${HOME}/.cache/calightra-wasm/emsdk/emsdk_env.sh" >/dev/null
    fi
fi

if ! command -v verilator >/dev/null 2>&1; then
    echo "Error: 'verilator' not found on PATH." >&2
    exit 1
fi
if ! command -v em++ >/dev/null 2>&1; then
    echo "Error: 'em++' (Emscripten SDK) not found on PATH." >&2
    exit 1
fi

echo "=== Calightra WASM Build ==="
echo "  Verilator  : $(verilator --version | head -n 1)"
echo "  Emscripten : $(em++ --version | head -n 1)"

mkdir -p "${WWW_DIR}"

# 1. Verilate Caliptra 2.1 RTL & compile/link WebAssembly module
make -C "${REPO_DIR}/wasm" WWW_DIR="${WWW_DIR}"

# 2. Stage Caliptra 2.1 ROM & Firmware Bundles into www/
cp -f "${FW_DIR}/fake-caliptra-rom.bin"        "${WWW_DIR}/fake-caliptra-rom.bin"
cp -f "${FW_DIR}/fake-image-bundle-mldsa.bin"  "${WWW_DIR}/fake-image-bundle-mldsa.bin"
cp -f "${FW_DIR}/fake-image-bundle-lms.bin"    "${WWW_DIR}/fake-image-bundle-lms.bin"
cp -f "${FW_DIR}/caliptra-rom-with-log.bin"    "${WWW_DIR}/caliptra-rom-with-log.bin"
cp -f "${FW_DIR}/image-bundle-mldsa.bin"       "${WWW_DIR}/image-bundle-mldsa.bin"
cp -f "${FW_DIR}/image-bundle-lms.bin"         "${WWW_DIR}/image-bundle-lms.bin"

# 3. Generate www/build-info.json
VERILATOR_VER="$(verilator --version | awk '{print $2}')"
EMCC_VER="$(em++ --version | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "unknown")"
GIT_REV="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo "local")"

cat > "${WWW_DIR}/build-info.json" <<EOF
{
  "caliptra_release": "2.1",
  "engine": "Calightra Phase 2 · Verilator ${VERILATOR_VER} (WASM)",
  "emscripten_version": "${EMCC_VER}",
  "rom_version": "2.1.3",
  "fmc_version": "2.1.4",
  "runtime_version": "2.1.4",
  "caliptra_rtl_rev": "49370266d12cb0c4a8f71b3a0ff7e54ba7d4866e",
  "caliptra_sw_rev": "dd1e79d5bf55a9bd5bdb05915757eaf34844145d",
  "calightra_rev": "${GIT_REV}",
  "features": {
    "verilated_rtl": true,
    "adams_bridge_pqc": true,
    "ocp_lock": true
  }
}
EOF

ls -lh "${WWW_DIR}/calightra_verilated.js" "${WWW_DIR}/calightra_verilated.wasm"
echo "=== Build Complete ==="
