#!/usr/bin/env bash
# CS:S v34 base installer (Linux).
#
#   ./install.sh                      interactive menu (when run from a terminal)
#   ./install.sh -y --dir /srv/css34  defaults: our SM line, all patches, SMAC
#
# Run ./install.sh --help for every option.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${ROOT}/manifest/sources.json"

# ---- defaults ---------------------------------------------------------------
DIR="${PWD}/css34"
CACHE_DIR=""
SERVER_SOURCE="auto"     # auto | mirror | rom4s | skip
SM_SOURCE=""             # ours | rom4s | myarena | none   (empty = manifest default)
SM_LINE=""               # ours only (empty = manifest default)
PATCHES="bufferfix,steamclient"
VALVE_RC="auto"          # auto | stock | debian9 | minimal
PLUGINS="smac,protectcmds"
SMAC_MODE="auto"         # auto | compile | prebuilt
INSTALL_DEPS=0
SMOKE=0
ASSUME_YES=0
PORT=27015
HOSTNAME_CFG="CS:S v34 server"
RCON_PASSWORD=""
FORCE=0

ALL_PATCHES="bufferfix steamclient steamdeny lanfix"
ALL_PLUGINS="smac protectcmds"

usage() {
  cat <<EOF
CS:S v34 base installer (Linux)

Usage: $0 [options]

Server:
  --dir DIR             install directory (default: ./css34)
  --server-source SRC   auto (mirror, then rom4s) | mirror | rom4s | skip
                        skip = install addons/patches into an existing --dir
  --cache DIR           download cache (default: DIR/.cache)
  --force               wipe an existing non-empty --dir before installing

Patches (--patch LIST, comma separated, or all / none;
default: bufferfix,steamclient):
  bufferfix     engine_*.so + server_i486.so: memcpy -> memmove (hangs,
                'Unknown command ":"', 'Incorrect price blob version!')
  steamclient   steamclient_i486.so: mute 'Assertion Failed: !"Implement me!"'
  steamdeny     engine: don't kick on Steam deny NoLicense / ConnectionLost /
                ConnectionError / ValidationStalled (GoDtm666)
  lanfix        engine: accept internet clients with sv_lan 1 (GoDtm666)
  --valve-rc V          auto | stock | debian9 | minimal
                        auto = debian9 with bufferfix, minimal without

SourceMod + Metamod:
  --sm SRC              ours (default) | rom4s | myarena | none
  --sm-line LINE        for --sm ours: $(manifest_lines | tr '\n' ' ')
                        (default: $(manifest_get sourcemod.ours.default_line))

Plugins:
  --plugins LIST        smac,protectcmds | all | none (default: smac,protectcmds)
                        protectcmds: ProtectCMDS extension (fmu1337 fork of WeSTManCoder's)
                        (client command flood/exploit filter; sends client
                        status/ping to SMAC's protected versions)
  --smac-mode MODE      auto (compile, fall back to prebuilt) | compile | prebuilt

Other:
  --port N              port in start-server.sh (default: 27015)
  --hostname NAME       hostname in server.cfg
  --rcon PASS           rcon_password in server.cfg
  --deps                install 32-bit runtime packages (apt/dnf, needs root)
  --deps-only           only install the packages, then exit
  --smoke               boot the server once and check MM/SM/plugins
  -y, --yes             no interactive menu
  -h, --help
EOF
}

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required (try --deps)"; }

# manifest_get a.b.c -> value (empty when missing/null)
manifest_get() {
  python3 -I - "${MANIFEST}" "$1" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    if isinstance(v, list):
        v = v[int(k)]
    elif isinstance(v, dict) and k in v:
        v = v[k]
    else:
        sys.exit(0)
if v is None:
    sys.exit(0)
print(v if not isinstance(v, bool) else str(v).lower())
PY
}

# manifest_releases LINE -> "tag sm mm" lines in order of preference
manifest_releases() {
  python3 -I - "${MANIFEST}" "$1" <<'PY'
import json, sys
line = json.load(open(sys.argv[1]))["sourcemod"]["ours"]["lines"].get(sys.argv[2])
for r in (line or {}).get("releases", []):
    print(r["tag"], r["sm"], r["mm"])
PY
}

manifest_lines() {
  python3 -I - "${MANIFEST}" <<'PY'
import json, sys
print("\n".join(json.load(open(sys.argv[1]))["sourcemod"]["ours"]["lines"]))
PY
}

# manifest_server_files linux -> "name sha256" lines
manifest_server_files() {
  python3 -I - "${MANIFEST}" "$1" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["server"][sys.argv[2]]:
    print(f["name"], f.get("sha256") or "-")
PY
}

has_item() { [[ ",$1," == *",$2,"* ]]; }

normalize_list() { # value all-items
  case "$1" in
    all) echo "${2// /,}" ;;
    none|"") echo "" ;;
    *) echo "$1" ;;
  esac
}

# ---- downloads --------------------------------------------------------------
curl_get() { # url out
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" && "$1" == https://github.com/* ]]; then
    auth=(-H "Authorization: token ${GITHUB_TOKEN}")
  fi
  curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 20 "${auth[@]}" -o "$2" "$1"
}

check_sha() { # file sha|-
  [[ "$2" == "-" || -z "$2" ]] && return 0
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [[ "${got}" == "$2" ]] || { warn "sha256 mismatch for $(basename "$1"): ${got}"; return 1; }
}

# fetch out sha url [url...] -> first URL that works, cached in CACHE_DIR
fetch() {
  local out="$1" sha="$2"; shift 2
  if [[ -s "${out}" ]] && check_sha "${out}" "${sha}"; then
    echo "    cached $(basename "${out}")"
    return 0
  fi
  local url
  for url in "$@"; do
    echo "    $(basename "${out}") <- ${url}"
    if curl_get "${url}" "${out}.part" && check_sha "${out}.part" "${sha}"; then
      mv -f "${out}.part" "${out}"
      return 0
    fi
    rm -f "${out}.part"
    warn "failed: ${url}"
  done
  return 1
}

unpack() { # archive dest
  mkdir -p "$2"
  case "$1" in
    *.tar.gz|*.tgz) tar -xzf "$1" -C "$2" ;;
    *.zip) unzip -qo "$1" -d "$2" || [[ $? -eq 1 ]] ;;  # 1 = warnings ('\' separators)
    *) die "unknown archive type: $1" ;;
  esac
}

# ---- steps ------------------------------------------------------------------
install_deps() {
  [[ "$(id -u)" == 0 ]] || die "--deps needs root"
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*)
      dpkg --add-architecture i386
      apt-get update -y
      local pkgs=(curl unzip python3 ca-certificates lib32gcc-s1 lib32stdc++6 lib32z1 libc6-i386 libstdc++6:i386 zlib1g:i386)
      apt-get install -y "${pkgs[@]}" || apt-get install -y "${pkgs[@]/lib32gcc-s1/lib32gcc1}"
      ;;
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*)
      (command -v dnf >/dev/null && dnf -y install curl unzip python3 glibc.i686 libstdc++.i686 zlib.i686) ||
        yum -y install curl unzip python3 glibc.i686 libstdc++.i686 zlib.i686
      ;;
    *) die "unsupported distro for --deps: ${ID:-unknown}; install 32-bit glibc/libstdc++/zlib manually" ;;
  esac
}

install_server() {
  if [[ -d "${DIR}" && -n "$(ls -A "${DIR}" 2>/dev/null | grep -v '^\.cache$' || true)" ]]; then
    [[ "${FORCE}" == 1 ]] || die "${DIR} is not empty (use --force to wipe it, or --server-source skip)"
    log "Wiping ${DIR}"
    find "${DIR}" -mindepth 1 -maxdepth 1 ! -name .cache -exec rm -rf {} +
  fi
  mkdir -p "${DIR}"

  local mirror rom4s name sha urls
  mirror="$(manifest_get server.mirror_release)"
  rom4s="$(manifest_get server.rom4s)"
  log "Server files (${SERVER_SOURCE})"
  while read -r name sha; do
    case "${SERVER_SOURCE}" in
      mirror) urls=("${mirror}/${name}") ;;
      rom4s)  urls=("${rom4s}/${name}") ;;
      *)      urls=("${mirror}/${name}" "${rom4s}/${name}") ;;
    esac
    fetch "${CACHE_DIR}/${name}" "${sha}" "${urls[@]}" || die "could not download ${name}"
    unpack "${CACHE_DIR}/${name}" "${DIR}"
  done < <(manifest_server_files linux)

  chmod +x "${DIR}"/srcds_* "${DIR}"/*.sh 2>/dev/null || true
  [[ -f "${DIR}/cstrike/bin/server_i486.so" ]] || die "server tree looks incomplete (no cstrike/bin/server_i486.so)"
}

apply_binary_patches() {
  local only=() p
  for p in ${PATCHES//,/ }; do only+=("${p}"); done
  [[ ${#only[@]} -eq 0 ]] && return 0
  log "Binary patches: ${only[*]}"
  python3 -I "${ROOT}/patches/srcds_patch.py" "${DIR}" --only "$(IFS=,; echo "${only[*]}")" \
    || die "binary patch failed (see above)"
}

install_valve_rc() {
  local mode="${VALVE_RC}"
  if [[ "${mode}" == auto ]]; then
    if has_item "${PATCHES}" bufferfix; then mode=debian9; else mode=minimal; fi
  fi
  [[ "${mode}" == stock ]] && return 0
  log "valve.rc: ${mode}"
  mkdir -p "${DIR}/cstrike/cfg"
  [[ -f "${DIR}/cstrike/cfg/valve.rc" && ! -f "${DIR}/cstrike/cfg/valve.rc.orig" ]] &&
    cp -f "${DIR}/cstrike/cfg/valve.rc" "${DIR}/cstrike/cfg/valve.rc.orig"
  cp -f "${ROOT}/configs/valve-${mode}.rc" "${DIR}/cstrike/cfg/valve.rc"
}

write_sourcemod_vdf() {
  mkdir -p "${DIR}/cstrike/addons/metamod"
  [[ -f "${DIR}/cstrike/addons/metamod/sourcemod.vdf" ]] && return 0
  cat >"${DIR}/cstrike/addons/metamod/sourcemod.vdf" <<'EOF'
"Metamod Plugin"
{
	"alias"		"sourcemod"
	"file"		"addons/sourcemod/bin/sourcemod_mm"
}
EOF
}

install_sourcemod() {
  [[ "${SM_SOURCE}" == none ]] && return 0
  local cs="${DIR}/cstrike" mm_url sm_url
  log "Metamod + SourceMod: ${SM_SOURCE}${SM_LINE:+ (${SM_LINE})}"
  rm -rf "${cs}/addons/metamod" "${cs}/addons/metamod.vdf" "${cs}/addons/sourcemod"

  case "${SM_SOURCE}" in
    ours)
      local base tag smn mmn ok=0
      base="$(manifest_get sourcemod.ours.release)"
      [[ -n "$(manifest_releases "${SM_LINE}")" ]] || die "unknown --sm-line ${SM_LINE}"
      # First release of the line whose files download (one may be a draft while rebuilt).
      while read -r tag smn mmn; do
        mm_url="${base}/${tag}/${mmn}-linux.tar.gz"
        sm_url="${base}/${tag}/${smn}-linux.tar.gz"
        if fetch "${CACHE_DIR}/ours-${tag}-${mmn}-linux.tar.gz" - "${mm_url}" &&
           fetch "${CACHE_DIR}/ours-${tag}-${smn}-linux.tar.gz" - "${sm_url}"; then
          ok=1
          echo "    release ${tag}"
          break
        fi
        warn "release ${tag} is not downloadable, trying the next one"
      done < <(manifest_releases "${SM_LINE}")
      [[ "${ok}" == 1 ]] || die "no downloadable release for --sm-line ${SM_LINE}"
      unpack "${CACHE_DIR}/ours-${tag}-${mmn}-linux.tar.gz" "${cs}"
      unpack "${CACHE_DIR}/ours-${tag}-${smn}-linux.tar.gz" "${cs}"
      mm_url=""   # already unpacked
      ;;
    rom4s)
      mm_url="$(manifest_get sourcemod.rom4s.linux.mm)"
      sm_url="$(manifest_get sourcemod.rom4s.linux.sm)"
      ;;
    myarena)
      local url tmp
      url="$(manifest_get sourcemod.myarena.linux.bundle)"
      fetch "${CACHE_DIR}/myarena-$(basename "${url}")" - "${url}" || die "could not download the myarena bundle"
      tmp="$(mktemp -d)"
      unpack "${CACHE_DIR}/myarena-$(basename "${url}")" "${tmp}"
      # The bundle may be rooted at addons/, cstrike/ or a wrapper directory.
      local addons
      addons="$(find "${tmp}" -type d -name addons -path '*addons' | awk '{print length, $0}' | sort -n | head -n1 | cut -d' ' -f2-)"
      [[ -n "${addons}" && -d "${addons}/sourcemod" ]] || die "unexpected myarena bundle layout"
      mkdir -p "${cs}"
      cp -a "$(dirname "${addons}")/." "${cs}/"
      rm -rf "${tmp}"
      ;;
    *) die "unknown --sm ${SM_SOURCE}" ;;
  esac

  if [[ -n "${mm_url:-}" ]]; then
    fetch "${CACHE_DIR}/${SM_SOURCE}-$(basename "${mm_url}")" - "${mm_url}" || die "could not download Metamod"
    fetch "${CACHE_DIR}/${SM_SOURCE}-$(basename "${sm_url}")" - "${sm_url}" || die "could not download SourceMod"
    unpack "${CACHE_DIR}/${SM_SOURCE}-$(basename "${mm_url}")" "${cs}"
    unpack "${CACHE_DIR}/${SM_SOURCE}-$(basename "${sm_url}")" "${cs}"
  fi

  [[ -f "${cs}/addons/metamod.vdf" ]] || die "metamod.vdf missing after install"
  [[ -d "${cs}/addons/sourcemod/bin" ]] || die "SourceMod missing after install"
  write_sourcemod_vdf
  sed -i 's/"AutoUpdate"[[:space:]]*"yes"/"AutoUpdate"\t\t"no"/' "${cs}/addons/sourcemod/configs/core.cfg" 2>/dev/null || true
  find "${cs}/addons" -name '*.so' -exec chmod +x {} + 2>/dev/null || true
  chmod +x "${cs}/addons/sourcemod/scripting/spcomp"* 2>/dev/null || true

  # SM 1.12+ geoip.ext reads GeoIP2 *.mmdb (not shipped in the packages).
  local geo="${cs}/addons/sourcemod/configs/geoip"
  if [[ -f "${cs}/addons/sourcemod/extensions/geoip.ext.so" && ! -f "${geo}/GeoIP.dat" ]] &&
     ! ls "${geo}"/*.mmdb >/dev/null 2>&1; then
    mkdir -p "${geo}"
    if fetch "${CACHE_DIR}/GeoLite2-Country.mmdb" - "$(manifest_get geoip2)"; then
      cp -f "${CACHE_DIR}/GeoLite2-Country.mmdb" "${geo}/"
    else
      warn "no GeoIP2 database; geoip.ext (and SMAC core) may fail to load"
    fi
  fi
}

install_smac() {
  local sm="${DIR}/cstrike/addons/sourcemod"
  [[ -d "${sm}" ]] || { warn "SMAC needs SourceMod; skipped"; return 0; }
  log "SMAC (${SMAC_MODE})"
  local url src tmp
  url="$(manifest_get plugins.smac.archive)"
  fetch "${CACHE_DIR}/smac_v34.tar.gz" - "${url}" || die "could not download SMAC"
  tmp="$(mktemp -d)"
  tar -xzf "${CACHE_DIR}/smac_v34.tar.gz" -C "${tmp}"
  src="${tmp}/$(manifest_get plugins.smac.dir)"
  [[ -d "${src}/addons/sourcemod" ]] || die "unexpected SMAC archive layout"

  local compiled=0
  if [[ "${SMAC_MODE}" != prebuilt ]]; then
    local spcomp="${sm}/scripting/spcomp"
    if [[ -x "${spcomp}" ]] && SPCOMP="${spcomp}" SM_INCLUDE="${sm}/scripting/include" \
         OUT_DIR="${src}/addons/sourcemod/plugins" bash "${src}/scripts/compile-all.sh" >"${tmp}/compile.log" 2>&1; then
      compiled=1
      echo "    compiled with $("${spcomp}" 2>&1 | head -n1 || true)"
    else
      [[ "${SMAC_MODE}" == compile ]] && { cat "${tmp}/compile.log" >&2; die "SMAC compile failed"; }
      warn "SMAC compile failed, using prebuilt .smx from the repo (log: ${CACHE_DIR}/smac-compile.log)"
      cp -f "${tmp}/compile.log" "${CACHE_DIR}/smac-compile.log" 2>/dev/null || true
      # compile-all.sh may have left partial output; restore the repo's .smx
      rm -rf "${src}"
      tar -xzf "${CACHE_DIR}/smac_v34.tar.gz" -C "${tmp}"
    fi
  fi

  cp -a "${src}/addons/sourcemod/." "${sm}/"
  mkdir -p "${DIR}/cstrike/cfg"
  cp -a "${src}/cfg/." "${DIR}/cstrike/cfg/"
  [[ -d "${src}/materials" ]] && cp -a "${src}/materials" "${DIR}/cstrike/"
  rm -rf "${tmp}"
  echo "    $(ls "${sm}/plugins"/smac*.smx | wc -l) SMAC plugins (compiled=${compiled})"
}

install_protectcmds() {
  local sm="${DIR}/cstrike/addons/sourcemod" src="${ROOT}/extras/protectcmds"
  [[ -d "${sm}" ]] || { warn "ProtectCMDS needs SourceMod; skipped"; return 0; }
  log "ProtectCMDS"
  # SourceMod 1.13 only loads extension API >= 9, 1.11/1.12 only <= 8.
  local api=api7 url
  if grep -aqE '1\.1[3-9]\.0\.[0-9]' "${sm}/bin/sourcemod.logic.so" 2>/dev/null; then
    api=api9
  fi
  url="$(manifest_get "plugins.protectcmds.ext_${api}")"
  fetch "${CACHE_DIR}/$(basename "${url}")" - "${url}" || die "could not download ProtectCMDS"
  install -m 755 "${CACHE_DIR}/$(basename "${url}")" "${sm}/extensions/protectcmds.ext.so"
  echo "    $(basename "${url}")"
  : >"${sm}/extensions/protectcmds.autoload"   # nothing #includes it, load it anyway
  mkdir -p "${sm}/data/protectcmds"
  # keep a config the admin already edited
  [[ -f "${sm}/data/protectcmds/protectcmds.ini" ]] || cp "${src}/protectcmds.ini" "${sm}/data/protectcmds/"
  [[ -f "${sm}/data/protectcmds/blockcmds.txt" ]] || cp "${src}/blockcmds.txt" "${sm}/data/protectcmds/"
  if has_item "${PATCHES}" bufferfix; then
    # same memcpy fix is already in the binaries
    sed -i 's/^osfix_enable *= *1/osfix_enable = 0/' "${sm}/data/protectcmds/protectcmds.ini"
  fi
  if "${sm}/scripting/spcomp" "${src}/protectcmds_status.sp" -o"${sm}/plugins/protectcmds_status.smx" \
       -i"${sm}/scripting/include" >"${CACHE_DIR}/protectcmds-compile.log" 2>&1; then
    echo "    status/ping -> sm_status/sm_ping (protectcmds_status.smx)"
  else
    warn "protectcmds_status.sp did not compile (log: ${CACHE_DIR}/protectcmds-compile.log)"
  fi
}

write_configs() {
  local cfg="${DIR}/cstrike/cfg/server.cfg"
  mkdir -p "${DIR}/cstrike/cfg"
  if [[ ! -f "${cfg}" || ! -f "${DIR}/.installer" ]]; then
    log "server.cfg"
    [[ -f "${cfg}" && ! -f "${cfg}.orig" ]] && cp -f "${cfg}" "${cfg}.orig"
    {
      echo "hostname \"${HOSTNAME_CFG}\""
      [[ -n "${RCON_PASSWORD}" ]] && echo "rcon_password \"${RCON_PASSWORD}\""
      echo "sv_lan 0"
      echo "sv_cheats 0"
      echo "sv_pure 0"
      echo "mp_dynamicpricing 0"
      echo "exec banned_user.cfg"
      echo "exec banned_ip.cfg"
      echo "writeid"
      echo "writeip"
    } >"${cfg}"
  fi

  # A missing or empty ban list makes the engine print "file size larger than 20MB".
  local f
  for f in banned_user.cfg banned_ip.cfg; do
    [[ -s "${DIR}/cstrike/cfg/${f}" ]] || echo "// ${f}" >"${DIR}/cstrike/cfg/${f}"
  done

  cat >"${DIR}/start-server.sh" <<EOF
#!/usr/bin/env bash
# Generated by v34_server_base install.sh
cd "\$(dirname "\$0")"
export LD_LIBRARY_PATH=".:bin:\${LD_LIBRARY_PATH:-}"
exec ./srcds_run -game cstrike -console -port \${PORT:-${PORT}} -tickrate 66 \\
  -maxplayers \${MAXPLAYERS:-32} -insecure -nomaster -localcser -norestart \\
  +map \${MAP:-de_dust2} "\$@"
EOF
  chmod +x "${DIR}/start-server.sh"
}

write_state() {
  cat >"${DIR}/.installer" <<EOF
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
installer=$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)
server_source=${SERVER_SOURCE}
sm=${SM_SOURCE}
sm_line=${SM_LINE}
patches=${PATCHES}
valve_rc=${VALVE_RC}
plugins=${PLUGINS}
EOF
}

smoke() {
  log "Smoke test"
  python3 -I "${ROOT}/lib/smoke.py" "${DIR}" \
    --sm "${SM_SOURCE}" \
    $(has_item "${PLUGINS}" smac && echo --expect-plugin smac) \
    $(has_item "${PLUGINS}" protectcmds && echo --expect-ext ProtectCMDS --expect-plugin ProtectCMDS:status/ping)
}

interactive() {
  local a lines
  ask() { local q="$1" def="$2"; read -r -p "$q [$def]: " a </dev/tty; echo "${a:-$def}"; }
  echo "CS:S v34 base installer"
  DIR="$(ask "Install directory" "${DIR}")"
  SERVER_SOURCE="$(ask "Server files: auto | mirror | rom4s | skip" "${SERVER_SOURCE}")"
  SM_SOURCE="$(ask "SourceMod: ours | rom4s | myarena | none" "${SM_SOURCE}")"
  if [[ "${SM_SOURCE}" == ours ]]; then
    lines="$(manifest_lines | tr '\n' ' ')"
    SM_LINE="$(ask "SourceMod line (${lines% })" "${SM_LINE}")"
  fi
  PATCHES="$(ask "Patches (bufferfix,steamclient,steamdeny,lanfix | all | none)" "${PATCHES}")"
  VALVE_RC="$(ask "valve.rc: auto | stock | debian9 | minimal" "${VALVE_RC}")"
  PLUGINS="$(ask "Plugins (smac,protectcmds | none)" "${PLUGINS}")"
  [[ "$(ask "Run smoke test after install? (y/n)" n)" == y ]] && SMOKE=1
  return 0
}

# ---- main -------------------------------------------------------------------
ARGC=$#
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --cache) CACHE_DIR="$2"; shift 2 ;;
    --server-source) SERVER_SOURCE="$2"; shift 2 ;;
    --sm) SM_SOURCE="$2"; shift 2 ;;
    --sm-line) SM_LINE="$2"; shift 2 ;;
    --patch|--patches) PATCHES="$2"; shift 2 ;;
    --valve-rc) VALVE_RC="$2"; shift 2 ;;
    --plugins) PLUGINS="$2"; shift 2 ;;
    --smac-mode) SMAC_MODE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --hostname) HOSTNAME_CFG="$2"; shift 2 ;;
    --rcon) RCON_PASSWORD="$2"; shift 2 ;;
    --deps) INSTALL_DEPS=1; shift ;;
    --deps-only) INSTALL_DEPS=2; shift ;;
    --smoke) SMOKE=1; shift ;;
    --force) FORCE=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ "${INSTALL_DEPS}" != 0 ]] && install_deps
[[ "${INSTALL_DEPS}" == 2 ]] && exit 0
need python3; need curl; need unzip; need tar
[[ -f "${MANIFEST}" ]] || die "missing ${MANIFEST}"

SM_SOURCE="${SM_SOURCE:-$(manifest_get sourcemod.default)}"
SM_LINE="${SM_LINE:-$(manifest_get sourcemod.ours.default_line)}"
if [[ "${ARGC}" -eq 0 && "${ASSUME_YES}" == 0 && -t 0 ]]; then
  interactive
fi
[[ "${SM_SOURCE}" == ours ]] || SM_LINE=""

PATCHES="$(normalize_list "${PATCHES}" "${ALL_PATCHES}")"
PLUGINS="$(normalize_list "${PLUGINS}" "${ALL_PLUGINS}")"
for p in ${PATCHES//,/ }; do [[ " ${ALL_PATCHES} " == *" ${p} "* ]] || die "unknown patch: ${p}"; done
for p in ${PLUGINS//,/ }; do [[ " ${ALL_PLUGINS} " == *" ${p} "* ]] || die "unknown plugin: ${p}"; done
case "${VALVE_RC}" in auto|stock|debian9|minimal) ;; *) die "unknown --valve-rc ${VALVE_RC}" ;; esac
case "${SERVER_SOURCE}" in auto|mirror|rom4s|skip) ;; *) die "unknown --server-source ${SERVER_SOURCE}" ;; esac
case "${SMAC_MODE}" in auto|compile|prebuilt) ;; *) die "unknown --smac-mode ${SMAC_MODE}" ;; esac

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"
CACHE_DIR="${CACHE_DIR:-${DIR}/.cache}"
mkdir -p "${CACHE_DIR}"

log "Install to ${DIR}"
echo "    server=${SERVER_SOURCE} sm=${SM_SOURCE}${SM_LINE:+/${SM_LINE}} patches=${PATCHES:-none} valve.rc=${VALVE_RC} plugins=${PLUGINS:-none}"

if [[ "${SERVER_SOURCE}" == skip ]]; then
  [[ -f "${DIR}/cstrike/bin/server_i486.so" ]] || die "--server-source skip: no server in ${DIR}"
else
  install_server
fi
apply_binary_patches
install_valve_rc
install_sourcemod
has_item "${PLUGINS}" smac && install_smac
has_item "${PLUGINS}" protectcmds && install_protectcmds
write_configs
write_state

log "Done: ${DIR}"
echo "    start: ${DIR}/start-server.sh   (PORT, MAXPLAYERS, MAP env vars)"
[[ "${SMOKE}" == 1 ]] && smoke
exit 0
