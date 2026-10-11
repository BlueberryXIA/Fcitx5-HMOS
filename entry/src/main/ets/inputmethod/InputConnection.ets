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
 * So a backspace key must delete via deleteForward(), and reading the text that
 * precedes the caret must use getForwardSync().  Deleting via deleteBackward()
 * for backspace does nothing whenever the caret sits at the end of the text,
 * which is the normal case while typing.  The wrapper methods below are named
 * after what they actually do so callers never have to remember this.
 * ---------------------------------------------------------------------------
 *
 * Only committed text is inserted into the document.  Rime's composing text is
 * shown by the keyboard itself, above the candidates, rather than pushed into
 * the application as preview text -- see the note on commitText().
 */

import { inputMethodEngine } from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLog } from '../common/AppLog';

const DOMAIN: number = 0x0000;
const TAG: string = 'InputConnection';

/**
 * Longest one client call may hold up the calls queued behind it, in ms.
 *
 * The asynchronous client calls return immediately but only *settle* once the
 * target application answers.  An application that never answers therefore
 * leaves its promise pending for good.  Waiting on such a promise is what turns
 * "the main thread is blocked" into "the queue never moves again", which looks
 * exactly like the keyboard being dead while nothing freezes.  Bounding the
 * wait keeps a mute application from taking the keyboard down with it.
 */
const CLIENT_CALL_TIMEOUT_MS: number = 1200;

/** How a bounded client call ended. */
enum ClientCallOutcome {
  /** The application answered. */
  ANSWERED,
  /** The application did not answer before the deadline. */
  TIMED_OUT,
  /** The call failed outright (a rejected promise or a thrown error). */
  FAILED
}

/**
 * Resolves when `operation` settles, or after `milliseconds`, whichever is first.
 *
 * Never rejects: the outcome is returned instead.  Both failures and timeouts
 * are recorded, and that record is what separates the two ways this path can
 * stay silent -- an application that is not answering, and a bug of ours.
 */
function settleWithin(operation: Promise<void>, milliseconds: number,
                      what: string): Promise<ClientCallOutcome> {
  let timer: number = -1;
  const expiry: Promise<ClientCallOutcome> = new Promise<ClientCallOutcome>(
    (resolve: (value: ClientCallOutcome) => void) => {
      timer = setTimeout(() => resolve(ClientCallOutcome.TIMED_OUT), milliseconds);
    });
  const guarded: Promise<ClientCallOutcome> = operation.then(
    () => ClientCallOutcome.ANSWERED,
    (error: BusinessError) => {
      const detail: string = `${what} failed: code=${error.code} msg=${error.message}`;
      hilog.warn(DOMAIN, TAG, '%{public}s', detail);
      AppLog.warn(TAG, detail);
      return ClientCallOutcome.FAILED;
    });
  return Promise.race([guarded, expiry]).then((outcome: ClientCallOutcome) => {
    clearTimeout(timer);
    if (outcome === ClientCallOutcome.TIMED_OUT) {
      const detail: string =
        `${what}: no answer from the target application within ${milliseconds}ms`;
      hilog.warn(DOMAIN, TAG, '%{public}s', detail);
      AppLog.warn(TAG, detail);
    }
    return outcome;
  });
}

export class InputConnection {
  private controller: inputMethodEngine.KeyboardController | null = null;
  private client: inputMethodEngine.InputClient | null = null;

  /**
   * Commits and deletions, in the order the user asked for them.
   *
   * Only one may be in flight at a time: these edit the document, so their order
   * is the user's order.
   */
  private documentOperations: Promise<void> = Promise.resolve();

  /**
   * Appends one document-editing call to its queue.
   *
   * The *Sync variants of these calls are blocking IPC into the target
   * application.  When that application stops answering -- an app running under
   * a compatibility layer is the case this was written for -- the call parks the
   * input method's main thread, and about six seconds later the system's freeze
   * detector reports THREAD_BLOCK_6S and kills the process.  A trace from such a
   * freeze shows the main thread sitting in InsertTextSync under onEnter().
   *
   * The asynchronous variants return instead of parking the thread, so this
   * queue only ever waits on a pending answer, and settleWithin() caps even that.
   *
   * Failures are recorded rather than thrown: by the time the call runs there is
   * no caller left to catch them, and a rejected tail would skip everything
   * queued behind it.  They go to AppLog as well as hilog so the settings page's
   * diagnostics card can show them without a connected workstation.
   */
  private enqueueDocumentOperation(what: string, run: () => Promise<void>): void {
    // The outcome is discarded here: settleWithin() has already recorded a
    // timeout or a failure, and the queue only needs to know the call is over.
    const bounded: () => Promise<void> =
      () => settleWithin(run(), CLIENT_CALL_TIMEOUT_MS, what).then(() => {});
    this.documentOperations = this.documentOperations
      .then(bounded)
      .catch((error: BusinessError) => {
        const detail: string = `${what} failed: code=${error.code} msg=${error.message}`;
        hilog.warn(DOMAIN, TAG, '%{public}s', detail);
        AppLog.warn(TAG, detail);
      });
  }

  attach(controller: inputMethodEngine.KeyboardController,
         client: inputMethodEngine.InputClient): void {
    this.controller = controller;
    this.client = client;
  }

  detach(): void {
    this.controller = null;
    this.client = null;
  }

  isAttached(): boolean {
    return this.client !== null;
  }

  // -------------------------------------------------------------------------
  // document editing
  // -------------------------------------------------------------------------

  /**
   * Inserts committed text at the caret.
   *
   * This class deliberately does not use the platform's preview text
   * (setPreviewText) to show the composing string inline.  Text preview is
   * optional for an application to support, and one that ignores it made every
   * keystroke hold the channel until the deadline: committed text then took
   * seconds to appear.  The keyboards that feel instant in that same
   * application do not use preview text either.  KeyboardPanel draws the
   * composing string above the candidates instead, which needs no cooperation
   * from the application at all.
   */
  commitText(text: string): void {
    if (text.length === 0) {
      return;
    }

    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null) {
      hilog.warn(DOMAIN, TAG, 'commitText ignored: no input client bound');
      return;
    }
    this.enqueueDocumentOperation('commitText', () => client.insertText(text).then(() => {}));
  }

  /**
   * Deletes `length` characters before the caret -- the backspace action.
   *
   * Uses deleteForward() because of the platform's inverted naming; see the
   * header comment.
   */
  deleteBeforeCursor(length: number): void {
    if (length <= 0) {
      return;
    }
    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null) {
      hilog.warn(DOMAIN, TAG, 'deleteBeforeCursor ignored: no input client bound');
      return;
    }
    this.enqueueDocumentOperation('deleteBeforeCursor',
                                  () => client.deleteForward(length).then(() => {}));
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
    const client: inputMethodEngine.InputClient | null = this.client;
    if (client === null) {
      return;
    }
    this.enqueueDocumentOperation('deleteAfterCursor',
                                  () => client.deleteBackward(length).then(() => {}));
  }

  /**
   * Text immediately before the caret.
   *
   * Unused today.  Kept because context-aware features (e.g. deciding whether a
   * space should be full-width) need it.
   */
  // The two readers below are the one place that keeps a blocking call, because
  // they have to return the text rather than a promise.  They are unused today;
  // before wiring them up, note that they block the main thread exactly like the
  // commit path used to, so they need the promise form and an async caller.
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
