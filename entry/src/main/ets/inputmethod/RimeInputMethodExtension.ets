/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * The input-method extension.
 *
 * Lifecycle:
 *   onCreate   - start the Rime engine and begin deployment; create the keyboard
 *                panel and register for input-focus events.
 *   inputStart - an editor took focus; bind the input connection and show the
 *                keyboard.  Panel.show() is only valid once the IME is bound to
 *                an edit box, so it must happen here rather than in onCreate.
 *   inputStop  - the editor lost focus; hide the keyboard and drop the
 *                connection.
 *   onDestroy  - release the panel and shut librime down.
 *
 * The panel's UI lives in pages/KeyboardPanel.ets; it reaches the engine through
 * the KeyboardHub singleton rather than through this class.
 *
 * Note on panel enums: the input-method *engine* namespace spells its flags
 * `FLG_FIXED` (inputMethodEngine.PanelFlag), which is a different enum from the
 * `FLAG_FIXED` used by inputMethod.Panel.  createPanel() expects the former.
 */

import { Want } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import {
  InputMethodExtensionAbility,
  InputMethodSubtype,
  inputMethodEngine
} from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { KeyboardHub } from './KeyboardHub';
import { RimeEngineService } from './RimeEngineService';
import { ConfigHandoff, Handles } from '../common/ConfigHandoff';
import { AppLog } from '../common/AppLog';
import { FolderImportOutcome } from './RimeConfigStore';
import { KEYBOARD_HEIGHT_VP, MAX_PANEL_HEIGHT_RATIO } from './KeyboardMetrics';

const DOMAIN: number = 0x0000;
const TAG: string = 'RimeImeExtension';

/** Page that provides the soft-keyboard UI inside the panel. */
const KEYBOARD_PAGE: string = 'pages/KeyboardPanel';

export default class RimeInputMethodExtension extends InputMethodExtensionAbility {
  // `context` is inherited from InputMethodExtensionAbility as an
  // InputMethodExtensionContext; do not shadow it.
  private hub: KeyboardHub = KeyboardHub.getInstance();
  private engine: RimeEngineService = RimeEngineService.getInstance();
  private panel: inputMethodEngine.Panel | null = null;
  private panelReady: boolean = false;
  private listenersRegistered: boolean = false;

  /**
   * True between inputStart and inputStop.
   *
   * The panel is created asynchronously, and inputStart can arrive first (the
   * IME is often launched because an editor already has focus).  Remembering the
   * state lets the panel be shown as soon as it becomes ready instead of
   * silently staying hidden.
   */
  private editorBound: boolean = false;

  // Handles of the common-event subscription created by setUpConfigHandoff();
  // held for as long as the extension lives.
  private configHandoffHandles: Handles | null = null;

  /**
   * Receives a configuration folder picked by the settings page.
   *
   * The settings page runs in the app process, outside the keyboard's sandbox,
   * so the files it picks are useless to librime there; only the document URI
   * travels over a common event, and the copy into the keyboard's own data
   * directory happens here.
   *
   * A request is published as well: common events are not sticky for
   * third-party apps, so a keyboard that starts after the settings page sent the
   * URI would otherwise never hear about it.
   */
  private setUpConfigHandoff(): void {
    ConfigHandoff.onUri((uri: string) => {
      this.applyHandedOffConfig(uri);
    });
    ConfigHandoff.listen().then((handles: Handles) => {
      this.configHandoffHandles = handles;
      // Now that we are listening, ask whoever is holding a folder to resend it.
      ConfigHandoff.requestUri();
    });
  }

  private applyHandedOffConfig(uri: string): void {
    // The engine remembers the last URI it imported, so a re-send of the same
    // folder (the request/reply round trip in ConfigHandoff can cause one) is
    // answered without copying every file again.
    if (this.engine.hasImportedUri(uri)) {
      AppLog.info(TAG, `already imported this folder, skipping the copy: ${uri}`);
      ConfigHandoff.publishDone();
      return;
    }

    AppLog.info(TAG, `applying handed-off configuration: ${uri}`);
    this.engine.importFromUri(uri, () => {
      // No progress UI on this path: the keyboard's settings panel only renders
      // progress for imports it starts itself.
    }).then((outcome: FolderImportOutcome) => {
      AppLog.info(TAG, `handed-off import finished: ${outcome.copied} files`);
      ConfigHandoff.publishDone();
    }).catch((error: Object) => {
      AppLog.exception(TAG, 'handed-off import failed', error);
    });
  }

  private readonly onInputStart = (controller: inputMethodEngine.KeyboardController,
                                   client: inputMethodEngine.InputClient): void => {
    hilog.info(DOMAIN, TAG, 'inputStart');
    this.editorBound = true;
    // Pick up any deployment the app's settings page performed since the
    // keyboard was last used (it may run in a different process).
    this.engine.syncExternalConfig();
    this.hub.attach(controller, client);
    this.showPanel();
  };

  private readonly onInputStop = (): void => {
    hilog.info(DOMAIN, TAG, 'inputStop');
    this.editorBound = false;
    this.hub.detach();
    this.hidePanel();
  };

  private readonly onKeyboardShow = (): void => {
    hilog.info(DOMAIN, TAG, 'keyboardShow');
  };

  private readonly onKeyboardHide = (): void => {
    hilog.info(DOMAIN, TAG, 'keyboardHide');
  };

  private readonly onSetSubtype = (subtype: InputMethodSubtype): void => {
    hilog.info(DOMAIN, TAG, 'subtype changed to %{public}s', subtype.id);
    this.applySubtype(subtype);
  };

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'onCreate');

    this.setUpConfigHandoff();
    this.engine.bootstrap(this.context)
      .then(() => {
        hilog.info(DOMAIN, TAG, 'Rime engine bootstrapped');
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'engine bootstrap failed: %{public}s', error.message);
      });

    this.registerInputMethodListeners();
    this.createPanel();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    this.unregisterInputMethodListeners();
    this.hub.detach();
    this.editorBound = false;

    const panel: inputMethodEngine.Panel | null = this.panel;
    if (panel !== null) {
      inputMethodEngine.getInputMethodAbility()
        .destroyPanel(panel)
        .catch((error: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'destroyPanel failed: %{public}s', error.message);
        });
      this.panel = null;
      this.panelReady = false;
    }
  }

  // -------------------------------------------------------------------------
  // panel
  // -------------------------------------------------------------------------

  /**
   * Creates the fixed soft-keyboard panel, sizes it and loads the keyboard page.
   *
   * The panel is not shown here: show() is only valid once the IME is bound to
   * an edit box, which is what the inputStart callback signals.
   */
  private createPanel(): void {
    const ability: inputMethodEngine.InputMethodAbility =
      inputMethodEngine.getInputMethodAbility();

    const panelInfo: inputMethodEngine.PanelInfo = {
      type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
      flag: inputMethodEngine.PanelFlag.FLG_FIXED
    };

    ability.createPanel(this.context, panelInfo)
      .then(async (panel: inputMethodEngine.Panel) => {
        hilog.info(DOMAIN, TAG, 'panel created');
        this.panel = panel;
        await this.resizePanel(panel);
        await this.loadKeyboardUi(panel);
        this.panelReady = true;
        hilog.info(DOMAIN, TAG, 'keyboard panel ready');

        // The editor may already have focus from before the panel existed.
        if (this.editorBound) {
          await this.showPanelAsync();
        }
      })
      .catch((error: BusinessError) => {
        this.panelReady = false;
        hilog.error(DOMAIN, TAG,
                    'failed to create keyboard panel: code=%{public}d msg=%{public}s',
                    error.code, error.message);
      });
  }

  /**
   * Gives the panel window a concrete size.
   *
   * resize() takes px while the keyboard page is laid out in vp, so the page
   * height is converted with the display density.  The width is the full screen
   * width; the height is capped at the share of the screen the platform accepts.
   */
  private async resizePanel(panel: inputMethodEngine.Panel): Promise<void> {
    try {
      const displayInfo: display.Display = display.getDefaultDisplaySync();

      // The keyboard page has a fixed height in vp; resize() wants px.
      const densityPixels: number = displayInfo.densityPixels > 0 ? displayInfo.densityPixels : 1;
      const wantedHeightPx: number = Math.round(KEYBOARD_HEIGHT_VP * densityPixels);
      // The platform rejects panels taller than a fixed share of the screen.
      const maxPanelHeightPx: number = Math.round(displayInfo.height * MAX_PANEL_HEIGHT_RATIO);
      const panelHeightPx: number = Math.min(wantedHeightPx, maxPanelHeightPx);
      const panelWidthPx: number = Math.round(displayInfo.width);

      hilog.info(DOMAIN, TAG,
                 'resizing panel to %{public}dx%{public}d px (wanted %{public}d, ceiling %{public}d, density %{public}f)',
                 panelWidthPx, panelHeightPx, wantedHeightPx, maxPanelHeightPx, densityPixels);
      await panel.resize(panelWidthPx, panelHeightPx);
    } catch (error) {
      // Not fatal: the page sets its own height, so a refused resize only
      // changes how much of it the panel window clips.
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'panel resize failed: code=%{public}d msg=%{public}s',
                 err.code, err.message);
    }
  }

  /**
   * Loads the keyboard page into the panel.
   *
   * No LocalStorage is passed: the page runs in this same process and gets the
   * engine from the RimeEngineService singleton, so no state has to cross the
   * panel boundary from the extension.
   */
  private async loadKeyboardUi(panel: inputMethodEngine.Panel): Promise<void> {
    try {
      await panel.setUiContent(KEYBOARD_PAGE);
      hilog.info(DOMAIN, TAG, 'keyboard UI loaded');
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'setUiContent failed: code=%{public}d msg=%{public}s',
                  err.code, err.message);
    }
  }

  /** Fire-and-forget wrapper used from synchronous callbacks. */
  private showPanel(): void {
    this.showPanelAsync().catch((error: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'showPanel failed: %{public}s', error.message);
    });
  }

  private async showPanelAsync(): Promise<void> {
    const panel: inputMethodEngine.Panel | null = this.panel;
    if (panel === null || !this.panelReady) {
      hilog.info(DOMAIN, TAG, 'showPanel skipped (panel not ready yet)');
      return;
    }
    try {
      await panel.show();
      hilog.info(DOMAIN, TAG, 'panel shown');
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'panel.show failed: code=%{public}d msg=%{public}s',
                 err.code, err.message);
    }
  }

  private hidePanel(): void {
    const panel: inputMethodEngine.Panel | null = this.panel;
    if (panel === null) {
      return;
    }
    panel.hide().catch((error: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'panel.hide failed: code=%{public}d msg=%{public}s',
                 error.code, error.message);
    });
  }

  // -------------------------------------------------------------------------
  // input focus
  // -------------------------------------------------------------------------

  private registerInputMethodListeners(): void {
    if (this.listenersRegistered) {
      return;
    }
    const ability: inputMethodEngine.InputMethodAbility =
      inputMethodEngine.getInputMethodAbility();

    ability.on('inputStart', this.onInputStart);
    ability.on('inputStop', this.onInputStop);
    ability.on('keyboardShow', this.onKeyboardShow);
    ability.on('keyboardHide', this.onKeyboardHide);
    ability.on('setSubtype', this.onSetSubtype);

    this.listenersRegistered = true;
  }

  private unregisterInputMethodListeners(): void {
    if (!this.listenersRegistered) {
      return;
    }
    const ability: inputMethodEngine.InputMethodAbility =
      inputMethodEngine.getInputMethodAbility();

    ability.off('inputStart', this.onInputStart);
    ability.off('inputStop', this.onInputStop);
    ability.off('keyboardShow', this.onKeyboardShow);
    ability.off('keyboardHide', this.onKeyboardHide);
    ability.off('setSubtype', this.onSetSubtype);

    this.listenersRegistered = false;
  }

  /**
   * Maps the declared subtypes (see resources/base/profile/input_method_config.json)
   * onto engine state.  "rime_en" switches Rime into ASCII mode rather than
   * selecting a different schema, because the shipped schemas cover both.
   */
  private applySubtype(subtype: InputMethodSubtype): void {
    if (subtype.id === 'rime_en') {
      if (!this.engine.isAsciiMode()) {
        this.engine.toggleAsciiMode();
      }
      return;
    }
    if (subtype.id === 'rime_cn_pinyin' && this.engine.isAsciiMode()) {
      this.engine.toggleAsciiMode();
    }
  }
}
