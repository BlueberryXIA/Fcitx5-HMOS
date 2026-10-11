/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Key tables for the letter and number panels.
 *
 * The rows, their order and the relative widths are taken from
 * fcitx5-android's TextKeyboard.Layout and NumberKeyboard.Layout so the two
 * keyboards feel the same.  Each table is data only; KeyboardPanel renders it.
 *
 * Widths follow the reference convention: a positive weight is a share out of
 * 100, and 0 means "take an equal part of whatever the positive weights leave".
 * resolveRows() turns that into a positive layoutWeight for every key.
 */

import { KeyCode } from '@kit.InputKit';

import { KeyVariant } from './KeyboardTheme';

/** Which panel a key switches to, or None when it does not switch. */
export enum PanelKind {
  None = 0,
  Letter = 1,
  Number = 2,
  Symbol = 3,
  Emoji = 4
}

/** What pressing a key does. */
export enum KeyKind {
  /** Printable key; types `text`, lower-cased for A-Z unless Shift is active. */
  Char = 0,
  /** One-shot shift. */
  Shift = 1,
  Backspace = 2,
  Enter = 3,
  Space = 4,
  /** Switch to another panel. */
  Switch = 5,
  /** Toggle Chinese/ASCII input. */
  Ascii = 6,
  /** Hide the keyboard. No key table uses it; the candidate bar's ⌄ key hides instead. */
  Hide = 7
}

export interface KeySpec {
  kind: KeyKind;
  /**
   * Main label.  Drawn for Switch keys; the other kinds draw a fixed glyph and
   * use this only as an identity in ForEach.
   */
  label: string;
  /** Small corner label, e.g. the digit on Q.  Drawn for Char keys only. */
  hint: string;
  /** Row share, or 0 to take an equal part of the remainder. */
  weight: number;
  /** Literal text for Char keys. */
  text: string;
  /** Key code passed to Rime for Char keys. */
  keyCode: number;
  /** Destination for Switch keys. */
  target: PanelKind;
  /** Palette role; see KeyVariant. */
  variant: KeyVariant;
  /**
   * Weight after expanding zero-weight keys.
   *
   * Computed by resolveRows(); ArkUI's layoutWeight needs a positive number, so
   * "share the remainder" has to be turned into a concrete share before layout.
   */
  renderWeight: number;
}

/** Fills in renderWeight: 0-weight keys split what the fixed ones leave. */
export function resolveRows(rows: KeySpec[][]): KeySpec[][] {
  const resolvedRows: KeySpec[][] = [];
  for (const row of rows) {
    let fixedWeight: number = 0;
    let fillKeyCount: number = 0;
    for (const key of row) {
      if (key.weight > 0) {
        fixedWeight += key.weight;
      } else {
        fillKeyCount++;
      }
    }
    const fillWeight: number = fillKeyCount > 0
      ? Math.max(1, Math.round((100 - fixedWeight) / fillKeyCount))
      : 0;

    const resolved: KeySpec[] = [];
    for (const key of row) {
      const expanded: KeySpec = {
        kind: key.kind,
        label: key.label,
        hint: key.hint,
        weight: key.weight,
        text: key.text,
        keyCode: key.keyCode,
        target: key.target,
        variant: key.variant,
        renderWeight: key.weight > 0 ? key.weight : fillWeight
      };
      resolved.push(expanded);
    }
    resolvedRows.push(resolved);
  }
  return resolvedRows;
}

function charKey(label: string, hint: string, text: string, keyCode: number,
                 weight: number = 0): KeySpec {
  return {
    kind: KeyKind.Char,
    label: label,
    hint: hint,
    weight: weight,
    text: text,
    keyCode: keyCode,
    target: PanelKind.None,
    variant: KeyVariant.Normal,
    renderWeight: weight
  };
}

/**
 * `index` is the key's position in the reference's QWERTY order (Q=0 … M=25);
 * the Rime key code is KEYCODE_A + index and `upperLetter` is what gets typed.
 */
function letterKey(index: number, upperLetter: string, hint: string, weight: number = 0): KeySpec {
  return charKey(upperLetter, hint, upperLetter, KeyCode.KEYCODE_A + index, weight);
}

function digitKey(digit: string, weight: number = 0): KeySpec {
  // KEYCODE_0 .. KEYCODE_9 are contiguous, so the offset gives the right code.
  return charKey(digit, '', digit, KeyCode.KEYCODE_0 + Number.parseInt(digit, 10), weight);
}

function symbolKey(label: string, weight: number): KeySpec {
  return charKey(label, '', label, 0, weight);
}

function functionKey(kind: KeyKind, label: string, weight: number,
                     target: PanelKind = PanelKind.None): KeySpec {
  return {
    kind: kind,
    label: label,
    hint: '',
    weight: weight,
    text: '',
    keyCode: 0,
    target: target,
    variant: KeyVariant.Alt,
    renderWeight: weight
  };
}

/** The Return key; KeyboardPanel draws it with the accent colour. */
function enterKey(weight: number): KeySpec {
  const key: KeySpec = functionKey(KeyKind.Enter, '回车', weight);
  key.variant = KeyVariant.Accent;
  return key;
}

// ---------------------------------------------------------------------------
// Letter panel
//
//   Q W E R T Y U I O P     each carrying its digit as a corner hint
//   A S D F G H J K L
//   [⇧] Z X C V B N M [⌫]
//   [?123] [中/英] , [space] . [↵]
// ---------------------------------------------------------------------------

export const LETTER_ROWS: KeySpec[][] = [
  [
    letterKey(0, 'Q', '1'), letterKey(1, 'W', '2'), letterKey(2, 'E', '3'),
    letterKey(3, 'R', '4'), letterKey(4, 'T', '5'), letterKey(5, 'Y', '6'),
    letterKey(6, 'U', '7'), letterKey(7, 'I', '8'), letterKey(8, 'O', '9'),
    letterKey(9, 'P', '0')
  ],
  [
    letterKey(10, 'A', '@'), letterKey(11, 'S', '*'), letterKey(12, 'D', '+'),
    letterKey(13, 'F', '-'), letterKey(14, 'G', '='), letterKey(15, 'H', '/'),
    letterKey(16, 'J', '#'), letterKey(17, 'K', '('), letterKey(18, 'L', ')')
  ],
  [
    functionKey(KeyKind.Shift, '⇧', 15),
    letterKey(19, 'Z', '\''), letterKey(20, 'X', ':'), letterKey(21, 'C', '"'),
    letterKey(22, 'V', '?'), letterKey(23, 'B', '!'), letterKey(24, 'N', '~'),
    letterKey(25, 'M', '\\'),
    functionKey(KeyKind.Backspace, '⌫', 15)
  ],
  [
    functionKey(KeyKind.Switch, '?123', 15, PanelKind.Number),
    functionKey(KeyKind.Ascii, '中', 15),
    charKey(',', '', ',', 0, 10),
    functionKey(KeyKind.Space, '空格', 0),
    charKey('.', '', '.', 0, 10),
    enterKey(15)
  ]
];

// ---------------------------------------------------------------------------
// Number panel (its '!?#' key opens the symbol grid)
//
//   + 1 2 3 /
//   - 4 5 6 [space]
//   * 7 8 9 [⌫]
//   ABC , !?# 0 = . [↵]
//
// Fixed widths are the reference's 0.15 / 0.1 / 0.13333 / 0.23334 shares
// written as whole percentages; the unweighted keys take what is left.
// ---------------------------------------------------------------------------

export const NUMBER_ROWS: KeySpec[][] = [
  [
    symbolKey('+', 15),
    digitKey('1'), digitKey('2'), digitKey('3'),
    symbolKey('/', 15)
  ],
  [
    symbolKey('-', 15),
    digitKey('4'), digitKey('5'), digitKey('6'),
    functionKey(KeyKind.Space, '空格', 15)
  ],
  [
    symbolKey('*', 15),
    digitKey('7'), digitKey('8'), digitKey('9'),
    functionKey(KeyKind.Backspace, '⌫', 15)
  ],
  [
    functionKey(KeyKind.Switch, 'ABC', 15, PanelKind.Letter),
    symbolKey(',', 10),
    functionKey(KeyKind.Switch, '!?#', 13, PanelKind.Symbol),
    digitKey('0', 24),
    symbolKey('=', 13),
    symbolKey('.', 10),
    enterKey(15)
  ]
];
