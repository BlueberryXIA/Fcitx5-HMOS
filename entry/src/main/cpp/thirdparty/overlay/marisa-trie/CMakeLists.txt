# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
# Overlay CMake build for marisa-trie 0.2.6.
#
# The upstream 0.2.6 release only ships an autotools build, which is awkward to
# cross-compile for OHOS.  The library itself is nine translation units, so this
# file provides a plain CMake target that consumes the pristine upstream sources
# without patching them.

cmake_minimum_required(VERSION 3.16)
project(marisa-trie CXX)

set(MARISA_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../marisa-trie"
    CACHE PATH "marisa-trie checkout")

if(NOT EXISTS "${MARISA_SOURCE_DIR}/include/marisa.h")
  message(FATAL_ERROR "marisa-trie sources not found at ${MARISA_SOURCE_DIR}")
endif()

set(MARISA_SOURCES
    "${MARISA_SOURCE_DIR}/lib/marisa/agent.cc"
    "${MARISA_SOURCE_DIR}/lib/marisa/keyset.cc"
    "${MARISA_SOURCE_DIR}/lib/marisa/trie.cc"
    "${MARISA_SOURCE_DIR}/lib/marisa/grimoire/io/mapper.cc"
    "${MARISA_SOURCE_DIR}/lib/marisa/grimoire/io/reader.cc"
    "${MARISA_SOURCE_DIR}/lib/marisa/grimoire/io/writer.cc"
    "${MARISA_SOURCE_DIR}/lib/marisa/grimoire/trie/louds-trie.cc"
    "${MARISA_SOURCE_DIR}/lib/marisa/grimoire/trie/tail.cc"
    "${MARISA_SOURCE_DIR}/lib/marisa/grimoire/vector/bit-vector.cc")

add_library(marisa STATIC ${MARISA_SOURCES})
add_library(marisa::marisa ALIAS marisa)

target_include_directories(marisa
  PUBLIC "${MARISA_SOURCE_DIR}/include"
  PRIVATE "${MARISA_SOURCE_DIR}/lib")

# marisa generates its public header from marisa.h.in-less sources, so make the
# upstream include tree the single source of truth.
target_compile_features(marisa PUBLIC cxx_std_11)
set_target_properties(marisa PROPERTIES
  OUTPUT_NAME marisa
  POSITION_INDEPENDENT_CODE ON)

# Silence the vendored code's own warnings rather than patching it.
target_compile_options(marisa PRIVATE
  -Wno-unused-parameter
  -Wno-unused-variable
  -Wno-unused-but-set-variable
  -Wno-sign-compare
  -Wno-deprecated-declarations)

include(GNUInstallDirs)
install(TARGETS marisa
  ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
install(DIRECTORY "${MARISA_SOURCE_DIR}/include/"
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")

# pkg-config file so downstream (OpenCC) find_package(Marisa) style probes work.
configure_file("${MARISA_SOURCE_DIR}/marisa.pc.in"
  "${CMAKE_CURRENT_BINARY_DIR}/marisa.pc" @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/marisa.pc"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig")
