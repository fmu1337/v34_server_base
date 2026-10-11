#!/usr/bin/env bash
# Build protectcmds.ext.so (WeSTManCoder/ProtectCMDS, css34) for SourceMod.
# Run inside debian:11 (old glibc, so the result loads on Debian 11+/Ubuntu 20.04+):
#   docker run --rm -v "$PWD:/w" -w /w debian:11 extras/protectcmds/build.sh OUT_DIR
set -euo pipefail

OUT="$(mkdir -p "${1:-out}" && cd "${1:-out}" && pwd)"
REPO="${PROTECTCMDS_REPO:-https://github.com/WeSTManCoder/ProtectCMDS}"
COMMIT="${PROTECTCMDS_COMMIT:-bbdc76641ec905858657a50ba78894a41e6c25d3}"
WORK="$(mktemp -d)"

if command -v apt-get >/dev/null 2>&1 && [[ "$(id -u)" == 0 ]]; then
  apt-get update -qq || apt-get -o Acquire::Check-Valid-Until=false update -qq
  apt-get install -y -qq git make gcc g++ gcc-multilib g++-multilib ca-certificates >/dev/null
fi

fetch() { # repo ref dir
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2"
  git -C "$3" checkout -q FETCH_HEAD
}
fetch "${REPO}" "${COMMIT}" "${WORK}/pcmds"
fetch https://github.com/alliedmodders/sourcemod 1.6-dev "${WORK}/sm16"
fetch https://github.com/alliedmodders/metamod-source 1.10-dev "${WORK}/mm110"
fetch https://github.com/alliedmodders/hl2sdk episode1 "${WORK}/hl2sdk-episode1"

cd "${WORK}/pcmds"
# Newer gcc: SDK headers use `register` and trip -Werror; build as C++14 without -Werror.
sed -i 's/ -Werror / /; s/^CPPFLAGS += -Wno-non-virtual-dtor/CPPFLAGS += -std=gnu++14 -Wno-non-virtual-dtor/' Makefile
make ENGINE=css34 \
  SMSDK="${WORK}/sm16" MMSOURCE110="${WORK}/mm110" HL2SDK_ORIG="${WORK}/hl2sdk-episode1" \
  -j"$(nproc)" >"${OUT}/build.log" 2>&1 || { tail -n 40 "${OUT}/build.log"; exit 1; }

cp Release.css34/protectcmds.ext.so "${OUT}/"
echo "${COMMIT}" >"${OUT}/protectcmds.commit"
ls -la "${OUT}"
