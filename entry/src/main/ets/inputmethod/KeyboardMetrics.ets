/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Shared keyboard geometry.
 *
 * The panel window is sized in px (what Panel.resize() takes) while the page is
 * laid out in vp, so both sides need to agree on one set of numbers.  They are
 * defined here and imported by the extension and the keyboard page alike.
 */

/**
 * Total height of the keyboard, in vp.
 *
 * The page uses it as a fixed height rather than '100%' so the layout is
 * deterministic even if the platform refuses the panel resize, and the extension
 * converts it to px (via display.densityPixels) to size the panel window.
 */
export const KEYBOARD_HEIGHT_VP: number = 280;

/**
 * The candidate strip above the keys.
 *
 * The rest of the key geometry (row height, key gap, row gap) lives in
 * keyboard/KeyboardTheme.ets, because only the keyboard page needs it.  These
 * three were once duplicated here with *different* row-gap value, which meant a
 * wrong import silently changed the layout; the duplicates are gone.
 */
export const CANDIDATE_BAR_HEIGHT_VP: number = 48;

/**
 * Upper bound the platform accepts for a panel's height, as a share of the
 * screen height.  resize() rejects anything taller.
 */
export const MAX_PANEL_HEIGHT_RATIO: number = 0.7;

