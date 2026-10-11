/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Build identity, shown in the UI so a reported problem can be tied to an exact
 * build.
 *
 * Bump BUILD on every delivery.  The patch component of the version is the build
 * number, so a report of "1.0.7" identifies one specific set of changes.
 */

/** Incremented for every delivery to the user. */
export const BUILD: number = 41;

export const VERSION_NAME: string = `1.0.${BUILD}`;

/**
 * HarmonyOS versionCode.
 *
 * Must increase for every installable package or the system refuses the update,
 * so it is derived from BUILD rather than maintained separately.
 */
export const VERSION_CODE: number = 1000000 + BUILD;

/** One-line identity for logs and the title bar. */
export const VERSION_LABEL: string = `Fcitx5 for HarmonyOS ${VERSION_NAME} (build ${BUILD})`;
