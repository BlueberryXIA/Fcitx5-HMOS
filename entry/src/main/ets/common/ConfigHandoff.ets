/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Cross-process hand-off of a picked configuration folder.
 *
 * An input method extension is a separate process with a separate data sandbox,
 * and its context has no startAbilityForResult(), so it cannot open the document
 * picker itself.  The settings page can pick a folder, but anything it copies
 * lands in the app's sandbox, which the keyboard cannot see.
 *
 * What does cross the boundary is the document URI: the picker grants the whole
 * app (the extension shares its token) access to the picked folder.  Only the
 * string has to move, so it travels over a common event.
 *
 * Flow:
 *   1. the settings page picks a folder and publishes IMPORT_URI;
 *   2. the extension subscribes to IMPORT_URI and copies from it into its own
 *      sandbox, then publishes IMPORT_DONE;
 *   3. a keyboard that started after step 1 publishes IMPORT_REQUEST, and any
 *      settings page still alive answers with the URI it is holding.
 *
 * Step 3 exists because common events are not sticky for third-party apps: a
 * subscriber that starts late does not receive earlier events.
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { commonEventManager } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLog } from './AppLog';

const TAG: string = 'ConfigHandoff';

/** Carries `uri`: the picked folder, sent from the settings page to the keyboard. */
export const EVENT_IMPORT_URI: string = 'xyz.blueberrycloud.fcitx_ohos.IMPORT_URI';

/** Published by the keyboard to ask a live settings page to resend the URI. */
export const EVENT_IMPORT_REQUEST: string = 'xyz.blueberrycloud.fcitx_ohos.IMPORT_REQUEST';

/** Published by the keyboard once it has taken the configuration. */
export const EVENT_IMPORT_DONE: string = 'xyz.blueberrycloud.fcitx_ohos.IMPORT_DONE';

/** Subscription handles, kept so they can be released on teardown. */
export interface Handles {
  subscriber: commonEventManager.CommonEventSubscriber | null;
}

export class ConfigHandoff {
  /**
   * Sends a picked folder's URI to whoever is listening.
   *
   * Fire-and-forget: if the keyboard is not running the message is lost, which
   * is what the request/reply path in step 3 is for.
   */
  static publishUri(uri: string): void {
    // The URI travels in `data` rather than `parameters`: the latter is typed as
    // an index signature, which ArkTS refuses to build from an object literal.
    const options: commonEventManager.CommonEventPublishData = { data: uri };
    commonEventManager.publish(EVENT_IMPORT_URI, options, (error) => {
      if (error !== undefined && error !== null && error.code !== 0) {
        AppLog.error(TAG, `publishUri failed: ${error.code} ${error.message}`);
      } else {
        AppLog.info(TAG, `published import uri: ${uri}`);
      }
    });
  }

  /** Asks a live settings page to resend the folder it is holding. */
  static requestUri(): void {
    commonEventManager.publish(EVENT_IMPORT_REQUEST, (error) => {
      if (error !== undefined && error !== null && error.code !== 0) {
        AppLog.warn(TAG, `requestUri failed: ${error.code} ${error.message}`);
      } else {
        AppLog.info(TAG, 'requested import uri');
      }
    });
  }

  /** Tells the settings page that the keyboard has taken the configuration. */
  static publishDone(): void {
    commonEventManager.publish(EVENT_IMPORT_DONE, (error) => {
      if (error !== undefined && error !== null && error.code !== 0) {
        AppLog.warn(TAG, `publishDone failed: ${error.code} ${error.message}`);
      }
    });
  }

  /**
   * Listens for a URI and passes each one to the handler registered with
   * onUri().
   *
   * The returned handle must be passed to release() or the subscriber leaks and
   * keeps the callback alive across page reloads.
   */
  static async listen(): Promise<Handles> {
    const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = { events: [EVENT_IMPORT_URI] };
    const handles: Handles = { subscriber: null };
    try {
      const subscriber: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber(subscribeInfo);
      handles.subscriber = subscriber;
      await commonEventManager.subscribeToEvent(subscriber, (data: commonEventManager.CommonEventData) => {
        ConfigHandoff.deliverUri(data);
      });
      AppLog.info(TAG, 'listening for import uri');
    } catch (error) {
      AppLog.exception(TAG, 'listen failed', error);
    }
    return handles;
  }

  /** Callback installed by the keyboard; set before listen(). */
  private static uriHandler: ((uri: string) => void) | null = null;

  static onUri(uriHandler: (uri: string) => void): void {
    ConfigHandoff.uriHandler = uriHandler;
  }

  private static deliverUri(data: commonEventManager.CommonEventData): void {
    const uri: string | undefined = data.data;
    if (uri === undefined || uri.length === 0) {
      AppLog.warn(TAG, 'import event carried no uri');
      return;
    }
    AppLog.info(TAG, `received import uri: ${uri}`);
    if (ConfigHandoff.uriHandler !== null) {
      ConfigHandoff.uriHandler(uri);
    }
  }

  /** Listens for the keyboard's request, so a live settings page can resend. */
  static async listenForRequest(onRequest: () => void): Promise<Handles> {
    const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = { events: [EVENT_IMPORT_REQUEST] };
    const handles: Handles = { subscriber: null };
    try {
      const subscriber: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber(subscribeInfo);
      handles.subscriber = subscriber;
      await commonEventManager.subscribeToEvent(subscriber, () => {
        AppLog.info(TAG, 'settings page received an import request');
        onRequest();
      });
    } catch (error) {
      AppLog.exception(TAG, 'listenForRequest failed', error);
    }
    return handles;
  }

  // -------------------------------------------------------------------------
  // Last picked folder, remembered on disk
  //
  // The keyboard may start long after the folder was picked, and the settings
  // page may be recreated in between.  Keeping the URI in a file means the page
  // can still answer the keyboard's request in both cases; it lives in the app's
  // own sandbox, which is all this side needs.
  // -------------------------------------------------------------------------

  private static pendingUriFilePath(context: common.Context): string {
    return `${context.filesDir}/pending-import-uri.txt`;
  }

  static savePendingUri(context: common.Context, uri: string): void {
    try {
      const file = fs.openSync(ConfigHandoff.pendingUriFilePath(context),
                               fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, uri);
      } finally {
        fs.closeSync(file);
      }
      AppLog.info(TAG, `saved pending uri: ${uri}`);
    } catch (error) {
      AppLog.exception(TAG, 'savePendingUri failed', error);
    }
  }

  static loadPendingUri(context: common.Context): string {
    try {
      const uriFilePath: string = ConfigHandoff.pendingUriFilePath(context);
      if (!fs.accessSync(uriFilePath)) {
        return '';
      }
      const file = fs.openSync(uriFilePath, fs.OpenMode.READ_ONLY);
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(4096);
        const bytesRead: number = fs.readSync(file.fd, buffer);
        if (bytesRead <= 0) {
          return '';
        }
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(new Uint8Array(buffer, 0, bytesRead));
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      AppLog.exception(TAG, 'loadPendingUri failed', error);
      return '';
    }
  }

  static clearPendingUri(context: common.Context): void {
    try {
      const uriFilePath: string = ConfigHandoff.pendingUriFilePath(context);
      if (fs.accessSync(uriFilePath)) {
        fs.unlinkSync(uriFilePath);
      }
    } catch (error) {
      AppLog.exception(TAG, 'clearPendingUri failed', error);
    }
  }

  static async release(handles: Handles | null): Promise<void> {
    if (handles === null || handles.subscriber === null) {
      return;
    }
    try {
      await commonEventManager.unsubscribe(handles.subscriber);
    } catch (error) {
      AppLog.exception(TAG, 'release failed', error);
    }
    handles.subscriber = null;
  }
}
