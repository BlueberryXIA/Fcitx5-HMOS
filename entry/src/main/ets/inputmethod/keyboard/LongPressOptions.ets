/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */

/*
 * What a letter key offers when it is long-pressed.
 *
 * Three choices: the letter as the key currently shows it, the same letter in
 * the other case, and a symbol.  Keeping the popup to three cells is what makes
 * it fit on one row; see the note on accents below.
 *
 * The letter-to-symbol pairing follows fcitx5, which pairs every letter with a
 * digit or punctuation mark (<fcitx5>/src/im/keyboard/longpress.cpp,
 * LGPL-2.1-or-later -- compatible with this project's AGPL-3.0-or-later).  The
 * table below is the same pairing as fcitx5-android transcribes it in
 * input/popup/PopupPreset.kt.
 *
 * Upstream pairs each letter with a longer list, for example
 * "a A @ a-circumflex a-diaeresis a-macron ...".  Those accented forms are
 * deliberately left out here: the popup is a single row, and a dozen cells
 * would run off the screen.  Only the symbol from each upstream entry is used.
 */

/** Long-press symbol for each unshifted letter. */
function buildSymbolTable(): Map<string, string> {
  const symbols: Map<string, string> = new Map<string, string>();
  // Top row of the keyboard, paired with the digits above it.
  symbols.set('q', '1');
  symbols.set('w', '2');
  symbols.set('e', '3');
  symbols.set('r', '4');
  symbols.set('t', '5');
  symbols.set('y', '6');
  symbols.set('u', '7');
  symbols.set('i', '8');
  symbols.set('o', '9');
  symbols.set('p', '0');
  // Home row.
  symbols.set('a', '@');
  symbols.set('s', '*');
  symbols.set('d', '+');
  symbols.set('f', '-');
  symbols.set('g', '=');
  symbols.set('h', '/');
  symbols.set('j', '#');
  symbols.set('k', '(');
  symbols.set('l', ')');
  // Bottom row.
  symbols.set('z', '\'');
  symbols.set('x', ':');
  symbols.set('c', '"');
  symbols.set('v', '?');
  symbols.set('b', '!');
  symbols.set('n', '~');
  symbols.set('m', '\\');
  return symbols;
}

const SYMBOL_BY_LETTER: Map<string, string> = buildSymbolTable();

/**
 * The choices for a long-pressed key, in the order they are shown.
 *
 * `label` is what the key currently displays, so on a shifted keyboard the
 * uppercase form comes first and the lowercase second; the symbol is the same
 * either way and always comes last.
 *
 * Returns an empty list for keys that have no long-press choices, which is how
 * the caller tells that a key should not open a popup at all.
 */
export function longPressChoices(label: string): string[] {
  if (label.length !== 1) {
    return [];
  }
  const lower: string = label.toLowerCase();
  const symbol: string | undefined = SYMBOL_BY_LETTER.get(lower);
  if (symbol === undefined) {
    return [];
  }
  const upper: string = lower.toUpperCase();
  const asShown: string = label === lower ? lower : upper;
  const otherCase: string = label === lower ? upper : lower;
  return [asShown, otherCase, symbol];
}
