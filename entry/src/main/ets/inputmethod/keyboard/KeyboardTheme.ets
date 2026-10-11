/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Keyboard colour palette and metrics.
 *
 * Values follow fcitx5-android's MaterialLight theme (data/theme/ThemePreset.kt)
 * so the keyboard looks like the reference implementation rather than an
 * approximation of it.  Names match the theme fields one-for-one where they
 * exist, which makes a future theme switch a matter of swapping this class.
 */

/** Colours, transcribed from ThemePreset.MaterialLight. */
export class KeyboardTheme {
  /** Panel background behind the key rows; also fills empty picker cells. */
  static readonly keyboard: string = '#ECEEF1';
  /** Background of the candidate strip. */
  static readonly bar: string = '#E4E7E9';

  /** Ordinary keys: letter and digit keys, picker cells, candidate chips. */
  static readonly key: string = '#FBFBFC';
  /** Text on ordinary keys, and the default body text in the settings panel. */
  static readonly keyText: string = '#37474F';

  /** Function keys: shift, backspace and the layout-switch keys. */
  static readonly altKey: string = '#DFE2E4';
  /** A control that is visible but cannot be used right now, e.g. a picker arrow that is at its last page. */
  static readonly altKeyText: string = '#7A858A';

  /** Emphasised items: Return, the active picker tab and an enabled switch. */
  static readonly accentKey: string = '#5CB5AB';
  static readonly accentKeyText: string = '#FFFFFF';

  /** Space bar. */
  static readonly spaceBar: string = '#C9CED1';

  /** Highlight for an engaged toggle: Shift, or ASCII mode. */
  static readonly activeKey: string = '#80CBC4';
  static readonly activeKeyText: string = '#37474F';

  // The pressed shade of each surface above.
  //
  // A key that is held down takes a darker version of whatever colour it
  // already has, rather than one shared highlight colour: a pressed Return key
  // that turned the same grey as a pressed letter would lose the colour that
  // tells the two apart.  Each is the base darkened by roughly the same amount,
  // so the effect reads the same across the keyboard.

  /** An ordinary key while held. */
  static readonly keyPressed: string = '#E3E6E9';
  /** A function key while held. */
  static readonly altKeyPressed: string = '#C7CCD0';
  /** Return while held. */
  static readonly accentKeyPressed: string = '#4BA49A';
  /** The space bar while held. */
  static readonly spaceBarPressed: string = '#B3B9BD';
  /** An engaged toggle while held. */
  static readonly activeKeyPressed: string = '#6BB8B0';

  /** Preedit and candidate text in the candidate strip. */
  static readonly candidateText: string = '#37474F';
  /** Candidate comments, the page counter, and muted settings text (headings and hints). */
  static readonly candidateComment: string = '#7A858A';
  /** Separator between settings sections. */
  static readonly divider: string = '#E4E7E9';

  /** Small text in the corner of a key, e.g. the digit on Q. */
  static readonly altKeyLabel: string = '#7A858A';

  /** Keyboard-wide error/message text. */
  static readonly message: string = '#D46B08';
  static readonly messageBackground: string = '#FFF7E6';
  /** Interactive text: enabled paging arrows, buttons and the settings links. */
  static readonly link: string = '#0A59F7';
}

/**
 * Palette role a key would use.
 *
 * Informational only: KeyboardPanel colours keys from KeyKind, so nothing reads
 * this enum.
 */
export enum KeyVariant {
  /** Letter and digit keys. */
  Normal = 0,
  /** Function keys. */
  Alt = 1,
  /** The emphasised key in a row. */
  Accent = 2
}

// ---------------------------------------------------------------------------
// Metrics, in vp.
//
// Panel height lives in KeyboardMetrics instead, because the input method
// extension needs it to size the panel and importing the palette there would
// pull the whole colour table into a non-UI module.
//
// Key geometry lives here.  KeyboardMetrics holds only what the input method
// extension also needs (the panel height and its ratio) plus the candidate bar
// height, which the page imports from there.  The two modules deliberately
// share no constant: they used to, with different values, which made a wrong
// import silently change the layout.
// ---------------------------------------------------------------------------

/** Corner radius of a key, tab, picker cell or candidate chip. */
export const KEY_RADIUS_VP: number = 6;
/** Gap between keys in a row. */
export const KEY_GAP_VP: number = 5;
/** Gap between rows. */
export const ROW_GAP_VP: number = 7;
/** Height of one key row. */
export const KEY_ROW_HEIGHT_VP: number = 46;

/**
 * Height of one candidate chip.
 *
 * Shorter than the candidate strip on purpose: at full strip height a chip was
 * a tall white block with the text floating in it and blank white showing
 * underneath, which read as an empty box rather than a chip.
 */
export const CANDIDATE_CHIP_HEIGHT_VP: number = 30;
/** Font size of a letter or digit on a key. */
export const KEY_TEXT_SIZE: number = 21;
/** Font size of a label on a function key. */
export const KEY_ALT_TEXT_SIZE: number = 15;
/** Font size of the small corner label. */
export const KEY_HINT_TEXT_SIZE: number = 9;
/** Font size in the symbol and emoji grids. */
export const GRID_TEXT_SIZE: number = 19;
/** Height of the category tab strip above a picker grid. */
export const PICKER_TAB_HEIGHT_VP: number = 30;
