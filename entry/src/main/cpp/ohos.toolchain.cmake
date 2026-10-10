# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
# ---------------------------------------------------------------------------
# OHOS (HarmonyOS NEXT) cross-compilation toolchain for the Fcitx5 / Rime port
# ---------------------------------------------------------------------------
#
# This file deliberately delegates the low-level work to the toolchain shipped
# inside the OHOS native SDK (`<sdk>/build/cmake/ohos.toolchain.cmake`), which
# knows the right compiler target, sysroot, linker flags and STL configuration
# for HarmonyOS.  Everything added here is specific to this project:
#
#   * locating the SDK when the caller did not supply it,
#   * feeding the prefix where our own third-party static libraries are
#     installed into CMake's find_* search path,
#   * relaxing a few vendor defaults that the old third-party trees and
#     -Werror builds trip over.
#
# Usage:
#   cmake -DCMAKE_TOOLCHAIN_FILE=<this file> \
#         -DOHOS_ARCH=arm64-v8a \
#         -DOHOS_DEPS_ROOT=<prefix> ...
#
# Recognised inputs (all optional):
#   OHOS_SDK_NATIVE   path to <sdk>/default/openharmony/native
#   OHOS_ARCH         arm64-v8a (default) | armeabi-v7a | x86_64
#   OHOS_STL          c++_shared (default) | c++_static | none
#   OHOS_DEPS_ROOT    install prefix of our third-party static libs
# ---------------------------------------------------------------------------

cmake_minimum_required(VERSION 3.16)

# ---------------------------------------------------------------------------
# Locate the OHOS native SDK
# ---------------------------------------------------------------------------
if(NOT OHOS_SDK_NATIVE)
  set(_ohos_sdk_candidates
      "$ENV{OHOS_SDK_NATIVE}"
      "$ENV{OHOS_NDK_HOME}"
      "$ENV{DEVECO_SDK_HOME}/default/openharmony/native"
      "$ENV{HOS_SDK_HOME}/default/openharmony/native"
      "/opt/devecostudio/sdk/default/openharmony/native"
      "$ENV{HOME}/Huawei/Sdk/default/openharmony/native"
      "$ENV{LOCALAPPDATA}/Huawei/Sdk/default/openharmony/native"
  )
  foreach(_cand IN LISTS _ohos_sdk_candidates)
    if(_cand AND EXISTS "${_cand}/build/cmake/ohos.toolchain.cmake")
      set(OHOS_SDK_NATIVE "${_cand}")
      break()
    endif()
  endforeach()
endif()

if(NOT OHOS_SDK_NATIVE OR NOT EXISTS "${OHOS_SDK_NATIVE}/build/cmake/ohos.toolchain.cmake")
  message(FATAL_ERROR
    "OHOS native SDK not found.  Pass -DOHOS_SDK_NATIVE=/path/to/sdk/default/openharmony/native "
    "or set the OHOS_SDK_NATIVE environment variable.")
endif()
get_filename_component(OHOS_SDK_NATIVE "${OHOS_SDK_NATIVE}" ABSOLUTE)
set(OHOS_SDK_NATIVE "${OHOS_SDK_NATIVE}" CACHE PATH "OHOS native SDK root" FORCE)

# ---------------------------------------------------------------------------
# Target configuration consumed by the SDK toolchain
# ---------------------------------------------------------------------------
if(NOT OHOS_ARCH)
  set(OHOS_ARCH "arm64-v8a")
endif()
set(OHOS_ARCH "${OHOS_ARCH}" CACHE STRING "OHOS target ABI" FORCE)

if(NOT OHOS_STL)
  set(OHOS_STL "c++_shared")
endif()
set(OHOS_STL "${OHOS_STL}" CACHE STRING "OHOS C++ runtime" FORCE)

# Third-party code is not always warning-clean; keep the SDK's hardening but
# stop format-string warnings from turning into hard build failures.
set(OHOS_DISABLE_FORMAT_STRING_CHECKS ON CACHE BOOL "" FORCE)

# Our final shared objects intentionally resolve some symbols (napi, hilog,
# libc++ etc.) from the application process at load time.
if(NOT DEFINED OHOS_ALLOW_UNDEFINED_SYMBOLS)
  set(OHOS_ALLOW_UNDEFINED_SYMBOLS ON CACHE BOOL "" FORCE)
endif()

# Some of the bundled third-party projects predate CMake 3.5 and would
# otherwise be rejected by modern CMake policy checks.
if(NOT DEFINED CMAKE_POLICY_VERSION_MINIMUM)
  set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)
endif()

# ---------------------------------------------------------------------------
# Hand over to the vendor toolchain
# ---------------------------------------------------------------------------
include("${OHOS_SDK_NATIVE}/build/cmake/ohos.toolchain.cmake")

# The vendor toolchain points clang at the SDK's LLVM root through
# --gcc-toolchain.  The OHOS SDK contains no GCC, so clang reports the flag as
# unused; dependencies that compile with -Werror then fail outright.  The target
# triple already lets clang locate its own runtimes, so drop the flag.
set(CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN "")
set(CMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN "")
set(CMAKE_ASM_COMPILER_EXTERNAL_TOOLCHAIN "")
unset(CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN CACHE)
unset(CMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN CACHE)
unset(CMAKE_ASM_COMPILER_EXTERNAL_TOOLCHAIN CACHE)

# ---------------------------------------------------------------------------
# Project-specific additions
# ---------------------------------------------------------------------------

# Install prefix for the third-party static libraries this project builds.
if(NOT OHOS_DEPS_ROOT)
  get_filename_component(_ohos_cpp_dir "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
  set(OHOS_DEPS_ROOT "${_ohos_cpp_dir}/thirdparty/install/${OHOS_ARCH}")
endif()
get_filename_component(OHOS_DEPS_ROOT "${OHOS_DEPS_ROOT}" ABSOLUTE)
set(OHOS_DEPS_ROOT "${OHOS_DEPS_ROOT}" CACHE PATH "OHOS third-party install prefix" FORCE)

# The vendor toolchain restricts find_path()/find_library() to CMAKE_FIND_ROOT_PATH
# (mode ONLY), so our prefix has to be registered there or nothing we build is
# ever discovered by librime's Find*.cmake modules.
list(APPEND CMAKE_FIND_ROOT_PATH "${OHOS_DEPS_ROOT}")
list(APPEND CMAKE_PREFIX_PATH    "${OHOS_DEPS_ROOT}")
list(APPEND CMAKE_INCLUDE_PATH   "${OHOS_DEPS_ROOT}/include")
list(APPEND CMAKE_LIBRARY_PATH   "${OHOS_DEPS_ROOT}/lib")

# Boost is consumed through librime's own FindBoost usage; point it at the
# header tree and at the single compiled component we build (regex).
if(EXISTS "${OHOS_DEPS_ROOT}/include/boost/version.hpp")
  set(BOOST_ROOT        "${OHOS_DEPS_ROOT}"        CACHE PATH "" FORCE)
  set(BOOST_INCLUDEDIR  "${OHOS_DEPS_ROOT}/include" CACHE PATH "" FORCE)
  set(BOOST_LIBRARYDIR  "${OHOS_DEPS_ROOT}/lib"     CACHE PATH "" FORCE)
  set(Boost_NO_SYSTEM_PATHS ON CACHE BOOL "" FORCE)
endif()

# NOTE: CMAKE_TRY_COMPILE_TARGET_TYPE is deliberately left at its default.
# Forcing it to STATIC_LIBRARY would make try_compile() skip linking, which
# silently breaks every negative feature probe (check_library_exists,
# check_symbol_exists, ...) and makes dependencies enable code paths whose
# headers are absent.  Cross-*linking* works fine against the OHOS sysroot;
# only cross-*running* would fail, and nothing here does that.

# Helpful for downstream projects that switch on the platform name.
set(OHOS TRUE)
