#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
#
#
# Cross-compile every third-party dependency of the Fcitx5/Rime port for OHOS.
#
# Dependencies install into a single prefix
# (entry/src/main/cpp/thirdparty/install/<arch>) that the module's CMake build
# picks up through ohos.toolchain.cmake: static archives, headers and .pc files.
#
# Usage:
#   scripts/build_thirdparty.sh                 # build everything
#   scripts/build_thirdparty.sh --only glog     # build one (or a comma list)
#   scripts/build_thirdparty.sh --clean         # wipe build trees first
#   OHOS_ARCH=arm64-v8a JOBS=8 scripts/build_thirdparty.sh
#
# Run scripts/fetch_sources.sh first to populate the source trees.

set -euo pipefail

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

ONLY=""
CLEAN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --only)  ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --clean) CLEAN=1; shift ;;
    --arch)  ARCH="$2"; PREFIX="${TP_DIR}/install/${ARCH}"; BUILD_ROOT="${TP_DIR}/build/${ARCH}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==> [%s]\033[0m %s\n' "${ARCH}" "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "${TOOLCHAIN}" ] || die "toolchain file missing: ${TOOLCHAIN}"

mkdir -p "${PREFIX}" "${BUILD_ROOT}"
if [ -n "${CLEAN}" ]; then
  log "cleaning ${BUILD_ROOT}"
  rm -rf "${BUILD_ROOT}"
  mkdir -p "${BUILD_ROOT}"
fi

# Common configure arguments.
#
# CMAKE_POLICY_VERSION_MINIMUM: yaml-cpp 0.8.0 declares
# cmake_minimum_required(VERSION 3.4), which CMake 4 rejects outright, so the
# compatibility floor has to be raised.  ohos.toolchain.cmake sets the same
# default; keeping it here keeps the dependency and engine builds identical.
CMAKE_COMMON=(
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}"
  -DOHOS_ARCH="${ARCH}"
  -DOHOS_DEPS_ROOT="${PREFIX}"
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
  -DCMAKE_INSTALL_PREFIX="${PREFIX}"
  -DCMAKE_PREFIX_PATH="${PREFIX}"
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

# run_dep <name> <source-dir> [extra cmake args...]
run_dep() {
  local name="$1" src="$2"; shift 2
  local build_dir="${BUILD_ROOT}/${name}"

  [ -d "${src}" ] || die "${name}: source directory not found (${src}); run scripts/fetch_sources.sh"

  log "configuring ${name}"
  cmake -S "${src}" -B "${build_dir}" "${CMAKE_COMMON[@]}" "$@" \
    > "${build_dir}.configure.log" 2>&1 || {
      tail -40 "${build_dir}.configure.log" >&2
      die "${name}: configure failed (full log: ${build_dir}.configure.log)"
    }

  log "building ${name}"
  cmake --build "${build_dir}" -j"${JOBS}" > "${build_dir}.build.log" 2>&1 || {
      tail -60 "${build_dir}.build.log" >&2
      die "${name}: build failed (full log: ${build_dir}.build.log)"
    }

  log "installing ${name}"
  cmake --install "${build_dir}" > "${build_dir}.install.log" 2>&1 || {
      tail -40 "${build_dir}.install.log" >&2
      die "${name}: install failed (full log: ${build_dir}.install.log)"
    }
  log "${name} done"
}

# ---------------------------------------------------------------------------
# Individual dependencies
# ---------------------------------------------------------------------------

# Yet another YAML parser: rime schema/config handling.
build_yaml_cpp() {
  run_dep yaml-cpp "${TP_DIR}/yaml-cpp" \
    -DYAML_CPP_BUILD_TESTS=OFF \
    -DYAML_CPP_BUILD_TOOLS=OFF \
    -DYAML_CPP_BUILD_CONTRIB=OFF \
    -DYAML_CPP_INSTALL=ON \
    -DYAML_CPP_FORMAT_SOURCE=OFF \
    -DYAML_BUILD_SHARED_LIBS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF
}

# Key-value store backing rime's user dictionaries.
build_leveldb() {
  run_dep leveldb "${TP_DIR}/leveldb" \
    -DLEVELDB_BUILD_TESTS=OFF \
    -DLEVELDB_BUILD_BENCHMARKS=OFF \
    -DLEVELDB_INSTALL=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF
}

# Trie used by rime dictionaries and by OpenCC.
build_marisa() {
  run_dep marisa-trie "${TP_DIR}/overlay/marisa-trie" \
    -DMARISA_SOURCE_DIR="${TP_DIR}/marisa-trie"
}

# Logging backend for librime and fcitx5.
build_glog() {
  run_dep glog "${TP_DIR}/glog" \
    -DWITH_GFLAGS=OFF \
    -DWITH_GTEST=OFF \
    -DWITH_UNWIND=OFF \
    -DWITH_SYMBOLIZE=OFF \
    -DWITH_UCONTEXT=OFF \
    -DWITH_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_SHARED_LIBS=OFF
}

# Simplified/traditional Chinese conversion for rime's opencc filter.
#
# ENABLE_DARTS is only needed for the legacy .ocd (DartsDict) format; the
# dictionaries shipped with rime-data are .ocd2, which MarisaDict reads, so this
# flag is not load-bearing and only makes OpenCC's default explicit.
build_opencc() {
  run_dep opencc "${TP_DIR}/opencc" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_GTEST=OFF \
    -DENABLE_BENCHMARK=OFF \
    -DBUILD_PYTHON=OFF \
    -DUSE_SYSTEM_MARISA=OFF \
    -DENABLE_DARTS=ON
}

# Locate a Boost header tree on the build host.  Only used as a fallback when
# the full Boost source archive could not be downloaded.
find_system_boost() {
  local candidate
  for candidate in /usr/include /usr/local/include /opt/homebrew/include \
                   /opt/local/include; do
    if [ -f "${candidate}/boost/version.hpp" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

# Boost headers + the compiled regex component.
#
# Preferred: the full Boost source archive (reproducible, fetched by
#   scripts/fetch_sources.sh --only boost).
# Fallback:  a header tree taken from the build host plus the Boost.Regex
#   sources from the boostorg/regex repository.  This exists because the full
#   archive is ~95 MB and can be impractical to download on restricted
#   networks.  Both halves must be the same Boost release.
build_boost() {
  local include_dir="" regex_src=""

  if [ -f "${TP_DIR}/boost/boost/version.hpp" ]; then
    include_dir="${TP_DIR}/boost"
    regex_src="${TP_DIR}/boost/libs/regex/src"
  else
    include_dir="${TP_DIR}/boost-headers"
    regex_src="${TP_DIR}/regex/src"

    if [ ! -f "${include_dir}/boost/version.hpp" ]; then
      local sys_boost
      if ! sys_boost="$(find_system_boost)"; then
        die "boost: neither ${TP_DIR}/boost nor a system Boost header tree was found.
     Run 'scripts/fetch_sources.sh --only boost' to download the source archive."
      fi
      warn "boost: full source archive unavailable, vendoring headers from ${sys_boost}"
      mkdir -p "${include_dir}"
      cp -r "${sys_boost}/boost" "${include_dir}/boost"
    fi

    if [ ! -d "${regex_src}" ]; then
      die "boost: Boost.Regex sources missing at ${regex_src};
     run 'scripts/fetch_sources.sh --only regex'."
    fi
    log "boost: using header tree ${include_dir} with regex sources ${regex_src}"
  fi

  run_dep boost "${TP_DIR}/overlay/boost" \
    -DBOOST_SOURCE_DIR="${TP_DIR}/boost" \
    -DBOOST_INCLUDE_DIR="${include_dir}" \
    -DBOOST_REGEX_SRC_DIR="${regex_src}"
}

# Embeddable Lua for the fcitx5-lua addon.
build_lua() {
  run_dep lua "${TP_DIR}/overlay/lua" \
    -DLUA_SOURCE_DIR="${TP_DIR}/lua"
}

# Minimal gettext implementation: OHOS libc ships <libintl.h> but no
# implementation, and fcitx5 core needs it for translations.
build_libintl_lite() {
  local src="${TP_DIR}/libintl-lite"
  [ -d "${src}" ] || die "libintl-lite sources missing"

  if [ -f "${src}/CMakeLists.txt" ]; then
    run_dep libintl-lite "${src}" -DBUILD_SHARED_LIBS=OFF
  else
    # Fallback for a checkout with no build system: compile the sources through
    # overlay/libintl-lite.  Upstream master does ship a CMakeLists.txt, so the
    # branch above is the one normally taken.
    log "configuring libintl-lite (overlay)"
    run_dep libintl-lite "${TP_DIR}/overlay/libintl-lite" \
      -DLIBINTL_LITE_SOURCE_DIR="${src}"
  fi
}

# Event loop used by fcitx5 core: use the libuv HarmonyOS already ships.
#
# The sysroot contains libuv.so and uv.h as a public NDK library, which is
# guaranteed to match the platform's own event loop.  Building upstream libuv
# from source does not work out of the box regardless: its
# uv_available_parallelism implementation uses glibc's
# sched_getaffinity()/cpu_set_t, which musl on OHOS does not provide.
#
# fcitx5 locates libuv through pkg-config, so all that is missing is a .pc file
# describing the sysroot library.
build_libuv() {
  local sdk=""
  local candidate
  for candidate in \
      "${OHOS_SDK_NATIVE:-}" \
      "${DEVECO_SDK_HOME:-}/default/openharmony/native" \
      "/opt/devecostudio/sdk/default/openharmony/native" \
      "${HOME}/Huawei/Sdk/default/openharmony/native"; do
    if [ -n "${candidate}" ] && [ -f "${candidate}/sysroot/usr/include/uv.h" ]; then
      sdk="${candidate}"
      break
    fi
  done
  [ -n "${sdk}" ] || die "libuv: OHOS sysroot containing uv.h not found; set OHOS_SDK_NATIVE"

  local sysroot="${sdk}/sysroot"
  local version_file="${sysroot}/usr/include/uv/version.h"
  local major minor patch
  major="$(sed -n 's/^#define UV_VERSION_MAJOR //p' "${version_file}" 2>/dev/null | head -1)"
  minor="$(sed -n 's/^#define UV_VERSION_MINOR //p' "${version_file}" 2>/dev/null | head -1)"
  patch="$(sed -n 's/^#define UV_VERSION_PATCH //p' "${version_file}" 2>/dev/null | head -1)"
  local version="${major:-1}.${minor:-0}.${patch:-0}"

  log "installing libuv.pc for the system libuv ${version}"
  mkdir -p "${PREFIX}/lib/pkgconfig"
  cat > "${PREFIX}/lib/pkgconfig/libuv.pc" <<EOF
prefix=${sysroot}/usr
exec_prefix=\${prefix}
libdir=\${prefix}/lib/aarch64-linux-ohos
includedir=\${prefix}/include

Name: libuv
Description: HarmonyOS system libuv (public NDK library)
Version: ${version}
Libs: -L\${libdir} -luv
Cflags: -I\${includedir}
EOF
  log "libuv done"
}

# Extra CMake Modules, required by fcitx5's build system.
build_ecm() {
  run_dep ecm "${TP_DIR}/ecm" \
    -DBUILD_TESTING=OFF \
    -DBUILD_HTML_DOCS=OFF \
    -DBUILD_MAN_DOCS=OFF \
    -DBUILD_QTHELP_DOCS=OFF
}

# X11 keysym definitions, vendored from xorgproto.
#
# librime and fcitx5 include <X11/keysym.h> unconditionally just to get key
# symbol constants, but OHOS has no X11.  Those headers are plain #define lists
# with no architecture or library dependency, so installing them into the
# prefix is enough to satisfy the `find_path(X11Keysym X11/keysym.h)` probe.
build_x11_headers() {
  local src="${TP_DIR}/xorgproto/include/X11"
  [ -d "${src}" ] || die "xorgproto keysym headers missing; run scripts/fetch_sources.sh"
  log "installing X11 keysym headers"
  mkdir -p "${PREFIX}/include/X11"
  cp -f "${src}"/*.h "${PREFIX}/include/X11/"
  log "x11-headers done"
}

# ---------------------------------------------------------------------------
ALL_DEPS=(x11-headers marisa-trie yaml-cpp leveldb glog boost opencc libintl-lite libuv lua ecm)

is_requested() {
  [ -z "${ONLY}" ] && return 0
  case ",${ONLY}," in *,${1},*) return 0 ;; esac
  return 1
}

log "prefix:      ${PREFIX}"
log "build trees: ${BUILD_ROOT}"
log "jobs:        ${JOBS}"

for dep in "${ALL_DEPS[@]}"; do
  is_requested "${dep}" || continue
  case "${dep}" in
    x11-headers)  build_x11_headers ;;
    marisa-trie)  build_marisa ;;
    yaml-cpp)     build_yaml_cpp ;;
    leveldb)      build_leveldb ;;
    glog)         build_glog ;;
    boost)        build_boost ;;
    opencc)       build_opencc ;;
    libintl-lite) build_libintl_lite ;;
    libuv)        build_libuv ;;
    lua)          build_lua ;;
    ecm)          build_ecm ;;
  esac
done

log "third-party dependencies installed into ${PREFIX}"
ls -1 "${PREFIX}/lib" 2>/dev/null || true
