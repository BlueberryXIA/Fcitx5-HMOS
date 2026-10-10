#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
#
#
# Builds a host-side probe that drives librime directly, so engine behaviour can
# be checked without a device.
#
# This exists because a bug in the app turned out to live in librime's OpenCC
# integration: with the conversion data missing, `simplifier@zh_simp` silently
# returns the original Traditional candidates, which looks exactly like "the
# switch does nothing". Reading the code was not enough to be sure -- running it
# was.
#
# Both librime and OpenCC are built for the host at the *same versions the app
# uses*: librime from the in-tree source, OpenCC from thirdparty/opencc (pinned
# to ver.1.1.9 by fetch_sources.sh). Linking the system OpenCC instead would be
# misleading: OpenCC 1.3 returns a null conversion chain where 1.1.9 throws, so
# the failure modes differ.
#
# Usage:
#     scripts/build_host_probe.sh            # build
#     scripts/build_host_probe.sh --run      # build, then run the checks
#
# --run covers four things:
#   A. no opencc/ data  -> zh_simp silently changes nothing (the bug it found)
#   B. with opencc/     -> zh_simp produces Simplified candidates
#   C. lua plugin       -> a lua_translator schema loads and emits a candidate
#   D. grammar plugin   -> a schema's grammar/language model is picked up
#                          (skipped when build_grammar was not built)
#
# Run the built probe binary directly to print the registry's component
# availability and, when the active schema declares grammar/language, whether
# the Octagram plugin picked the model up ("use grammar: <language>").
#
# Output lands in entry/src/main/cpp/thirdparty/build/host/.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPP_DIR="${PROJECT_ROOT}/entry/src/main/cpp"
HOST="${CPP_DIR}/thirdparty/build/host"
JOBS="$(nproc)"

OPENCC_SRC="${CPP_DIR}/thirdparty/opencc"
LIBRIME_SRC="${CPP_DIR}/librime"
PROBE_SRC="${CPP_DIR}/thirdparty/host-probe"
# Headers and conversion data are taken from the *device* prefix: both are
# architecture-independent, and reusing them keeps the probe on exactly the
# files the app ships.  The OpenCC archive itself is built for the host below.
OPENCC_DATA="${CPP_DIR}/thirdparty/install/arm64-v8a/share/opencc"
OPENCC_INC_SRC="${CPP_DIR}/thirdparty/install/arm64-v8a/include/opencc"
BUNDLED_DATA="${PROJECT_ROOT}/entry/src/main/resources/rawfile/rime"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
# Used for conditions that skip an optional step; before this existed the call
# site aborted the script under `set -e`.
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }

# --- OpenCC 1.1.9 ------------------------------------------------------------
# GCC 15 and newer no longer pull <cstdint>/<cstddef> in transitively, which this
# vintage of OpenCC relies on.
if [[ ! -f "${HOST}/opencc/src/libopencc.a" ]]; then
    log "configuring OpenCC (host)"
    cmake -S "${OPENCC_SRC}" -B "${HOST}/opencc" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_DOCUMENTATION=OFF -DBUILD_TESTING=OFF -DENABLE_GTEST=OFF \
        -DUSE_SYSTEM_RAPIDJSON=OFF \
        -DCMAKE_CXX_FLAGS="-include cstdint -include cstddef" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > /dev/null
    log "building OpenCC (host)"
    cmake --build "${HOST}/opencc" -j"${JOBS}" > /dev/null
fi

# --- librime ----------------------------------------------------------------
if [[ ! -f "${HOST}/librime/lib/librime.a" ]]; then
    mkdir -p "${HOST}/opencc-inc/opencc"
    cp -f "${OPENCC_INC_SRC}"/*.hpp "${HOST}/opencc-inc/opencc/" 2>/dev/null || true
    cp -f "${OPENCC_INC_SRC}"/*.h   "${HOST}/opencc-inc/opencc/" 2>/dev/null || true

    # The Opencc_* paths are spelled out because the host has no installed
    # OpenCC: FindOpencc is given the copied headers, the archive built just
    # above, and the device prefix's conversion data.
    #
    # BUILD_TOOLS is left at its default (ON) here, unlike the device build, so
    # the octagram plugin also builds its build_grammar tool; check D below uses
    # it to compile a test .gram model.
    log "configuring librime (host)"
    cmake -S "${LIBRIME_SRC}" -B "${HOST}/librime" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC=ON \
        -DBUILD_TEST=OFF -DBUILD_SAMPLE=OFF -DBUILD_SEPARATE_LIBS=OFF \
        -DENABLE_LOGGING=ON -DENABLE_EXTERNAL_PLUGINS=OFF -DENABLE_TIMESTAMP=OFF \
        -DOpencc_INCLUDE_PATH="${HOST}/opencc-inc" \
        -DOpencc_LIBRARY="${HOST}/opencc/src/libopencc.a" \
        -DOpencc_DICT_DIR="${OPENCC_DATA}" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > /dev/null
    log "building librime (host)"
    cmake --build "${HOST}/librime" -j"${JOBS}" > /dev/null
fi

# --- probes -----------------------------------------------------------------
# librime's Lua plugin is merged into librime.a by build_engine.sh, which copies
# thirdparty/librime-lua into librime/plugins/lua.  The interpreter is a separate
# library, so it has to be linked here too -- exactly as the module's
# CMakeLists.txt does for the device build.
#
# librime registers its modules from static initialisers, so librime.a is pulled
# in with --whole-archive; without it the linker drops those objects and nothing
# gets registered.  The static dependencies are mutually recursive, hence the
# linker group.  GLOG_USE_GLOG_EXPORT is demanded by glog 0.7's headers, as in
# the module's CMakeLists.txt.
PROBE_LIBS=(-lyaml-cpp -lleveldb -lmarisa -lglog -lboost_regex -llua -lpthread -ldl)

log "building probes"
g++ -std=c++17 -O1 -g -o "${HOST}/probe/probe" "${PROBE_SRC}/host_probe.cc" \
    -I "${LIBRIME_SRC}/src" -I "${LIBRIME_SRC}/include" -I "${HOST}/opencc-inc" \
    -I "${HOST}/librime/src" -DGLOG_USE_GLOG_EXPORT \
    -Wl,--start-group -Wl,--whole-archive "${HOST}/librime/lib/librime.a" \
    -Wl,--no-whole-archive "${HOST}/opencc/src/libopencc.a" \
    "${PROBE_LIBS[@]}" -Wl,--end-group

g++ -std=c++17 -O1 -g -o "${HOST}/probe/lua_probe" "${PROBE_SRC}/lua_probe.cc" \
    -I "${LIBRIME_SRC}/src" -I "${LIBRIME_SRC}/include" -I "${HOST}/opencc-inc" \
    -I "${HOST}/librime/src" -DGLOG_USE_GLOG_EXPORT \
    -Wl,--start-group -Wl,--whole-archive "${HOST}/librime/lib/librime.a" \
    -Wl,--no-whole-archive "${HOST}/opencc/src/libopencc.a" \
    "${PROBE_LIBS[@]}" -Wl,--end-group

# The bundled data, so the probe exercises the same schemas the app ships.
mkdir -p "${HOST}/probe/shared"
cp -f "${BUNDLED_DATA}"/*.yaml "${BUNDLED_DATA}"/*.txt "${HOST}/probe/shared/" 2>/dev/null || true

if [[ "${1:-}" == "--run" ]]; then
    cd "${HOST}/probe"
    rm -rf user && mkdir -p user

    log "A: without opencc/ (reproduces the silent no-conversion bug)"
    rm -rf shared/opencc
    ./probe "${PWD}/shared" "${PWD}/user" | grep -E '========|candidates|committed'

    rm -rf user && mkdir -p user
    log "B: with opencc/ (zh_simp must produce Simplified candidates)"
    cp -r "${OPENCC_DATA}" shared/opencc
    ./probe "${PWD}/shared" "${PWD}/user" | grep -E '========|candidates|committed'

    # --- Lua plugin ---------------------------------------------------------
    # A schema whose only translator is lua_translator@test_lua: if the plugin
    # is missing the schema cannot be selected at all, and if the interpreter is
    # unreachable the script never runs.
    log "C: lua plugin (schema must load and the script must emit a candidate)"
    mkdir -p user
    cat > user/rime.lua <<'LUA'
function test_lua(input, seg, env)
  if input == "lua" then
    yield(Candidate("lua", seg.start, seg._end, "LUA_WORKS", " probe"))
  end
end
LUA
    python3 - "${PWD}/shared" <<'PYEOF'
import sys
shared = sys.argv[1]
original = open(f"{shared}/luna_pinyin.schema.yaml").read()
schema = original.replace("schema_id: luna_pinyin", "schema_id: luatest")
schema = schema.replace("  translators:\n    - punct_translator",
                        "  translators:\n    - lua_translator@test_lua\n    - punct_translator")
open(f"{shared}/luatest.schema.yaml", "w").write(schema)
config = open(f"{shared}/default.yaml").read()
config = config.replace("schema_list:\n  - schema: luna_pinyin",
                        "schema_list:\n  - schema: luatest\n  - schema: luna_pinyin")
open(f"{shared}/default.yaml", "w").write(config)
PYEOF
    rm -rf user/build
    ./lua_probe "${PWD}/shared" "${PWD}/user" | tail -4

    # --- grammar plugin -----------------------------------------------------
    # A schema that declares grammar/language.  With a model present the plugin
    # logs "use grammar: <language>"; with none it logs "failed to load grammar
    # database", which is the difference the in-app diagnostics report.
    log "D: grammar plugin (schema declares grammar/language)"
    GRAM_TOOL="${HOST}/librime/plugins/octagram/bin/build_grammar"
    if [[ -x "${GRAM_TOOL}" ]]; then
        printf '你好 100.0\n你好世界 90.0\n' > shared/corpus.txt
        (cd shared && "${GRAM_TOOL}" testgram < corpus.txt > /dev/null 2>&1) || true
        cat > user/luna_pinyin.custom.yaml <<'YAML'
patch:
  grammar:
    language: testgram
    collocation_max_length: 5
    collocation_min_length: 2
YAML
        rm -rf user/build
        ./probe "${PWD}/shared" "${PWD}/user" "nihao" 2>&1 \
            | grep -E "use grammar|failed to load grammar|component check" | head -4
    else
        warn "build_grammar not built; skipping the grammar check"
    fi
    echo
    echo "For a ranking comparison with a real model, point the probe at a"
    echo "configuration that ships one and run it with and without the .gram file."
fi
