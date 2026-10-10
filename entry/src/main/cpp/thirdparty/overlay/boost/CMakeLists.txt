# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
# Overlay CMake build for the single compiled Boost component this project
# needs: Boost.Regex.
#
# librime uses boost::regex in its algebra/encoder/calculus code.  Everything
# else it takes from Boost (algorithm, interprocess, signals2, unordered_*,
# scope_exit, uuid, vmd, ...) is header-only.  Building Boost through b2 for an
# OHOS target is fragile, so this target compiles the handful of Boost.Regex
# translation units directly and installs the Boost header tree alongside.
#
# Two inputs, both settable by the caller so the same target works whether the
# caller has a full Boost source archive or only a header tree plus the regex
# sources extracted from the boostorg/regex repository:
#
#   BOOST_INCLUDE_DIR    directory containing boost/version.hpp
#   BOOST_REGEX_SRC_DIR  directory containing the Boost.Regex *.cpp sources
#
# If both are left empty, BOOST_SOURCE_DIR is used for both (the layout of the
# official Boost source archive).

cmake_minimum_required(VERSION 3.16)
project(boost-regex CXX)

set(BOOST_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../boost"
    CACHE PATH "Boost source archive root")

if(NOT BOOST_INCLUDE_DIR)
  set(BOOST_INCLUDE_DIR "${BOOST_SOURCE_DIR}")
endif()
if(NOT BOOST_REGEX_SRC_DIR)
  set(BOOST_REGEX_SRC_DIR "${BOOST_SOURCE_DIR}/libs/regex/src")
endif()

if(NOT EXISTS "${BOOST_INCLUDE_DIR}/boost/version.hpp")
  message(FATAL_ERROR
    "Boost headers not found: ${BOOST_INCLUDE_DIR}/boost/version.hpp")
endif()
if(NOT IS_DIRECTORY "${BOOST_REGEX_SRC_DIR}")
  message(FATAL_ERROR
    "Boost.Regex sources not found: ${BOOST_REGEX_SRC_DIR}")
endif()

file(GLOB BOOST_REGEX_SOURCES "${BOOST_REGEX_SRC_DIR}/*.cpp")
if(NOT BOOST_REGEX_SOURCES)
  message(FATAL_ERROR "no Boost.Regex sources under ${BOOST_REGEX_SRC_DIR}")
endif()

# Platform-specific translation units that must not be compiled for OHOS.
set(_boost_regex_exclude
    w32_regex_traits.cpp   # Win32 character traits
    winstances.cpp         # Win32 wide-char instantiation unit
    icu.cpp)               # only used with BOOST_HAS_ICU

foreach(_src IN LISTS BOOST_REGEX_SOURCES)
  get_filename_component(_name "${_src}" NAME)
  if(_name IN_LIST _boost_regex_exclude)
    list(REMOVE_ITEM BOOST_REGEX_SOURCES "${_src}")
  endif()
endforeach()

list(LENGTH BOOST_REGEX_SOURCES _n)
message(STATUS "Boost.Regex: ${_n} sources from ${BOOST_REGEX_SRC_DIR}")
message(STATUS "Boost headers: ${BOOST_INCLUDE_DIR}")

add_library(boost_regex STATIC ${BOOST_REGEX_SOURCES})
add_library(Boost::regex ALIAS boost_regex)

target_include_directories(boost_regex PUBLIC "${BOOST_INCLUDE_DIR}")
target_compile_features(boost_regex PUBLIC cxx_std_11)

target_compile_definitions(boost_regex
  PRIVATE BOOST_REGEX_SOURCE   # required when compiling the library itself
  PUBLIC  BOOST_ALL_NO_LIB     # suppress auto-linking pragmas
          BOOST_REGEX_STATIC_LINK)

set_target_properties(boost_regex PROPERTIES
  OUTPUT_NAME boost_regex
  POSITION_INDEPENDENT_CODE ON)

target_compile_options(boost_regex PRIVATE
  -Wno-unused-parameter -Wno-deprecated-declarations -Wno-sign-compare
  -Wno-unused-variable -Wno-unused-but-set-variable)

include(GNUInstallDirs)

install(TARGETS boost_regex ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")

# Boost is header-only apart from the library above, so install the whole tree.
install(DIRECTORY "${BOOST_INCLUDE_DIR}/boost"
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
  PATTERN "*.hpp" PATTERN "*.h" PATTERN "*.ipp" PATTERN "*.inc")
