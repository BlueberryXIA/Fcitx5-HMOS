#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Haochen Xia
#
#
#
# One-shot build of everything the HAP needs.
#
#   1. fetch third-party sources          (network)
#   2. cross-compile the dependencies     (slow, cached)
#   3. cross-compile the engine           (slow, cached)
#   4. assemble the HAP with hvigor
#
# Every stage is incremental, so re-running is cheap once it has succeeded.
#
# Usage:
#   scripts/build_all.sh                 # full build
#   scripts/build_all.sh --skip-fetch    # don't touch the network
#   scripts/build_all.sh --hap-only      # just re-run hvigor
#   OHOS_ARCH=arm64-v8a JOBS=8 scripts/build_all.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_FETCH=""
HAP_ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-fetch) SKIP_FETCH=1; shift ;;
    --hap-only)   HAP_ONLY=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m######## %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# hvigorw ships with DevEco Studio; make sure it is on PATH.
if ! command -v hvigorw > /dev/null 2>&1; then
  for candidate in /opt/devecostudio/tools/bin /usr/local/bin; do
    if [ -x "${candidate}/hvigorw" ]; then
      PATH="${candidate}:${PATH}"
      break
    fi
  done
fi

if [ -z "${HAP_ONLY}" ]; then
  if [ -z "${SKIP_FETCH}" ]; then
    step "1/4  fetching sources"
    "${SCRIPT_DIR}/fetch_sources.sh" || die "source fetch failed"
  else
    step "1/4  fetching sources (skipped)"
  fi

  step "2/4  building third-party dependencies"
  "${SCRIPT_DIR}/build_thirdparty.sh" || die "third-party build failed"

  step "3/4  building the engine"
  "${SCRIPT_DIR}/build_engine.sh" || die "engine build failed"
fi

step "4/4  assembling the HAP"
command -v hvigorw > /dev/null 2>&1 || die "hvigorw not found; install DevEco Studio or add its tools/bin to PATH"
cd "${PROJECT_ROOT}" || die "cannot enter ${PROJECT_ROOT}"
hvigorw assembleHap --no-daemon || die "HAP assembly failed"

step "done"
find "${PROJECT_ROOT}/entry/build" -name '*.hap' -printf 'HAP: %p\n' 2>/dev/null || true
