#!/usr/bin/env bash
# Build protectcmds.ext.so (fmu1337/ProtectCMDS, fork of WeSTManCoder/ProtectCMDS; css34) for SourceMod.
# Run inside debian:11 (old glibc, so the result loads on Debian 11+/Ubuntu 20.04+):
#   docker run --rm -v "$PWD:/w" -w /w debian:11 extras/protectcmds/build.sh OUT_DIR
#
# Two binaries, because SourceMod changed the extension API in between:
#   protectcmds-api7.ext.so  SM 1.6 SDK   -> SourceMod 1.11 / 1.12 (accept API <= 8)
#   protectcmds-api9.ext.so  SM 1.13.0.7394 SDK -> SourceMod 1.13 (7394 loads only 9, 7472 loads 9..11)
set -euo pipefail

OUT="$(mkdir -p "${1:-out}" && cd "${1:-out}" && pwd)"
REPO="${PROTECTCMDS_REPO:-https://github.com/fmu1337/ProtectCMDS}"
COMMIT="${PROTECTCMDS_COMMIT:-bbdc76641ec905858657a50ba78894a41e6c25d3}"
SM113_COMMIT="${SM113_COMMIT:-bd1bde7def4c1e3e584c320dfb2ac974eb4d7433}"  # 1.13.0.7394: API 9 (1.13 loads 9..11)
WORK="$(mktemp -d)"

if ! command -v make >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1 && [[ "$(id -u)" == 0 ]]; then
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
fetch https://github.com/alliedmodders/sourcemod "${SM113_COMMIT}" "${WORK}/sm113"
git -C "${WORK}/sm113" submodule update -q --init --depth 1 sourcepawn public/amtl
fetch https://github.com/alliedmodders/metamod-source 1.10-dev "${WORK}/mm110"
fetch https://github.com/alliedmodders/hl2sdk episode1 "${WORK}/hl2sdk-episode1"

build() { # name smsdk
  local name="$1" smsdk="$2" src="${WORK}/build-$1"
  cp -a "${WORK}/pcmds" "${src}"
  cd "${src}"
  # Newer gcc: SDK headers use `register` and trip -Werror; C++14 (C++17 makes
  # the SDK's clamp() ambiguous with std::clamp).
  sed -i 's/ -Werror / /; s/^CPPFLAGS += -Wno-non-virtual-dtor/CPPFLAGS += -std=gnu++14 -Wno-non-virtual-dtor/' Makefile
  if [[ "${name}" == api9 ]]; then
    # SM 1.13 layout: SourcePawn and AMTL headers moved; take its smsdk_ext and
    # keep eiface.h, which the old one pulled in for css34.
    printf '\nINCLUDE += -I$(SMSDK)/sourcepawn/include -I$(SMSDK)/public/amtl -I$(SMSDK)/public/amtl/amtl\n' >>Makefile
    cp "${smsdk}/public/smsdk_ext.cpp" "${smsdk}/public/smsdk_ext.h" sdk/
    sed -i 's|^#if !defined METAMOD_PLAPI_VERSION|#ifdef ENGINE_CSS34\n#include <eiface.h>\n#endif\n\n&|' sdk/smsdk_ext.h
    grep -q '^#ifdef ENGINE_CSS34' sdk/smsdk_ext.h || { echo "smsdk_ext.h patch failed" >&2; exit 1; }
  fi
  make ENGINE=css34 \
    SMSDK="${smsdk}" MMSOURCE110="${WORK}/mm110" HL2SDK_ORIG="${WORK}/hl2sdk-episode1" \
    -j"$(nproc)" >"${OUT}/build-${name}.log" 2>&1 || { tail -n 40 "${OUT}/build-${name}.log"; exit 1; }
  cp Release.css34/protectcmds.ext.so "${OUT}/protectcmds-${name}.ext.so"
}

build api7 "${WORK}/sm16"
build api9 "${WORK}/sm113"

echo "${COMMIT}" >"${OUT}/protectcmds.commit"
ls -la "${OUT}"
