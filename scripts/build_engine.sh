#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
#
#
# Cross-compile the input-method engine itself for OHOS:
#
#   librime      -- the Rime engine (schema/dictionary processing)
#   fcitx5       -- the fcitx5 core framework
#   fcitx5-lua   -- fcitx5's Lua scripting addon
#   fcitx5-rime  -- fcitx5's Rime input-method addon
#
# Everything lands in the same prefix as the third-party dependencies, but only
# librime is linked into the app; the fcitx5 libraries contribute no symbols.
#
# Usage:
#   scripts/build_engine.sh                          # all components
#   scripts/build_engine.sh --only librime           # one (or a comma list)
#   scripts/build_engine.sh --clean
#
# Run scripts/build_thirdparty.sh first.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CPP_DIR="${CPP_DIR_OVERRIDE:-${PROJECT_ROOT}/entry/src/main/cpp}"
TP_DIR="${CPP_DIR}/thirdparty"

ARCH="${OHOS_ARCH:-arm64-v8a}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
JOBS="${JOBS:-$(nproc)}"
PREFIX="${TP_DIR}/install/${ARCH}"
BUILD_ROOT="${TP_DIR}/build/${ARCH}"
TOOLCHAIN="${CPP_DIR}/ohos.toolchain.cmake"
LIBRIME_DIR="${LIBRIME_DIR:-${CPP_DIR}/librime}"

ONLY=""
CLEAN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --only)  ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==> [engine]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "${TOOLCHAIN}" ] || die "toolchain file missing: ${TOOLCHAIN}"
[ -d "${PREFIX}/include" ] || die "third-party prefix not populated; run scripts/build_thirdparty.sh"

mkdir -p "${BUILD_ROOT}"

# fcitx5 5.1.23 is C++20 but the HarmonyOS NDK ships libc++ 15, which has
# <format> and <span> yet no <source_location> at all -- and fcitx-utils/log.h
# includes it unconditionally.  Three flags work around that:
#
#   -isystem <shim>        supplies a std::source_location built on
#                          __builtin_FILE()/__builtin_LINE()
#   -fexperimental-library unlocks <format> and std::ranges, which libc++ 15
#                          gates behind the flag
#   -include <compat.h>    supplies std::hash<std::filesystem::path>, which
#                          libc++ only gained after 15
#
# These are needed by the three fcitx5 packages (core, lua, rime), not by
# librime, so they are passed explicitly per component rather than baked into
# the toolchain (which would invalidate every already-built dependency).
CXX_COMPAT_INCLUDE="${CPP_DIR}/thirdparty/overlay/cxx-compat/include"
CXX_COMPAT_FLAGS="-fexperimental-library -isystem ${CXX_COMPAT_INCLUDE} -include ${CXX_COMPAT_INCLUDE}/fcitx5_ohos_cxx_compat.h"

# -fexperimental-library unlocks <format> but does not pull in its out-of-line
# implementation; std::format_error's vtable lives in libc++experimental, so it
# has to be named on the link line or the modules fail with undefined symbols.
# The OHOS toolchain merges these with its own linker flags.
CXX_COMPAT_LINK_FLAGS="-lc++experimental"

# fcitx5 addons configure against fcitx5's installed CMake package, whose exported
# targets reference imported targets it never resolves.  This prelude defines
# them; see the file for the full explanation.
FCITX5_ADDON_PRELUDE="${CPP_DIR}/thirdparty/overlay/fcitx5-addon-prelude.cmake"

# Cross-compilation hazard: fcitx5 locates libuv (and lua) through pkg-config.
# Left alone, pkg-config would happily return the *host's* .pc files and we would
# link x86-64 libraries into an aarch64 build.  Restrict it to the target prefix.
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"
export PKG_CONFIG_PATH=""

if [ -n "${CLEAN}" ]; then
  log "cleaning engine build trees"
  rm -rf "${BUILD_ROOT}/librime" "${BUILD_ROOT}/fcitx5" "${BUILD_ROOT}/fcitx5-lua" "${BUILD_ROOT}/fcitx5-rime"
fi

# Common configure arguments.
#
# CMAKE_POLICY_VERSION_MINIMUM: same compatibility floor as in
# build_thirdparty.sh, where some CMakeLists still predate CMake 3.5 (CMake 4
# rejects them outright).  Every engine project requires >= 3.6, so here it is
# only kept in step.
CMAKE_COMMON=(
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}"
  -DOHOS_ARCH="${ARCH}"
  -DOHOS_DEPS_ROOT="${PREFIX}"
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
  -DCMAKE_INSTALL_PREFIX="${PREFIX}"
  -DCMAKE_PREFIX_PATH="${PREFIX}"
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

# apply_patches <component> <source-dir>
#
# Applies the patches under scripts/patches/<component>/ to a fetched source
# tree.  They are applied in place, but idempotently: each patch is dry-run in
# reverse first, so an already-patched tree is skipped and re-running the build
# never fails with "patch does not apply".
apply_patches() {
  local component="$1" source_dir="$2"
  local patch_dir="${SCRIPT_DIR}/patches/${component}"
  [ -d "${patch_dir}" ] || return 0
  [ -d "${source_dir}" ] || return 0

  local patch_file
  for patch_file in "${patch_dir}"/*.patch; do
    [ -e "${patch_file}" ] || continue
    if patch -d "${source_dir}" -p1 -R --dry-run --silent -f < "${patch_file}" > /dev/null 2>&1; then
      log "${component}: already patched ($(basename "${patch_file}"))"
      continue
    fi
    log "${component}: applying $(basename "${patch_file}")"
    if ! patch -d "${source_dir}" -p1 --forward --silent < "${patch_file}"; then
      die "${component}: failed to apply $(basename "${patch_file}")"
    fi
  done
}

# run_component <name> <source-dir> [extra cmake args...]
run_component() {
  local name="$1" src="$2"; shift 2
  local build_dir="${BUILD_ROOT}/${name}"

  [ -d "${src}" ] || die "${name}: source directory not found (${src}); run scripts/fetch_sources.sh"

  log "configuring ${name}"
  cmake -S "${src}" -B "${build_dir}" "${CMAKE_COMMON[@]}" "$@" \
    > "${build_dir}.configure.log" 2>&1 || {
      tail -50 "${build_dir}.configure.log" >&2
      die "${name}: configure failed (full log: ${build_dir}.configure.log)"
    }

  log "building ${name}"
  cmake --build "${build_dir}" -j"${JOBS}" > "${build_dir}.build.log" 2>&1 || {
      tail -80 "${build_dir}.build.log" >&2
      die "${name}: build failed (full log: ${build_dir}.build.log)"
    }

  log "installing ${name}"
  cmake --install "${build_dir}" > "${build_dir}.install.log" 2>&1 || {
      tail -50 "${build_dir}.install.log" >&2
      die "${name}: install failed (full log: ${build_dir}.install.log)"
    }
  log "${name} done"
}

# ---------------------------------------------------------------------------
# librime
# ---------------------------------------------------------------------------
build_librime() {
  # librime discovers plugins by globbing the subdirectories of plugins/, and the
  # Lua scripting plugin lives in its own repository.  Copy it in so schemas that
  # use lua_translator / lua_filter / lua_processor actually work -- rime-ice and
  # most large configuration sets depend on them.
  if [ -d "${TP_DIR}/librime-lua" ]; then
    apply_patches librime-lua "${TP_DIR}/librime-lua"
    rm -rf "${LIBRIME_DIR:?}/plugins/lua"
    cp -r "${TP_DIR}/librime-lua" "${LIBRIME_DIR}/plugins/lua"
    rm -rf "${LIBRIME_DIR}/plugins/lua/.git"
    log "librime: bundling lua plugin from thirdparty/librime-lua"
  else
    warn "thirdparty/librime-lua missing; schemas using Lua will not work"
  fi

  # Same mechanism for the grammar plugin: it supplies the `grammar` component
  # that loads <language>.gram, which rime-ice and friends enable via their
  # grammar/language setting.  librime ships only the abstract interface.
  if [ -d "${TP_DIR}/librime-octagram" ]; then
    rm -rf "${LIBRIME_DIR:?}/plugins/octagram"
    cp -r "${TP_DIR}/librime-octagram" "${LIBRIME_DIR}/plugins/octagram"
    rm -rf "${LIBRIME_DIR}/plugins/octagram/.git"
    log "librime: bundling octagram grammar plugin from thirdparty/librime-octagram"
  else
    warn "thirdparty/librime-octagram missing; .gram language models will be ignored"
  fi

  # librime lives beside the module's other native sources rather than under
  # thirdparty/, because it is a first-class part of this project.
  #
  # INSTALL_PRIVATE_HEADERS is on because the NAPI bridge links librime
  # statically and needs <rime/registry.h> to report which plugins registered
  # their components; librime documents the option for consuming the library
  # from outside its own tree.
  #
  # BUILD_MERGED_PLUGINS (librime's default) folds the plugin object files into
  # the single librime archive, which is what the app links.
  #
  # BUILD_TOOLS is read by the octagram plugin, not by librime core: it enables
  # the `build_grammar` authoring tool, which a device build does not need.
  run_component librime "${LIBRIME_DIR}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC=ON \
    -DBUILD_TEST=OFF \
    -DBUILD_SAMPLE=OFF \
    -DBUILD_DATA=OFF \
    -DBUILD_SEPARATE_LIBS=OFF \
    -DBUILD_MERGED_PLUGINS=ON \
    -DENABLE_LOGGING=ON \
    -DENABLE_THREADING=ON \
    -DENABLE_EXTERNAL_PLUGINS=OFF \
    -DENABLE_TIMESTAMP=OFF \
    -DBUILD_TOOLS=OFF \
    -DINSTALL_PRIVATE_HEADERS=ON \
    -DGlog_STATIC=ON \
    -DYamlCpp_STATIC=ON \
    -DLevelDb_STATIC=ON \
    -DMarisa_STATIC=ON \
    -DOpencc_STATIC=ON
}

# ---------------------------------------------------------------------------
# fcitx5 core
#
# The option set mirrors what fcitx5-android disables: everything that would
# pull in a desktop session (X11, Wayland, DBus, systemd, the XDG autostart
# integration, the fcitx5 server, the XKB keyboard engine, spell checking and
# the emoji addon) is off, along with the packaging extras (libuuid, flatpak
# icon), because the engine is driven directly by our own NAPI layer rather than
# by an fcitx5 frontend.  ENABLE_SERVER=OFF is what lets fcitx5 be consumed as
# an embedded library.
#
# ENABLE_DL stays ON even though nothing here dlopen()s addons: fcitx5 only
# installs <fcitx-utils/library.h> when it is enabled, and fcitx5-rime includes
# that header unconditionally.  musl provides dlopen() from libc and the sysroot
# ships a stub libdl.a, so the cost is nil.
# ---------------------------------------------------------------------------
build_fcitx5() {
  apply_patches fcitx5 "${TP_DIR}/fcitx5"
  run_component fcitx5 "${TP_DIR}/fcitx5" \
    -DCMAKE_CXX_FLAGS="${CXX_COMPAT_FLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DCMAKE_MODULE_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_TESTING_ADDONS=OFF \
    -DENABLE_TEST=OFF \
    -DENABLE_COVERAGE=OFF \
    -DENABLE_ENCHANT=OFF \
    -DENABLE_X11=OFF \
    -DENABLE_WAYLAND=OFF \
    -DENABLE_DBUS=OFF \
    -DENABLE_DOC=OFF \
    -DENABLE_SERVER=OFF \
    -DENABLE_KEYBOARD=OFF \
    -DUSE_SYSTEMD=OFF \
    -DENABLE_XDGAUTOSTART=OFF \
    -DENABLE_EMOJI=OFF \
    -DENABLE_LIBUUID=OFF \
    -DBUILD_SPELL_DICT=OFF \
    -DUSE_FLATPAK_ICON=OFF \
    -DENABLE_DL=ON \
    -DEVENT_LOOP_BACKEND=libuv
}

# ---------------------------------------------------------------------------
# fcitx5-lua
#
# USE_DLOPEN=OFF links the Lua interpreter we built instead of looking for a
# liblua.so at runtime, which is what an embedded build wants.  (fcitx5 core
# keeps ENABLE_DL=ON for an unrelated reason: see build_fcitx5 above.)
# ---------------------------------------------------------------------------
build_fcitx5_lua() {
  apply_patches fcitx5-lua "${TP_DIR}/fcitx5-lua"
  run_component fcitx5-lua "${TP_DIR}/fcitx5-lua" \
    -DCMAKE_PROJECT_INCLUDE="${FCITX5_ADDON_PRELUDE}" \
    -DCMAKE_CXX_FLAGS="${CXX_COMPAT_FLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DCMAKE_MODULE_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DUSE_DLOPEN=OFF \
    -DENABLE_TEST=OFF \
    -DBUILD_SHARED_LIBS=OFF
}

# ---------------------------------------------------------------------------
# fcitx5-rime (the addon that binds librime into fcitx5)
#
# RIME_TARGET short-circuits the pkg-config lookup for librime (our install
# ships a CMake package, not a .pc file); the Rime::Rime target itself is set up
# by the prelude.  RIME_DATA_DIR is both compiled in as the default schema
# location and used as the install destination for the addon's bundled schemas,
# so it has to be a path that is writable at build time.  The app does not rely
# on that default: its ArkTS layer extracts rawfile/rime and hands librime the
# resulting directory through the NAPI configure() call.
# ---------------------------------------------------------------------------
build_fcitx5_rime() {
  apply_patches fcitx5-rime "${TP_DIR}/fcitx5-rime"
  run_component fcitx5-rime "${TP_DIR}/fcitx5-rime" \
    -DCMAKE_PROJECT_INCLUDE="${FCITX5_ADDON_PRELUDE}" \
    -DCMAKE_CXX_FLAGS="${CXX_COMPAT_FLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DCMAKE_MODULE_LINKER_FLAGS="${CXX_COMPAT_LINK_FLAGS}" \
    -DFCITX5_OHOS_RIME_LIBRARY="${PREFIX}/lib/librime.a" \
    -DFCITX5_OHOS_RIME_INCLUDE_DIR="${PREFIX}/include" \
    -DFCITX5_OHOS_RIME_DEP_DIR="${PREFIX}/lib" \
    -DRIME_TARGET="Rime::Rime" \
    -DRIME_DATA_DIR="${FCITX_RIME_DATA_DIR:-${PREFIX}/share/rime-data}" \
    -DENABLE_TEST=OFF \
    -DBUILD_SHARED_LIBS=OFF
}

# ---------------------------------------------------------------------------
ALL_COMPONENTS=(librime fcitx5 fcitx5-lua fcitx5-rime)

is_requested() {
  [ -z "${ONLY}" ] && return 0
  case ",${ONLY}," in *,${1},*) return 0 ;; esac
  return 1
}

log "prefix:      ${PREFIX}"
log "build trees: ${BUILD_ROOT}"
log "jobs:        ${JOBS}"

for component in "${ALL_COMPONENTS[@]}"; do
  is_requested "${component}" || continue
  case "${component}" in
    librime)     build_librime ;;
    fcitx5)      build_fcitx5 ;;
    fcitx5-lua)  build_fcitx5_lua ;;
    fcitx5-rime) build_fcitx5_rime ;;
  esac
done

log "engine installed into ${PREFIX}"
ls -1 "${PREFIX}/lib" 2>/dev/null || true
