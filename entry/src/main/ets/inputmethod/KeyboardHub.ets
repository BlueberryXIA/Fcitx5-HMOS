/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Single entry point the keyboard UI uses to type.
 *
 * The panel page (UI) and the input-method extension (lifecycle) run in the same
 * process, so both import this singleton and therefore share one engine and one
 * input connection.  Keeping the "engine result -> editor update" logic here
 * means the panel only has to report key presses.
 */

import { inputMethodEngine } from '@kit.IMEKit';
import { KeyCode } from '@kit.InputKit';

import { InputConnection } from './InputConnection';
import { RimeEngineService } from './RimeEngineService';
import { RimeModifier } from './RimeKeys';

export class KeyboardHub {
  private static instance: KeyboardHub | null = null;

  private engine: RimeEngineService = RimeEngineService.getInstance();
  private connection: InputConnection = new InputConnection();

  private constructor() {
  }

  static getInstance(): KeyboardHub {
    if (KeyboardHub.instance === null) {
      KeyboardHub.instance = new KeyboardHub();
    }
    return KeyboardHub.instance;
  }

  getEngine(): RimeEngineService {
    return this.engine;
  }

  getConnection(): InputConnection {
    return this.connection;
  }

  /** Called by the extension when a new editor takes input focus. */
  attach(controller: inputMethodEngine.KeyboardController,
         client: inputMethodEngine.InputClient): void {
    this.connection.attach(controller, client);
  }

  /** Called when the editor loses focus or input stops. */
  detach(): void {
    this.connection.detach();
    this.engine.reset();
  }

  isAttached(): boolean {
    return this.connection.isAttached();
  }

  // -------------------------------------------------------------------------
  // key handling
  // -------------------------------------------------------------------------

  /**
   * Reports a key press.
   *
   * `unicodeChar` should be the character the key produces, or 0 for keys that
   * only have a keysym (arrows, Escape, ...).
   */
  onKey(keyCode: number, unicodeChar: number = 0, modifiers: number = RimeModifier.NONE): void {
    const engine: RimeEngineService = this.engine;

    // An engine that is not ready yet (bootstrap or first deployment) cannot
    // compose, so printable input goes straight to the editor instead of being
    // swallowed.  That keeps the keyboard usable while Rime starts up.
    if (!engine.isReady()) {
      if (unicodeChar > 0 && modifiers === RimeModifier.NONE) {
        this.connection.commitText(String.fromCodePoint(unicodeChar));
      }
      return;
    }

    const committedText: string | null = engine.handleKey(keyCode, unicodeChar, modifiers);
    if (committedText !== null) {
      this.connection.commitText(committedText);
    }
    // Nothing else to do here.  The composing text is not pushed into the editor
    // as preview text any more: an application that ignores setPreviewText made
    // every keystroke hold the channel until the deadline and delayed the text
    // that actually mattered.  KeyboardPanel draws the pinyin above the
    // candidates instead, from the state the engine publishes.
  }

  // -------------------------------------------------------------------------
  // convenience actions used by the keyboard layout
  // -------------------------------------------------------------------------

  onBackspace(): void {
    const engine: RimeEngineService = this.engine;
    if (engine.isReady() && engine.isComposing()) {
      // While composing, Rime owns the backspace so its internal state stays
      // consistent (it may step back a whole syllable, not just one letter).
      this.onKey(KeyCode.KEYCODE_DEL, 0, RimeModifier.NONE);
      return;
    }

    // Nothing composing: delete real text from the document.  This must go
    // through deleteBeforeCursor(), which maps onto the platform's
    // (mis-named) deleteForward API -- see InputConnection.
    this.connection.deleteBeforeCursor(1);
  }

  /**
   * Space picks the first candidate of the page the keyboard is showing.
   *
   * The caller supplies the global index because the keyboard owns pagination;
   * passing 0 here would jump back to the first page's first candidate.
   */
  onSpace(firstVisibleCandidateIndex: number): void {
    if (this.engine.getCandidates().length > 0) {
      this.onSelectCandidate(firstVisibleCandidateIndex);
      return;
    }
    this.onKey(KeyCode.KEYCODE_SPACE, 0x20, RimeModifier.NONE);
  }

  onEnter(): void {
    const committedText: string | null = this.engine.commitComposition();
    // A newline has no keysym Rime acts on, so it is inserted directly.  The
    // composition and the newline go out as ONE insert rather than two: two
    // calls would have to reach the client in order, and a single round trip is
    // both cheaper and impossible to reorder.
    const composition: string = committedText === null ? '' : committedText;
    this.connection.commitText(composition + '\n');
  }

  onEscape(): void {
    this.engine.clearComposition();
  }

  /** `globalIndex` is an index into the whole candidate list. */
  onSelectCandidate(globalIndex: number): void {
    const committedText: string | null = this.engine.selectCandidate(globalIndex);
    if (committedText !== null) {
      this.connection.commitText(committedText);
    }
  }

  onToggleAsciiMode(): void {
    this.engine.toggleAsciiMode();
  }

  /**
   * Commits text straight to the editor, bypassing Rime.
   *
   * Used for emoji: they are frequently several code points (ZWJ sequences,
   * skin-tone modifiers) and typeCharacter() only forwards the first one, which
   * would turn a family emoji into a single person.
   */
  commitDirect(text: string): void {
    if (text.length === 0) {
      return;
    }
    // Anything half-composed would otherwise be stranded behind the emoji.
    const pendingComposition: string | null = this.engine.commitComposition();
    if (pendingComposition !== null && pendingComposition.length > 0) {
      this.connection.commitText(pendingComposition);
    }
    this.connection.commitText(text);
  }

  /**
   * Types a literal character by code point.
   *
   * Used by the symbol grid.  Letter and digit keys do NOT come through here;
   * they carry a key code and go to onKey() so Rime receives a real key event.
   */

  typeCharacter(text: string): void {
    if (text.length === 0) {
      return;
    }
    const codePoint: number = text.codePointAt(0) ?? 0;
    if (codePoint === 0) {
      return;
    }
    this.onKey(0, codePoint, RimeModifier.NONE);
  }

  async hideKeyboard(): Promise<void> {
    await this.connection.hideKeyboard();
  }
}
