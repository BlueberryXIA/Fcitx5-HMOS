// -*- C++ -*-
//===----------------------------------------------------------------------===//
// Compatibility helpers for building fcitx5 against the HarmonyOS NDK's
// libc++ 15.
//
// This header is force-included (`-include`) into every fcitx5 translation
// unit, before any other include, so that the declarations below are visible
// before the standard library is first used.
//
// Currently it supplies std::hash<std::filesystem::path>, which the C++17
// standard requires but libc++ only implemented in a later release.  fcitx5
// stores filesystem::path values in an unordered_set, so without it the build
// fails with "std::hash<filesystem::path> does not provide a call operator".
//
// Specialising a standard template for a standard type is formally undefined
// behaviour, but it is precisely the specialisation the library itself later
// gained, so it is safe in practice and keeps fcitx5 unmodified.
//===----------------------------------------------------------------------===//

#ifndef FCITX5_OHOS_CXX_COMPAT_H
#define FCITX5_OHOS_CXX_COMPAT_H

// This header is force-included into every translation unit, including CMake's
// compiler-detection probe.  Clang 15 still defaults to gnu++14, and under
// C++14 libc++ has no std::filesystem at all -- so the body must be skipped
// unless the language version actually provides it.  Real fcitx5 sources are
// built at C++20 (set by Fcitx5CompilerSettings.cmake) and do take this path.
#if defined(__cplusplus) && __cplusplus >= 201703L

#include <cstddef>
#include <filesystem>
#include <functional>
#include <string>

#if defined(_LIBCPP_VERSION) && _LIBCPP_VERSION < 170000

namespace std {

template <>
struct hash<std::filesystem::path> {
  std::size_t operator()(const std::filesystem::path& path) const noexcept {
    // Hash the native representation; every path has one, and it is cheap to
    // reach, whereas generic_string() would allocate and re-encode.
    return std::hash<std::filesystem::path::string_type>{}(path.native());
  }
};

}  // namespace std

#endif  // _LIBCPP_VERSION < 17

#endif  // __cplusplus >= 201703L

#endif  // FCITX5_OHOS_CXX_COMPAT_H
