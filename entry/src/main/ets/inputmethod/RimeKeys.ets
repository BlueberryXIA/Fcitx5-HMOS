/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Translation between HarmonyOS key events and the X11 key symbols that librime
 * expects.
 *
 * librime's key codes are X11 keysyms (see librime/src/rime/key_table.h).
 * Latin-1 characters keep their own code point, special keys live in the
 * 0xFF00-0xFFFF range, and everything above Latin-1 uses X11's Unicode
 * convention of `0x01000000 | codePoint`.
 */

import { KeyCode } from '@kit.InputKit';

/**
 * librime's `RimeModifier` bits.
 *
 * These mirror `enum RimeModifier` in librime/src/rime/key_table.h and must not
 * be changed: they are part of the engine's wire format.  The native module also
 * exports them, but they are duplicated here so ordinary key handling does not
 * need to cross the N-API boundary.
 */
export class RimeModifier {
  static readonly NONE: number = 0;
  /** Shift held. */
  static readonly SHIFT: number = 1 << 0;
  /** Caps Lock active. */
  static readonly LOCK: number = 1 << 1;
  /** Ctrl held. */
  static readonly CONTROL: number = 1 << 2;
  /** Alt held (X11 Mod1). */
  static readonly ALT: number = 1 << 3;
  /** Super/Win key held. */
  static readonly SUPER: number = 1 << 26;
  /** Key-release event. */
  static readonly RELEASE: number = 1 << 30;
}

/** X11 keysyms for the non-printing keys the keyboard emits. */
export class X11Keysym {
  static readonly BACKSPACE: number = 0xff08;
  static readonly TAB: number = 0xff09;
  static readonly LINE_FEED: number = 0xff0a;
  static readonly RETURN: number = 0xff0d;
  static readonly ESCAPE: number = 0xff1b;
  static readonly HOME: number = 0xff50;
  static readonly LEFT: number = 0xff51;
  static readonly UP: number = 0xff52;
  static readonly RIGHT: number = 0xff53;
  static readonly DOWN: number = 0xff54;
  static readonly PAGE_UP: number = 0xff55;
  static readonly PAGE_DOWN: number = 0xff56;
  static readonly END: number = 0xff57;
  static readonly INSERT: number = 0xff63;
  static readonly DELETE: number = 0xffff;
  static readonly CAPS_LOCK: number = 0xffe5;
  static readonly SHIFT_L: number = 0xffe1;
  static readonly SHIFT_R: number = 0xffe2;
  static readonly CONTROL_L: number = 0xffe3;
  static readonly CONTROL_R: number = 0xffe4;
  static readonly ALT_L: number = 0xffe9;
  static readonly ALT_R: number = 0xffea;
  static readonly SUPER_L: number = 0xffeb;
  static readonly SUPER_R: number = 0xffec;
  static readonly SPACE: number = 0x0020;
}

export class RimeKeys {
  /**
   * HarmonyOS key code -> X11 keysym.
   *
   * Keys that need an explicit mapping: the non-printing keys (arrows, Enter,
   * modifiers, ...) plus Space and Tab, which the arithmetic paths below do not
   * cover.  Letters and digits are computed from their enum base, and
   * punctuation goes through the PUNCTUATION table.
   */
  private static readonly SPECIAL_KEYS: Map<number, number> = new Map<number, number>([
    [KeyCode.KEYCODE_SPACE, X11Keysym.SPACE],
    [KeyCode.KEYCODE_TAB, X11Keysym.TAB],
    [KeyCode.KEYCODE_ENTER, X11Keysym.RETURN],
    [KeyCode.KEYCODE_NUMPAD_ENTER, X11Keysym.RETURN],
    [KeyCode.KEYCODE_DEL, X11Keysym.BACKSPACE],
    [KeyCode.KEYCODE_FORWARD_DEL, X11Keysym.DELETE],
    [KeyCode.KEYCODE_ESCAPE, X11Keysym.ESCAPE],
    [KeyCode.KEYCODE_DPAD_UP, X11Keysym.UP],
    [KeyCode.KEYCODE_DPAD_DOWN, X11Keysym.DOWN],
    [KeyCode.KEYCODE_DPAD_LEFT, X11Keysym.LEFT],
    [KeyCode.KEYCODE_DPAD_RIGHT, X11Keysym.RIGHT],
    [KeyCode.KEYCODE_MOVE_HOME, X11Keysym.HOME],
    [KeyCode.KEYCODE_MOVE_END, X11Keysym.END],
    [KeyCode.KEYCODE_PAGE_UP, X11Keysym.PAGE_UP],
    [KeyCode.KEYCODE_PAGE_DOWN, X11Keysym.PAGE_DOWN],
    [KeyCode.KEYCODE_INSERT, X11Keysym.INSERT],
    [KeyCode.KEYCODE_CAPS_LOCK, X11Keysym.CAPS_LOCK],
    [KeyCode.KEYCODE_SHIFT_LEFT, X11Keysym.SHIFT_L],
    [KeyCode.KEYCODE_SHIFT_RIGHT, X11Keysym.SHIFT_R],
    [KeyCode.KEYCODE_CTRL_LEFT, X11Keysym.CONTROL_L],
    [KeyCode.KEYCODE_CTRL_RIGHT, X11Keysym.CONTROL_R],
    [KeyCode.KEYCODE_ALT_LEFT, X11Keysym.ALT_L],
    [KeyCode.KEYCODE_ALT_RIGHT, X11Keysym.ALT_R],
    [KeyCode.KEYCODE_META_LEFT, X11Keysym.SUPER_L],
    [KeyCode.KEYCODE_META_RIGHT, X11Keysym.SUPER_R]
  ]);

  /** HarmonyOS letters run KEYCODE_A .. KEYCODE_Z contiguous with 'a' .. 'z'. */
  private static readonly LETTER_BASE_CODE: number = KeyCode.KEYCODE_A;
  private static readonly LETTER_BASE_CHAR: number = 'a'.charCodeAt(0);
  /** HarmonyOS digits run KEYCODE_0 .. KEYCODE_9 contiguous with '0' .. '9'. */
  private static readonly DIGIT_BASE_CODE: number = KeyCode.KEYCODE_0;
  private static readonly DIGIT_BASE_CHAR: number = '0'.charCodeAt(0);

  /**
   * Punctuation whose HarmonyOS key code does not line up with its ASCII value.
   * The value is the ASCII code the key produces unshifted.
   */
  private static readonly PUNCTUATION: Map<number, number> = new Map<number, number>([
    [KeyCode.KEYCODE_COMMA, 0x2c],          // ,
    [KeyCode.KEYCODE_PERIOD, 0x2e],         // .
    [KeyCode.KEYCODE_SEMICOLON, 0x3b],      // ;
    [KeyCode.KEYCODE_APOSTROPHE, 0x27],     // '
    [KeyCode.KEYCODE_SLASH, 0x2f],          // /
    [KeyCode.KEYCODE_BACKSLASH, 0x5c],      // backslash
    [KeyCode.KEYCODE_GRAVE, 0x60],          // `
    [KeyCode.KEYCODE_MINUS, 0x2d],          // -
    [KeyCode.KEYCODE_EQUALS, 0x3d],         // =
    [KeyCode.KEYCODE_LEFT_BRACKET, 0x5b],   // [
    [KeyCode.KEYCODE_RIGHT_BRACKET, 0x5d],  // ]
    [KeyCode.KEYCODE_PLUS, 0x2b],           // +
    [KeyCode.KEYCODE_POUND, 0x23],          // #
    [KeyCode.KEYCODE_STAR, 0x2a]            // *
  ]);

  /**
   * Converts a Unicode code point into an X11 keysym.
   *
   * Latin-1 (and therefore all of ASCII) is its own keysym; anything else uses
   * the `0x01000000 | codePoint` convention that X11 and fcitx5 share.
   */
  static keysymFromCodePoint(codePoint: number): number {
    if (codePoint <= 0) {
      return 0;
    }
    if (codePoint <= 0xff) {
      return codePoint;
    }
    return 0x01000000 | codePoint;
  }

  /**
   * Converts a HarmonyOS key code into an X11 keysym.
   *
   * `unicodeChar` is preferred when the platform supplies one, because it
   * already reflects the active layout and Shift state.  Returns 0 when the key
   * has no representation rime can use.
   */
  static keysymFromKeyCode(keyCode: number, unicodeChar: number = 0): number {
    if (unicodeChar > 0) {
      return RimeKeys.keysymFromCodePoint(unicodeChar);
    }

    const specialKeysym: number | undefined = RimeKeys.SPECIAL_KEYS.get(keyCode);
    if (specialKeysym !== undefined) {
      return specialKeysym;
    }

    if (keyCode >= RimeKeys.LETTER_BASE_CODE &&
        keyCode <= RimeKeys.LETTER_BASE_CODE + 25) {
      return RimeKeys.LETTER_BASE_CHAR + (keyCode - RimeKeys.LETTER_BASE_CODE);
    }
    if (keyCode >= RimeKeys.DIGIT_BASE_CODE &&
        keyCode <= RimeKeys.DIGIT_BASE_CODE + 9) {
      return RimeKeys.DIGIT_BASE_CHAR + (keyCode - RimeKeys.DIGIT_BASE_CODE);
    }

    const punctuationKeysym: number | undefined = RimeKeys.PUNCTUATION.get(keyCode);
    if (punctuationKeysym !== undefined) {
      return punctuationKeysym;
    }

    // Numpad digits share the digit keysyms.
    if (keyCode >= KeyCode.KEYCODE_NUMPAD_0 &&
        keyCode <= KeyCode.KEYCODE_NUMPAD_9) {
      return RimeKeys.DIGIT_BASE_CHAR + (keyCode - KeyCode.KEYCODE_NUMPAD_0);
    }

    return 0;
  }

  /**
   * Builds a rime modifier mask from the named modifiers currently held.
   * Calling it with no arguments yields `RimeModifier.NONE`.
   */
  static modifierMask(
    shift: boolean = false,
    ctrl: boolean = false,
    alt: boolean = false,
    capsLock: boolean = false,
    superKey: boolean = false
  ): number {
    let mask: number = RimeModifier.NONE;
    if (shift) {
      mask |= RimeModifier.SHIFT;
    }
    if (ctrl) {
      mask |= RimeModifier.CONTROL;
    }
    if (alt) {
      mask |= RimeModifier.ALT;
    }
    if (capsLock) {
      mask |= RimeModifier.LOCK;
    }
    if (superKey) {
      mask |= RimeModifier.SUPER;
    }
    return mask;
  }
}
