# Prelude injected into fcitx5 addon builds via CMAKE_PROJECT_INCLUDE.
#
# fcitx5's installed Fcitx5UtilsConfig.cmake includes its exported targets
# without resolving the imported targets those targets reference.  When fcitx5
# itself is being built the targets already exist, but a consumer -- an addon
# such as fcitx5-lua or fcitx5-rime -- configures from scratch, and CMake then
# fails at generate time with:
#
#   The link interface of target "Fcitx5::Core" contains:
#     LibIntl::LibIntl
#   but the target was not found.
#
# CMAKE_PROJECT_INCLUDE runs immediately after the addon's project() call, which
# is before its find_package(Fcitx5Core), so defining the missing targets here
# fixes the consumer side without patching fcitx5's packaging.

include(CMakeFindDependencyMacro)

# LibIntl::LibIntl -- supplied by the libintl-lite CMake package we install.
if(NOT TARGET LibIntl::LibIntl)
  find_package(LibIntl QUIET)
endif()

# Pthread::Pthread -- fcitx5 ships its own FindPthread.cmake but does not install
# it, so build the target from CMake's built-in Threads package instead.
if(NOT TARGET Pthread::Pthread)
  set(THREADS_PREFER_PTHREAD_FLAG ON)
  find_package(Threads QUIET)
  if(TARGET Threads::Threads)
    add_library(Pthread::Pthread INTERFACE IMPORTED)
    set_target_properties(Pthread::Pthread PROPERTIES
      INTERFACE_LINK_LIBRARIES Threads::Threads)
  endif()
endif()

# PkgConfig::LibUV -- resolves against the libuv.pc generated for the HarmonyOS
# system libuv.
if(NOT TARGET PkgConfig::LibUV)
  find_package(PkgConfig QUIET)
  if(PkgConfig_FOUND)
    pkg_check_modules(LibUV IMPORTED_TARGET "libuv")
  endif()
endif()

# DL::DL -- dynamic loading support.  fcitx5 ships its own FindDL.cmake and does
# not install it, so the target is recreated here.  On OHOS (musl) dlopen() and
# friends live in libc and the sysroot only carries a stub libdl.a, so this ends
# up linking nothing meaningful either way.
if(NOT TARGET DL::DL)
  add_library(DL::DL INTERFACE IMPORTED)
  find_library(FCITX5_OHOS_DL_LIBRARY NAMES dl)
  if(FCITX5_OHOS_DL_LIBRARY)
    set_target_properties(DL::DL PROPERTIES
      INTERFACE_LINK_LIBRARIES "${FCITX5_OHOS_DL_LIBRARY}")
  endif()
endif()

# Rime::Rime -- wrapping librime and its static dependencies, for fcitx5-rime.
#
# fcitx5-rime takes the library through the RIME_TARGET variable, which it also
# passes to target_link_libraries().  A bare archive path links but carries no
# usage requirements, so <rime_api.h> would not be found; an interface target
# supplies the include directory and the dependency chain.
#
# Two details matter here:
#   * librime registers its modules from static initialisers, so it has to be
#     linked with --whole-archive or the linker discards those objects and
#     librime comes up with no modules loaded;
#   * librime is static and references yaml-cpp, glog, leveldb, marisa, opencc
#     and boost.regex, so they must follow it on the link line, inside a linker
#     group because they depend on each other.
if(DEFINED FCITX5_OHOS_RIME_LIBRARY AND NOT TARGET Rime::Rime)
  set(_fcitx5_ohos_rime_deps
      "${FCITX5_OHOS_RIME_DEP_DIR}/libboost_regex.a"
      "${FCITX5_OHOS_RIME_DEP_DIR}/libglog.a"
      "${FCITX5_OHOS_RIME_DEP_DIR}/libleveldb.a"
      "${FCITX5_OHOS_RIME_DEP_DIR}/libmarisa.a"
      "${FCITX5_OHOS_RIME_DEP_DIR}/libopencc.a"
      "${FCITX5_OHOS_RIME_DEP_DIR}/libyaml-cpp.a")

  add_library(Rime::Rime INTERFACE IMPORTED)
  set_target_properties(Rime::Rime PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${FCITX5_OHOS_RIME_INCLUDE_DIR}"
    INTERFACE_LINK_LIBRARIES
      "-Wl,--start-group;-Wl,--whole-archive;${FCITX5_OHOS_RIME_LIBRARY};-Wl,--no-whole-archive;${_fcitx5_ohos_rime_deps};-Wl,--end-group")
endif()
