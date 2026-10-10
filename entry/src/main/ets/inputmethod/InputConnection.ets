/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Adapter between the Rime engine and the HarmonyOS input connection.
 *
 * The engine produces plain strings; this class knows how to show them in the
 * target editor.
 *
 * ---------------------------------------------------------------------------
 * IMPORTANT: several InputClient method names are inverted relative to what
 * they do.  The OpenHarmony IME Kit documentation is explicit:
 *
 *   deleteForward(n)  删除光标【前】固定长度的文本   -> deletes BEFORE the caret
 *   deleteBackward(n) 删除光标【后】固定长度的文本   -> deletes AFTER the caret
 *   getForward(n)     获取光标【前】固定长度的文本   -> reads BEFORE the caret
 *   getBackward(n)    获取光标【后】固定长度的文本   -> reads AFTER the caret
 *
 * So a backspace key must call deleteForwardSync(), and reading the text that
 * precedes the caret must use getForwardSync().  Calling deleteBackwardSync()
 * for backspace does nothing whenever the caret sits at the end of the text,
 * which is the normal case while typing.  The wrapper methods below are named
 * after what they actually do so callers never have to remember this.
 * ---------------------------------------------------------------------------
 *
 * Rime's composing text is rendered as *preview* text (the platform's inline
 * composition overlay) and only committed text is inserted into the document.
 */

import { inputMethodEngine } from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'InputConnection';

/**
 * "Replace the whole preview area" range.
 *
 * setPreviewText() rejects any other negative value as a parameter error; only
 * { -1, -1 } is the documented way to address the entire preview.
 */
const WHOLE_PREVIEW_RANGE: inputMethodEngine.Range = { start: -1, end: -1 };

export class InputConnection {
  private controller: inputMethodEngine.KeyboardController | null = null;
  private client: inputMethodEngine.InputClient | null = null;

  /** True while preview text is displayed and must be cleared before insert. */
  private previewActive: boolean = false;

  attach(controller: inputMethodEngine.KeyboardController,
         client: inputMethodEngine.InputClient): void {
    this.controller = controller;
    this.client = client;
    this.previewActive = false;
  }

  detach(): void {
    this.controller = null;
    this.client = null;
    this.previewActive = false;
  }

  isAttached(): boolean {
    return this.client !== null;
  }

  // -------------------------------------------------------------------------
  // composing text (preview overlay)
  // -------------------------------------------------------------------------

  /**
   * Shows the composing text inline, or clears the preview when it is empty.
   *
   * Preview text is an overlay on top of the document rather than part of it,
   * and every call replaces the whole overlay, so the composing text never has
   * to be edited in place.
   */
  updatePreview(preedit: string): void {
    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null) {
      return;
    }

    if (preedit.length === 0) {
      this.clearPreview();
      return;
    }

    try {
      client.setPreviewTextSync(preedit, WHOLE_PREVIEW_RANGE);
      this.previewActive = true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setPreviewTextSync failed: code=%{public}d msg=%{public}s',
                 err.code, err.message);
    }
  }

  /**
   * Removes the preview overlay without inserting anything.
   *
   * Note that finishTextPreviewSync() would *commit* the preview into the
   * document instead, which is almost never what an input method wants here.
   */
  clearPreview(): void {
    if (!this.previewActive) {
      return;
    }
    this.previewActive = false;

    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null) {
      return;
    }
    try {
      client.setPreviewTextSync('', WHOLE_PREVIEW_RANGE);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'clearing preview failed: code=%{public}d msg=%{public}s',
                 err.code, err.message);
    }
  }

  // -------------------------------------------------------------------------
  // document editing
  // -------------------------------------------------------------------------

  /**
   * Inserts committed text at the caret.
   *
   * The composing overlay is dropped first so a stale preedit is not left
   * sitting next to the committed text.
   */
  commitText(text: string): void {
    if (text.length === 0) {
      return;
    }
    this.clearPreview();

    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null) {
      hilog.warn(DOMAIN, TAG, 'commitText ignored: no input client bound');
      return;
    }
    try {
      client.insertTextSync(text);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'insertTextSync failed: code=%{public}d msg=%{public}s',
                  err.code, err.message);
    }
  }

  /**
   * Deletes `length` characters before the caret -- the backspace action.
   *
   * Uses deleteForwardSync() because of the platform's inverted naming; see the
   * header comment.
   */
  deleteBeforeCursor(length: number): void {
    if (length <= 0) {
      return;
    }
    this.clearPreview();

    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null) {
      hilog.warn(DOMAIN, TAG, 'deleteBeforeCursor ignored: no input client bound');
      return;
    }
    try {
      client.deleteForwardSync(length);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'deleteForwardSync failed: code=%{public}d msg=%{public}s',
                 err.code, err.message);
    }
  }

  /**
   * Deletes `length` characters after the caret (forward delete).
   *
   * Unused: the keyboard has no forward-delete key.  Kept as the counterpart of
   * deleteBeforeCursor().
   */
  deleteAfterCursor(length: number): void {
    if (length <= 0) {
      return;
    }
    this.clearPreview();

    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null) {
      return;
    }
    try {
      client.deleteBackwardSync(length);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'deleteBackwardSync failed: code=%{public}d msg=%{public}s',
                 err.code, err.message);
    }
  }

  /**
   * Text immediately before the caret.
   *
   * Unused today.  Kept because context-aware features (e.g. deciding whether a
   * space should be full-width) need it.
   */
  getTextBeforeCursor(length: number): string {
    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null || length <= 0) {
      return '';
    }
    try {
      // getForward reads *before* the caret; see the header comment.
      return client.getForwardSync(length);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getForwardSync failed: code=%{public}d msg=%{public}s',
                 err.code, err.message);
      return '';
    }
  }

  /**
   * Text immediately after the caret.
   *
   * Unused today; the counterpart of getTextBeforeCursor().
   */
  getTextAfterCursor(length: number): string {
    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null || length <= 0) {
      return '';
    }
    try {
      return client.getBackwardSync(length);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getBackwardSync failed: code=%{public}d msg=%{public}s',
                 err.code, err.message);
      return '';
    }
  }

  async hideKeyboard(): Promise<void> {
    const controller: inputMethodEngine.KeyboardController | null = this.controller;
    if (controller === null) {
      return;
    }
    try {
      await controller.hideKeyboard();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'hideKeyboard failed: msg=%{public}s', err.message);
    }
  }
}
