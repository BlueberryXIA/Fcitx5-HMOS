#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
#
#
# Fetch every third-party source tree needed to build the Fcitx5/Rime port for
# HarmonyOS NEXT.
#
# Sources land in entry/src/main/cpp/thirdparty/<name>.  The script is
# idempotent: an already-populated directory is left alone unless --force is
# given.  Archive downloads resume across invocations, and a component that
# fails only aborts that component -- everything else still gets fetched.
#
# Usage:
#   scripts/fetch_sources.sh                    # everything
#   scripts/fetch_sources.sh --only boost       # one component
#   scripts/fetch_sources.sh --only lua,fcitx5  # a few
#   scripts/fetch_sources.sh --force            # re-fetch from scratch
#
# fcitx5-lua and fcitx5-rime are pinned to the exact commits fcitx5-android
# builds against; fcitx5 core comes from the master branch (see fetch_fcitx5).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Native sources live under the HAP module's cpp directory, not at the
# repository root, so the module picks them up through its own CMake build.
CPP_DIR="${CPP_DIR_OVERRIDE:-${PROJECT_ROOT}/entry/src/main/cpp}"
TP_DIR="${CPP_DIR}/thirdparty"
DL_DIR="${TP_DIR}/.downloads"
FORCE=""
ONLY=""

# GitHub is frequently unreachable or unreliable from mainland China.  When
# GH_PROXY is non-empty, every github.com, raw.githubusercontent.com and
# objects.githubusercontent.com URL is routed through the given accelerator;
# set GH_PROXY= to talk to GitHub directly.
GH_PROXY="${GH_PROXY:-https://gh-proxy.com}"
GH_PREFIXES_RE='^https://github\.com/|^https://raw\.githubusercontent\.com/|^https://objects\.githubusercontent\.com/'

gh_url() {
  local url="$1"
  [ -z "${GH_PROXY}" ] && { printf '%s' "${url}"; return; }
  if [[ "${url}" =~ ${GH_PREFIXES_RE} ]]; then
    printf '%s/%s' "${GH_PROXY}" "${url}"
  else
    printf '%s' "${url}"
  fi
}

# git's insteadOf rewriting proxies every GitHub remote without having to
# rewrite individual URLs (including the ones baked into .gitmodules).
GIT_PROXY_ARGS=()
if [ -n "${GH_PROXY}" ]; then
  GIT_PROXY_ARGS=(-c "url.${GH_PROXY}/https://github.com/.insteadOf=https://github.com/")
fi

git_proxied() { git "${GIT_PROXY_ARGS[@]}" "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE="--force"; shift ;;
    --only)  ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "${CPP_DIR}" ]; then
  echo "native cpp directory not found: ${CPP_DIR}" >&2
  exit 1
fi

mkdir -p "${TP_DIR}" "${DL_DIR}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; }

# The network in some build environments drops TLS connections sporadically, so
# every remote operation is retried with a growing backoff.
retry() {
  local attempts="$1"; shift
  local attempt=1 exit_code=0
  while :; do
    "$@" && return 0
    exit_code=$?
    if [ "${attempt}" -ge "${attempts}" ]; then
      return "${exit_code}"
    fi
    warn "attempt ${attempt}/${attempts} failed, retrying in $((attempt * 2))s: $1"
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

FAILED=()

# A component counts as fetched only when it has real content.  A directory
# holding nothing but .git is the residue of an interrupted clone and must be
# re-fetched rather than silently skipped.
already_fetched() {
  local name="$1"
  local dir="${TP_DIR}/${name}"
  [ -d "${dir}" ] || return 1
  [ "${FORCE}" = "--force" ] && return 1
  local count
  count="$(find "${dir}" -mindepth 1 -maxdepth 1 ! -name '.git' 2>/dev/null | wc -l)"
  [ "${count}" -gt 0 ]
}

# git_clone <url> <dir> <ref>
git_clone() {
  local url="$1" dir="$2" ref="$3"
  if already_fetched "${dir}"; then log "${dir}: present, skipping"; return 0; fi
  rm -rf "${TP_DIR:?}/${dir}"
  log "cloning ${dir} @ ${ref}"
  if retry 3 git_proxied clone --depth 1 --branch "${ref}" "${url}" "${TP_DIR}/${dir}"; then
    :
  else
    warn "shallow clone of ${ref} failed, trying full clone + checkout"
    rm -rf "${TP_DIR:?}/${dir}"
    retry 2 git_proxied clone "${url}" "${TP_DIR}/${dir}" || return 1
    git_proxied -C "${TP_DIR}/${dir}" checkout "${ref}" || return 1
  fi
  if [ -f "${TP_DIR}/${dir}/.gitmodules" ]; then
    retry 2 git_proxied -C "${TP_DIR}/${dir}" submodule update --init --recursive --depth 1 || \
      warn "submodule init failed for ${dir} (may be harmless)"
  fi
  return 0
}

# git_clone_at <url> <dir> <commit-sha>
# Checks out one exact commit that is not reachable by tag (used for the fcitx5
# stack): it first tries a shallow `fetch origin <sha>`, and only if that fails
# does it fall back to a clone of the default branch.
#
# Fetching an arbitrary object requires the server to allow it
# (uploadpack.allowReachableSHA1InWant) and, on a slow link, can take many
# minutes without making visible progress.  If it does not succeed we fall back
# to a shallow clone of the default branch, which contains the pinned commit or
# a later one; the caller is warned because that trades reproducibility for
# being able to build at all.
git_clone_at() {
  local url="$1" dir="$2" sha="$3"
  if already_fetched "${dir}"; then log "${dir}: present, skipping"; return 0; fi
  rm -rf "${TP_DIR:?}/${dir}"
  log "cloning ${dir} @ ${sha:0:12}"
  git init -q "${TP_DIR}/${dir}"
  git_proxied -C "${TP_DIR}/${dir}" remote add origin "${url}"
  # Bounded: on a slow link this fetch can sit for a very long time without
  # transferring anything, so give it a fixed budget before falling back.
  if timeout "${GIT_SHA_FETCH_TIMEOUT:-240}" \
       git_proxied -C "${TP_DIR}/${dir}" fetch --depth 1 origin "${sha}"; then
    git_proxied -C "${TP_DIR}/${dir}" checkout -q "${sha}" || return 1
    return 0
  fi

  warn "${dir}: cannot fetch ${sha:0:12} directly; falling back to the tip of the default branch"
  rm -rf "${TP_DIR:?}/${dir}"
  retry 3 git_proxied clone --depth 1 "${url}" "${TP_DIR}/${dir}" || return 1
  git_proxied -C "${TP_DIR}/${dir}" submodule update --init --recursive --depth 1 2>/dev/null || true
  return 0
}

# fetch_archive <url> <dir> <strip-prefix>
# Downloads into a persistent cache so an interrupted transfer can resume.
fetch_archive() {
  local url="$1" dir="$2" strip_prefix="$3"
  if already_fetched "${dir}"; then log "${dir}: present, skipping"; return 0; fi
  local archive="${DL_DIR}/$(basename "${url%%\?*}")"
  url="$(gh_url "${url}")"
  log "downloading ${dir} <- $(basename "${archive}")"
  retry 5 curl -fL --retry 5 --retry-delay 3 --retry-all-errors -C - \
    -o "${archive}" "${url}" || return 1
  local extract_dir
  extract_dir="$(mktemp -d)"
  tar -xf "${archive}" -C "${extract_dir}" || { rm -rf "${extract_dir}"; return 1; }
  rm -rf "${TP_DIR:?}/${dir}"
  mv "${extract_dir}/${strip_prefix}" "${TP_DIR}/${dir}" ||
    { rm -rf "${extract_dir}"; return 1; }
  rm -rf "${extract_dir}"
  return 0
}

# fetch_files <dir> <base-url> <file>...
# Downloads a handful of individual files into <dir>.  Used for the X11 keysym
# headers, which are pure constants and therefore architecture-independent.
fetch_files() {
  local dir="$1" base="$2"; shift 2
  if already_fetched "${dir}" && [ "$(find "${TP_DIR}/${dir}" -type f 2>/dev/null | wc -l)" -ge "$#" ]; then
    log "${dir}: present, skipping"; return 0
  fi
  mkdir -p "${TP_DIR}/${dir}"
  local file
  for file in "$@"; do
    log "downloading ${dir}/${file}"
    retry 5 curl -fL --retry 5 --retry-delay 3 --retry-all-errors -C - \
      -o "${TP_DIR}/${dir}/${file}" "$(gh_url "${base}/${file}")" || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Component definitions
# ---------------------------------------------------------------------------

fetch_x11_headers() {
  # librime and fcitx5 include <X11/keysym.h> unconditionally for key-code
  # constants, but OHOS ships no X11 headers.  Vendor the keysym definitions
  # from xorgproto: they are just #define lists with no platform dependency.
  fetch_files "xorgproto/include/X11" \
    "https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/raw/master/include/X11" \
    keysym.h keysymdef.h XF86keysym.h Sunkeysym.h DECkeysym.h HPkeysym.h ap_keysym.h
}

fetch_boost() {
  # The GitHub release archive is preferred because it can be routed through
  # the accelerator; archives.boost.io is the direct fallback.  Both are the
  # full superproject tree, which is what we need: Boost headers plus the
  # libs/regex sources that we compile into libboost_regex.a.
  if ! fetch_archive \
        "https://github.com/boostorg/boost/releases/download/boost-1.86.0/boost-1.86.0-cmake.tar.gz" \
        "boost" "boost-1.86.0"; then
    warn "GitHub boost archive unavailable, falling back to archives.boost.io"
    fetch_archive \
      "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2" \
      "boost" "boost_1_86_0" || return 1
  fi

  # Guard against a partially extracted or unexpected archive layout, which
  # would otherwise surface much later as a confusing compile error.
  if [ ! -f "${TP_DIR}/boost/boost/version.hpp" ]; then
    err "boost headers missing at ${TP_DIR}/boost/boost/version.hpp"; return 1
  fi
  if [ ! -d "${TP_DIR}/boost/libs/regex/src" ]; then
    err "boost libs/regex sources missing at ${TP_DIR}/boost/libs/regex/src"; return 1
  fi
  return 0
}

# Just the Boost.Regex sources.
#
# Needed for the header-tree fallback in scripts/build_thirdparty.sh: when the
# full Boost archive is impractical to download, the headers come from the build
# host and only this handful of translation units is fetched.  The tag must
# match the header tree's release, so it is derived from
# /usr/include/boost/version.hpp unless BOOST_REGEX_TAG is set explicitly.
fetch_boost_regex() {
  local tag="${BOOST_REGEX_TAG:-}"
  if [ -z "${tag}" ]; then
    local boost_lib_version=""
    if [ -f /usr/include/boost/version.hpp ]; then
      boost_lib_version="$(sed -n 's/.*BOOST_LIB_VERSION "\([^"]*\)".*/\1/p' \
                  /usr/include/boost/version.hpp | head -1)"
    fi
    if [ -n "${boost_lib_version}" ]; then
      tag="boost-${boost_lib_version//_/.}.0"
    else
      tag="boost-1.86.0"
    fi
  fi
  log "boost regex sources use tag ${tag}"
  git_clone https://github.com/boostorg/regex.git regex "${tag}"
}

fetch_fcitx5() {
  # fcitx5-android pins fcitx5 core to a development commit that is newer than
  # the newest release tag (the addons require a core version only present on
  # master), and `git fetch <sha>` through an accelerator is impractically slow.
  # The master branch archive is therefore the primary source here, which means
  # the fetched core tracks master rather than the exact pin.
  if ! fetch_archive \
        "https://github.com/fcitx/fcitx5/archive/refs/heads/master.tar.gz" \
        "fcitx5" "fcitx5-master"; then
    warn "fcitx5 archive unavailable, trying the pinned commit"
    git_clone_at https://github.com/fcitx/fcitx5.git fcitx5 \
      1e00551899f9d0fa5418d899f468b6e421401adf || return 1
  fi
  if [ ! -f "${TP_DIR}/fcitx5/CMakeLists.txt" ]; then
    err "fcitx5 sources incomplete at ${TP_DIR}/fcitx5"
    return 1
  fi
  return 0
}

ALL_COMPONENTS=(
  glog leveldb yaml-cpp marisa-trie opencc
  x11-headers boost regex
  ecm libuv libintl-lite lua librime-lua librime-octagram
  fcitx5 fcitx5-lua fcitx5-rime
)

is_requested() {
  [ -z "${ONLY}" ] && return 0
  case ",${ONLY}," in *,${1},*) return 0 ;; esac
  return 1
}

fetch_component() {
  case "$1" in
    glog)         git_clone https://github.com/google/glog.git        glog        v0.7.1 ;;
    leveldb)      git_clone https://github.com/google/leveldb.git     leveldb     1.23 ;;
    yaml-cpp)     git_clone https://github.com/jbeder/yaml-cpp.git    yaml-cpp    0.8.0 ;;
    marisa-trie)  git_clone https://github.com/s-yata/marisa-trie.git marisa-trie v0.2.6 ;;
    opencc)       git_clone https://github.com/BYVoid/OpenCC.git      opencc      ver.1.1.9 ;;
    x11-headers)  fetch_x11_headers ;;
    boost)        fetch_boost ;;
    regex)        fetch_boost_regex ;;
    ecm)          git_clone https://github.com/KDE/extra-cmake-modules.git ecm           v6.10.0 ;;
    libuv)        git_clone https://github.com/libuv/libuv.git              libuv         v1.48.0 ;;
    libintl-lite) git_clone https://github.com/j-jorge/libintl-lite.git     libintl-lite  master ;;
    lua)          git_clone https://github.com/lua/lua.git                  lua           v5.4.7 ;;
    # librime's Lua scripting plugin lives in its own repository; librime only
    # auto-discovers it as a subdirectory of plugins/.
    librime-lua)  git_clone https://github.com/hchunhui/librime-lua.git      librime-lua   master ;;
    # Provides the `grammar` component that reads .gram language models, which
    # schemas enable through their grammar/language setting.
    librime-octagram) git_clone https://github.com/lotem/librime-octagram.git librime-octagram master ;;
    fcitx5)       fetch_fcitx5 ;;
    fcitx5-lua)   git_clone_at https://github.com/fcitx/fcitx5-lua.git   fcitx5-lua  9bf8d3dd2c6240d8e3e194d09547acbfa6a81204 ;;
    fcitx5-rime)  git_clone_at https://github.com/fcitx/fcitx5-rime.git  fcitx5-rime 00be19a18ea5b5d1748f9fe6f6bad50f42f96781 ;;
    *) err "unknown component: $1"; return 1 ;;
  esac
}

for component in "${ALL_COMPONENTS[@]}"; do
  is_requested "${component}" || continue
  if ! fetch_component "${component}"; then
    err "${component}: fetch failed"
    FAILED+=("${component}")
  fi
done

# The fetched trees are build inputs, not working copies.  A .git inside each
# one makes an IDE report the dependency's directory as a repository root, which
# is confusing when the project itself is a repository; it would also make git
# treat them as embedded repositories if those paths were ever tracked.  The
# metadata is dropped once fetching is done.
#
# This is safe for the incremental path: already_fetched() counts real entries
# while explicitly ignoring .git, so a re-run still reports these as present.
stripped=0
while IFS= read -r nested_git; do
  rm -rf "${nested_git}"
  stripped=$((stripped + 1))
done < <(find "${TP_DIR}" "${CPP_DIR}/librime" -maxdepth 3 -name .git -type d 2>/dev/null)
if [ "${stripped}" -gt 0 ]; then
  log "stripped ${stripped} nested .git directories from the fetched sources"
fi

log "sources under ${TP_DIR}"
ls -1 "${TP_DIR}" | grep -v '^\.'

if [ "${#FAILED[@]}" -gt 0 ]; then
  err "failed components: ${FAILED[*]}"
  exit 1
fi
