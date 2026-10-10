# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
# Native build for the HarmonyOS input-method module.
#
# This builds exactly one artifact -- libentry.so, the NAPI bridge -- and links
# it against the engine libraries that the scripts/ pipeline has already
# cross-compiled into thirdparty/install/<arch>:
#
#   librime, boost_regex, glog, leveldb, marisa, opencc, yaml-cpp, lua
#
# Keeping the engine out of this CMake project means hvigor only ever rebuilds
# the small bridge, while the expensive engine build is a separate, cacheable
# step (scripts/build_engine.sh).
#
# Build the engine first:
#   scripts/fetch_sources.sh
#   scripts/build_thirdparty.sh
#   scripts/build_engine.sh

cmake_minimum_required(VERSION 3.16)

project(fcitx5_ohos_ime CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------------------------------------------------------------------------
# Locate the engine libraries
# ---------------------------------------------------------------------------

# hvigor supplies OHOS_ARCH for the official OHOS toolchain; derive it when this
# file is configured standalone.
if(NOT OHOS_ARCH)
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(OHOS_ARCH "arm64-v8a")
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "armv7|arm")
    set(OHOS_ARCH "armeabi-v7a")
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64")
    set(OHOS_ARCH "x86_64")
  else()
    set(OHOS_ARCH "arm64-v8a")
  endif()
endif()

if(NOT OHOS_DEPS_ROOT)
  set(OHOS_DEPS_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/install/${OHOS_ARCH}")
endif()

set(_ime_required_libs
    librime.a
    libboost_regex.a
    libglog.a
    libleveldb.a
    libmarisa.a
    libopencc.a
    libyaml-cpp.a
    liblua.a)

foreach(_lib IN LISTS _ime_required_libs)
  if(NOT EXISTS "${OHOS_DEPS_ROOT}/lib/${_lib}")
    message(FATAL_ERROR
      "Missing engine library: ${OHOS_DEPS_ROOT}/lib/${_lib}\n"
      "Build the engine first:\n"
      "  scripts/fetch_sources.sh\n"
      "  scripts/build_thirdparty.sh\n"
      "  scripts/build_engine.sh")
  endif()
endforeach()

message(STATUS "IME engine prefix: ${OHOS_DEPS_ROOT} (${OHOS_ARCH})")

# ---------------------------------------------------------------------------
# NAPI bridge
# ---------------------------------------------------------------------------

add_library(entry SHARED
  rime_napi/napi_init.cpp
  rime_napi/rime_engine.cpp)

target_include_directories(entry PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/rime_napi"
  "${OHOS_DEPS_ROOT}/include")

# librime registers its modules from static initialisers scattered across the
# archive.  Without --whole-archive the linker discards those objects, the
# constructors never run, and initialize() finds no modules.
#
# The static libraries reference one another (librime.a needs symbols from
# opencc, marisa, leveldb, yaml-cpp, glog, boost_regex and lua, and opencc needs
# marisa), so they are wrapped in a linker group instead of relying on a
# hand-sorted link order.
target_link_options(entry PRIVATE
  "-Wl,--start-group"
  "-Wl,--whole-archive"
  "${OHOS_DEPS_ROOT}/lib/librime.a"
  "-Wl,--no-whole-archive"
  "${OHOS_DEPS_ROOT}/lib/libboost_regex.a"
  "${OHOS_DEPS_ROOT}/lib/libglog.a"
  "${OHOS_DEPS_ROOT}/lib/libleveldb.a"
  "${OHOS_DEPS_ROOT}/lib/libmarisa.a"
  "${OHOS_DEPS_ROOT}/lib/libopencc.a"
  "${OHOS_DEPS_ROOT}/lib/libyaml-cpp.a"
  # librime's Lua plugin is merged into librime.a, so the interpreter it calls
  # into has to be linked as well.
  "${OHOS_DEPS_ROOT}/lib/liblua.a"
  "-Wl,--end-group")

# NAPI entry points and the OHOS logging facility are provided by the system.
target_link_libraries(entry PRIVATE
  libace_napi.z.so
  libhilog_ndk.z.so
  z
  dl)

# The engine is C++ and uses exceptions/RTTI.  The OHOS toolchain leaves both at
# clang's defaults; state them explicitly so the bridge cannot break if that
# ever changes.
target_compile_options(entry PRIVATE
  -fexceptions
  -frtti
  -Wno-deprecated-declarations
  # Pulling in librime's private headers (rime/registry.h -> rime/common.h, for
  # reporting which plugins registered their components) also pulls in
  # <glog/logging.h>, and glog 0.7 refuses to compile unless the consumer opts
  # into its export header.
  -DGLOG_USE_GLOG_EXPORT)

set_target_properties(entry PROPERTIES
  OUTPUT_NAME entry
  PREFIX "lib"
  POSITION_INDEPENDENT_CODE ON)
