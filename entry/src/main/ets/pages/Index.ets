/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Companion page for the Rime input method.
 *
 * An input method is configured from the system settings, but a small app-side
 * page is useful for the things users need to check or trigger manually:
 * whether the engine deployed successfully, the librime version, which schemas
 * are installed, how to enable the keyboard, how to hand a configuration
 * folder or patch files to the keyboard, and the licence texts bundled in the
 * HAP.
 */

import { bundleManager, common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { inputMethod } from '@kit.IMEKit';

import rime from 'libentry.so';
import { AppLog } from '../common/AppLog';
import { ConfigHandoff, Handles } from '../common/ConfigHandoff';
import { VERSION_LABEL } from '../common/AppInfo';
import {
  HDColor, HDRadius, HDSize, HDSpace, HDSurface, HDText, HDType
} from '../common/HarmonyDesign';
import { RimeEngineService } from '../inputmethod/RimeEngineService';
import {
  RimeConfigStore,
  UserConfigFile,
  ImportOutcome,
  ImportProgress,
  FolderImportOutcome
} from '../inputmethod/RimeConfigStore';
import { RimePaths } from '../inputmethod/RimePaths';

/** One upstream project credited on the about page. */
interface Credit {
  name: string;
  author: string;
  license: string;
  /** What this project actually takes from it. */
  usage: string;
}

/**
 * Upstream projects this app is built on or learned from.
 *
 * Listed with the licence each is distributed under, because that is the
 * attribution those licences require, and with what was actually taken -- a
 * blanket "thanks to open source" would not tell a reader which parts are whose.
 */
const CREDITS: Credit[] = [
  {
    name: 'librime',
    author: 'RIME Developers',
    license: 'BSD-3-Clause',
    usage: '输入法引擎：方案、词典、候选、部署'
  },
  {
    name: 'librime-lua',
    author: 'librime-lua Developers',
    license: 'BSD-3-Clause',
    usage: 'Rime 方案的 Lua 脚本支持'
  },
  {
    name: 'librime-octagram',
    author: 'RIME Developers',
    license: 'BSD-3-Clause',
    usage: '语法模型（.gram）支持'
  },
  {
    name: 'fcitx5-android',
    author: 'Fcitx5 for Android Contributors',
    license: 'LGPL-2.1',
    usage: '键盘布局、配色与交互设计参考'
  },
  {
    name: 'fcitx5',
    author: 'Fcitx Contributors',
    license: 'LGPL-2.1',
    usage: '输入法框架架构参考'
  },
  {
    name: 'OpenCC',
    author: 'BYVoid 与贡献者',
    license: 'Apache-2.0',
    usage: '简繁转换与 Emoji 转换数据'
  },
  {
    name: 'Lua',
    author: 'Lua.org, PUC-Rio',
    license: 'MIT',
    usage: '脚本语言运行时'
  },
  {
    name: 'glog / leveldb / yaml-cpp / marisa-trie',
    author: 'Google / Jesse Beder / やた',
    license: 'BSD-3 / BSD-3 / MIT / BSD-2',
    usage: '日志、用户词典存储、配置解析、Trie'
  },
  {
    name: 'Boost',
    author: 'Boost 社区',
    license: 'BSL-1.0',
    usage: '正则表达式'
  },
  {
    name: 'rime-ice 雾凇拼音等方案',
    author: '各方案作者',
    license: '各自许可证',
    usage: '用户可自行导入的输入方案与语言模型'
  }
];

const DOMAIN: number = 0x0000;
const TAG: string = 'IndexPage';

interface SchemaRow {
  schemaId: string;
  name: string;
}

@Entry
@Component
struct Index {
  @State engineVersion: string = '';
  @State engineReady: boolean = false;
  @State deploying: boolean = false;
  @State engineMessage: string = '';
  @State schemas: SchemaRow[] = [];

  // Input-method registration diagnostics.  A keyboard that never appears is
  // almost always an IME that the system has not registered or the user has not
  // enabled, so surface that state explicitly.
  @State imeRegistered: boolean = false;
  @State imeEnabled: boolean = false;
  @State imeNames: string[] = [];

  // User-supplied Rime configuration.
  @State configDir: string = '';
  @State configFiles: UserConfigFile[] = [];
  @State configMessage: string = '';
  /** Shared data directory, the one librime reads the bundled schemas from. */
  @State sharedDir: string = '';

  // Whole-folder import: armed until the user confirms, because it replaces
  // the bundled schemas.
  /** Whether the AI-participation disclosure is expanded. */
  @State disclaimerOpen: boolean = false;
  @State importArmed: boolean = false;
  /** 'BASIC' | 'FULL' | 'unknown(...)'; see RimeEngineService.getSecurityMode(). */
  @State securityMode: string = '';
  /**
   * The folder this page picked last.  Also loaded from disk at startup, so a
   * keyboard that starts later can still ask for it.
   */
  private pendingFolderUri: string = '';
  private requestHandles: Handles | null = null;
  /** Diagnostics window state.  `logTick` forces a re-render when AppLog changes. */
  @State diagnosticsOpen: boolean = false;
  @State logTick: number = 0;
  @State importing: boolean = false;
  @State importProgress: string = '';

  // Licence viewer.  Apache-2.0 and the BSD variants require the notices to
  // accompany the distributed binary, and a HAP's rawfile is the only place they
  // can live -- so they are also shown here, where a user can actually read them.
  @State licensesOpen: boolean = false;
  @State licenseNames: string[] = [];
  @State licenseName: string = '';
  @State licenseText: string = '';

  private engine: RimeEngineService = RimeEngineService.getInstance();
  // startAbility() lives on UIAbilityContext, not on the base Context.
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private appLogListener: () => void = () => {
    // Bumping a state counter is what makes the open window re-render when new
    // entries arrive.
    this.logTick++;
  };

  aboutToAppear(): void {
    AppLog.subscribe(this.appLogListener);
    AppLog.info(TAG, `=== ${VERSION_LABEL} ===`);
    // Answer the keyboard when it asks for the folder: common events are not
    // sticky, so a keyboard that started after the pick would never see it.
    this.pendingFolderUri = ConfigHandoff.loadPendingUri(this.context);
    if (this.pendingFolderUri.length > 0) {
      AppLog.info(TAG, `restored pending uri: ${this.pendingFolderUri}`);
    }
    ConfigHandoff.listenForRequest(() => {
      if (this.pendingFolderUri.length > 0) {
        AppLog.info(TAG, `resending pending uri to keyboard: ${this.pendingFolderUri}`);
        ConfigHandoff.publishUri(this.pendingFolderUri);
      } else {
        AppLog.info(TAG, 'keyboard asked for a folder, but none has been picked yet');
      }
    }).then((handles: Handles) => {
      this.requestHandles = handles;
    });
    this.detectInputMethod();
    this.refreshConfig();
    this.startEngine();
  }

  aboutToDisappear(): void {
    AppLog.unsubscribe(this.appLogListener);
    ConfigHandoff.release(this.requestHandles);
    this.requestHandles = null;
  }

  /** Copies the whole buffer so it can be pasted into a bug report. */
  private copyLogToClipboard(): void {
    const text: string = `${VERSION_LABEL}\n${AppLog.asText()}`;
    try {
      const data: pasteboard.PasteData = pasteboard.createPlainTextData(text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      AppLog.info(TAG, 'log copied to clipboard');
      this.logTick++;
    } catch (error) {
      AppLog.exception(TAG, 'copyLog failed', error);
    }
  }

  /**
   * Honest disclosure about how this project was produced.
   *
   * Kept collapsed but always visible: the notice matters most to someone who
   * has just installed an input method, and an input method sees every
   * keystroke in every other app, so the risk is not abstract.  Collapsing it
   * keeps the settings page usable while making sure it is never missed.
   */
  @Builder
  AiDisclaimerCard() {
    Column() {
      Row() {
        Text('\u26A0\uFE0F 重要声明')
          .fontSize(HDType.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(HDColor.warning)
          .layoutWeight(1)
        Text(this.disclaimerOpen ? '收起' : '展开')
          .fontSize(HDType.caption)
          .fontColor(HDColor.warning)
          .onClick(() => {
            this.disclaimerOpen = !this.disclaimerOpen;
          })
      }
      .width('100%')

      Text('作者为高三在读学生，本项目大量使用 AI 辅助生成，代码可靠性与安全性存疑。')
        .fontSize(HDType.caption)
        .fontColor(HDColor.warning)
        .width('100%')
        .margin({ top: 6 })

      if (this.disclaimerOpen) {
        Text('受学业时间限制，项目有AI大量参与，包括C++ 原生层、UI界面、构建脚本与文档，整体代码架构由人工完成。并且作者只会Java，几乎不会C++（不嘻嘻）\n\n' +
             '· 代码未经系统性安全审计\n' +
             '· 学习与借鉴时请自行甄别\n' +
             '· 不建议用于生产环境或处理敏感信息\n\n' +
             '尤其注意：这是一个输入法。启用后它会接触到你在其他所有应用中的按键输入，' +
             '请充分评估风险后再决定是否启用。\n\n' +
             '作者承诺：2027 年高考结束后，将对项目中所有涉及 AI 生成的内容进行系统性审查' +
             '或重构，以保证其安全性。在此之前，请把本项目视为学习与实验用途。')
          .fontSize(HDType.caption)
          .fontColor(HDColor.warning)
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDColor.warningTint)
    .borderRadius(HDRadius.large)
    .margin({ bottom: 12 })
  }

  /**
   * Explains the one setting that decides whether importing can work at all.
   *
   * In its basic mode HarmonyOS treats an input method as a pure typing tool: the
   * extension may not read files outside its own sandbox, so neither the imported
   * configuration nor a picked folder URI is reachable.  Only the user can change
   * this, from the system settings, so the app's job is to say so plainly.
   */
  @Builder
  SecurityModeBanner() {
    if (this.securityMode === 'BASIC') {
      Column() {
        Text('⚠ 当前为「基础模式」，导入配置不会生效')
          .fontSize(HDType.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(HDColor.warning)
          .width('100%')
          .margin({ bottom: 6 })
        Text('基础模式下系统禁止输入法读取沙箱外的文件，因此导入的配置永远到不了键盘。\n' +
             '请前往：设置 → 系统 → 输入法 → 选择本输入法 → 打开「完整体验模式」，然后重新导入。')
          .fontSize(HDType.caption)
          .fontColor(HDColor.warning)
          .width('100%')
      }
      .width('100%')
      .padding(HDSpace.lg)
      .backgroundColor(HDColor.warningTint)
      .borderRadius(HDRadius.large)
      .margin({ bottom: 12 })
    } else if (this.securityMode === 'FULL') {
      Text(`运行模式：完整体验模式（securityMode=${this.securityMode}）`)
        .fontSize(HDType.caption)
        .fontColor(HDColor.success)
        .width('100%')
        .padding({ left: 4, bottom: 8 })
    } else if (this.securityMode.length > 0) {
      Text(`运行模式：无法获取（${this.securityMode}）`)
        .fontSize(HDType.caption)
        .fontColor(HDText.tertiary)
        .width('100%')
        .padding({ left: 4, bottom: 8 })
    }
  }

  /**
   * Diagnostics log, always present in the page.
   *
   * Collapsed it is one row with the error count and an expand toggle; opened it
   * lists every recorded message, with buttons to copy or clear them.  This
   * exists because the device's hilog cannot be read back by the user, so a
   * failure would otherwise be invisible.
   */
  @Builder
  DiagnosticsCard() {
    Column() {
      Row() {
        Text('诊断')
          .fontSize(HDType.body)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        if (AppLog.errorCount() > 0) {
          Text(`${AppLog.errorCount()}`)
            .fontSize(HDType.caption)
            .fontColor(HDText.onAccent)
            .backgroundColor(HDColor.warning)
            .borderRadius(9)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .margin({ right: 8 })
        }
        Text(this.diagnosticsOpen ? '收起' : '展开')
          .fontSize(HDType.caption)
          .fontColor(HDColor.brand)
          .onClick(() => {
            this.diagnosticsOpen = !this.diagnosticsOpen;
            this.logTick++;
          })
      }
      .width('100%')
      .height(HDSize.headerHeight)

      if (this.diagnosticsOpen) {
        Row({ space: 8 }) {
          Button('复制全部')
            .fontSize(HDType.caption)
            .layoutWeight(1)
            .height(HDSize.buttonHeight)
            .borderRadius(HDRadius.medium)
            .onClick(() => {
              this.copyLogToClipboard();
            })
          Button('清空')
            .fontSize(HDType.caption)
            .layoutWeight(1)
            .height(HDSize.buttonHeight)
            .borderRadius(HDRadius.medium)
            .backgroundColor(HDColor.buttonTonal)
            .fontColor(HDText.primary)
            .onClick(() => {
              AppLog.clear();
              this.logTick++;
            })
        }
        .width('100%')
        .margin({ top: 4, bottom: 8 })

        // Selectable so individual lines can be copied by hand if the clipboard
        // call is refused.
        Scroll() {
          Text(AppLog.asText())
            .fontSize(HDType.footnote)
            .fontColor(HDText.primary)
            .fontFamily('monospace')
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .height(240)
        .width('100%')
        .padding(8)
        .backgroundColor(HDSurface.sunken)
        .borderRadius(HDRadius.medium)
      }
    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDSurface.card)
    .borderRadius(HDRadius.large)
    .margin({ bottom: 12 })
  }

  /**
   * Reports whether the system knows this IME and whether the user has enabled
   * it, which separates "the app is not installed or registered" from "the
   * keyboard just has not been switched on yet".
   */
  private detectInputMethod(): void {
    const bundleName: string = this.context.abilityInfo.bundleName;
    try {
      const imeSetting: inputMethod.InputMethodSetting = inputMethod.getSetting();
      const enabled: inputMethod.InputMethodProperty[] = imeSetting.getInputMethodsSync(true);
      const installed: inputMethod.InputMethodProperty[] = imeSetting.getInputMethodsSync(false);

      const enabledNames: string[] = [];
      let registered: boolean = false;
      let switchedOn: boolean = false;

      for (const ime of installed) {
        if (ime.name.indexOf(bundleName) === 0) {
          registered = true;
        }
      }
      for (const ime of enabled) {
        enabledNames.push(ime.label !== undefined ? ime.label : ime.name);
        if (ime.name.indexOf(bundleName) === 0) {
          switchedOn = true;
        }
      }

      this.imeRegistered = registered;
      this.imeEnabled = switchedOn;
      this.imeNames = enabledNames;
      hilog.info(DOMAIN, TAG,
                 'IME diagnostics: bundle=%{public}s registered=%{public}s enabled=%{public}s',
                 bundleName, String(registered), String(switchedOn));
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'detectInputMethod failed: %{public}s', err.message);
    }
  }

  /** Opens the system picker so the user can switch to this keyboard. */
  private showInputMethodPicker(): void {
    inputMethod.getSetting().showOptionalInputMethods()
      .then((shown: boolean) => {
        hilog.info(DOMAIN, TAG, 'picker shown: %{public}s', String(shown));
      })
      .catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'showOptionalInputMethods failed: %{public}s', error.message);
      });
  }

  // -------------------------------------------------------------------------
  // user configuration and engine state
  // -------------------------------------------------------------------------

  private refreshConfig(): void {
    this.configDir = RimeConfigStore.ensureUserDir(this.context.filesDir);
    this.configFiles = RimeConfigStore.list(this.context.filesDir);
    this.securityMode = this.engine.getSecurityMode();
    const paths: RimePaths | null = this.engine.getPaths();
    this.sharedDir = paths !== null ? paths.sharedDataDir : '';
    if (paths !== null) {
      hilog.info(DOMAIN, TAG, 'settings page sees shared=%{public}s user=%{public}s',
                 paths.sharedDataDir, paths.userDataDir);
    }
  }

  /**
   * Asks the user to confirm replacing the bundled schemas with a picked
   * folder; the picker itself waits for that confirmation.
   */
  private requestFolderImport(): void {
    if (this.importing || this.sharedDir.length === 0) {
      return;
    }
    this.importArmed = true;
    this.configMessage = '将用所选文件夹替换内置方案：先清空内置方案目录再整体复制，' +
      '未包含的内置文件不会保留。';
  }

  private cancelFolderImport(): void {
    this.importArmed = false;
    this.importProgress = '';
    this.configMessage = '';
  }

  private confirmFolderImport(): void {
    if (this.importing || this.sharedDir.length === 0) {
      return;
    }
    this.importArmed = false;
    this.importing = true;
    this.importProgress = '正在读取文件夹…';
    this.configMessage = '';

    // The settings page only picks the folder; the input method extension does
    // the copying, because it is a separate process with its own sandbox and
    // owns the data directory librime reads.
    RimeConfigStore.pickFolder(this.context)
      .then((uri: string | null) => {
        this.importing = false;
        this.importProgress = '';
        if (uri === null) {
          this.configMessage = '未选择文件夹';
          return;
        }
        this.pendingFolderUri = uri;
        // Published now for a keyboard that is already running, and written to
        // disk so this page can resend it when the keyboard asks after starting.
        ConfigHandoff.savePendingUri(this.context, uri);
        ConfigHandoff.publishUri(uri);
        this.configMessage = '已选择文件夹。请打开一次键盘，它会接收并导入（可在键盘的' +
          '「方案设置 → 诊断」中查看进度）。';
        this.refreshEngineState();
      })
      .catch((error: BusinessError) => {
        this.importing = false;
        this.importProgress = '';
        hilog.error(DOMAIN, TAG, 'folder pick failed: %{public}s', error.message);
        AppLog.exception(TAG, 'pickFolder failed', error);
        this.configMessage = `选择文件夹失败：${error.message}`;
      });
  }

  /** Throws away imported schemas and extracts the bundled ones again. */
  private restoreBundledConfig(): void {
    if (this.importing || this.sharedDir.length === 0) {
      return;
    }
    this.importing = true;
    this.configMessage = '';
    this.importProgress = '正在恢复内置配置…';

    RimeConfigStore.restoreBundled(this.context, this.sharedDir)
      .then(() => {
        this.importing = false;
        this.importProgress = '';
        this.configMessage = '已恢复内置配置，正在重新部署…';
        this.engine.redeploy();
        this.refreshEngineState();
      })
      .catch((error: BusinessError) => {
        this.importing = false;
        this.importProgress = '';
        hilog.error(DOMAIN, TAG, 'restore failed: %{public}s', error.message);
        this.configMessage = `恢复失败：${error.message}`;
      });
  }

  /**
   * Copies files chosen in the system picker into the Rime user directory.
   *
   * Any name RimeConfigStore.isConfigFile() accepts is taken -- .yaml, .yml,
   * .txt, .dict and .json, not only *.custom.yaml patches.  Rime only reads
   * customisation at deployment time, so a successful import is followed by a
   * redeploy; otherwise the user would see their files listed but nothing would
   * change.
   */
  private importPatchFiles(): void {
    RimeConfigStore.pickAndImport(this.context)
      .then((outcome: ImportOutcome) => {
        this.refreshConfig();
        if (outcome.imported.length === 0) {
          this.configMessage = outcome.skipped.length > 0
            ? '没有导入任何文件（文件名或类型不被接受）'
            : '未选择文件';
          return;
        }
        this.configMessage = `已导入 ${outcome.imported.length} 个文件` +
          (outcome.skipped.length > 0 ? `，跳过 ${outcome.skipped.length} 个` : '') +
          '，正在重新部署…';
        this.engine.redeploy();
        this.refreshEngineState();
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'import failed: %{public}s', error.message);
        this.configMessage = `导入失败：${error.message}`;
      });
  }

  private removeConfigFile(name: string): void {
    if (RimeConfigStore.remove(this.context.filesDir, name)) {
      this.refreshConfig();
      this.configMessage = `已删除 ${name}，重新部署后生效`;
      this.engine.redeploy();
      this.refreshEngineState();
    } else {
      this.configMessage = `无法删除 ${name}`;
    }
  }

  private startEngine(): void {
    this.engine.bootstrap(this.context)
      .then(() => {
        this.refreshEngineState();
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', error.message);
        this.engineMessage = `引擎启动失败: ${error.message}`;
      });
  }

  private refreshEngineState(): void {
    this.refreshConfig();
    this.engineVersion = this.engine.getVersion();
    this.engineReady = this.engine.isReady();
    this.deploying = this.engine.isDeploying();
    this.schemas = this.engine.getSchemaList().map((item: rime.RimeSchemaItem) => {
      const row: SchemaRow = { schemaId: item.schemaId, name: item.name };
      return row;
    });
  }

  build() {
    Stack() {
      this.PageBody()
      if (this.licensesOpen) {
        this.LicenseViewer()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  PageBody() {
    Scroll() {
      Column() {
      Text($r('app.string.ime_label'))
        .fontSize(HDType.title)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 24, bottom: 4 })

      Text(VERSION_LABEL)
        .fontSize(HDType.caption)
        .fontColor(HDText.tertiary)
        .margin({ bottom: 20 })

      this.AiDisclaimerCard()
      this.SecurityModeBanner()
      this.DiagnosticsCard()
      this.InputMethodStatusCard()
      this.CustomConfigCard()
      this.EngineStatusCard()
      this.SchemaListCard()
      this.EnableInputMethodCard()
      this.AboutCard()
      this.LicenseCard()
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
  }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .backgroundColor(HDSurface.page)
  }

  @Builder
  InputMethodStatusCard() {
    Column() {
      Row() {
        Text('输入法状态')
          .fontSize(HDType.body)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text(this.imeEnabled ? '已启用' : (this.imeRegistered ? '未启用' : '未注册'))
          .fontSize(HDType.caption)
          .fontColor(this.imeEnabled ? HDColor.success : HDColor.warning)
      }
      .width('100%')

      Text(this.imeEnabled
        ? '系统已启用本输入法。在任意输入框中长按并切换即可使用。'
        : (this.imeRegistered
          ? '系统已识别本输入法，但尚未启用。请点击下方按钮启用。'
          : '系统尚未识别本输入法。请确认已安装本应用，然后重新启动应用或设备。'))
        .fontSize(HDType.caption)
        .fontColor(HDText.secondary)
        .width('100%')
        .margin({ top: 8 })

      if (this.imeNames.length > 0) {
        Text(`已启用的输入法：${this.imeNames.join('、')}`)
          .fontSize(HDType.footnote)
          .fontColor(HDText.tertiary)
          .width('100%')
          .margin({ top: 6 })
      }

    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDSurface.card)
    .borderRadius(HDRadius.large)
    .margin({ bottom: 12 })
  }

  @Builder
  CustomConfigCard() {
    Column() {
      Text('自定义配置')
        .fontSize(HDType.body)
        .fontWeight(FontWeight.Medium)
        .width('100%')

      // ---- whole configuration bundles --------------------------------
      Text('完整配置包')
        .fontSize(HDType.caption)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ top: 10 })

      // Input method extensions have their own data sandbox on HarmonyOS, and
      // their context cannot open the picker, so this page only selects the
      // folder and hands the URI to the keyboard, which does the copying.
      Text('注意：输入法扩展是独立沙箱。这里只负责选择文件夹，' +
           '真正的复制由键盘完成。选好后请打开一次键盘，它会自动接收并导入。')
        .fontSize(HDType.caption)
        .fontColor(HDColor.warning)
        .width('100%')
        .margin({ bottom: 8 })

      Text('选择包含 default.yaml、*.schema.yaml、*.dict.yaml、*.gram 等文件的文件夹。' +
           '导入会先清空内置方案目录再整体复制，未包含的文件不会保留；' +
           '如需还原可使用「恢复内置配置」。')
        .fontSize(HDType.caption)
        .fontColor(HDText.secondary)
        .width('100%')
        .margin({ top: 4 })

      Text(this.sharedDir.length > 0 ? `方案目录：${this.sharedDir}` : '引擎尚未就绪')
        .fontSize(HDType.footnote)
        .fontColor(HDText.tertiary)
        .width('100%')
        .padding(8)
        .margin({ top: 8 })
        .backgroundColor(HDSurface.page)
        .borderRadius(HDRadius.medium)
        .copyOption(CopyOptions.LocalDevice)

      if (this.importing) {
        Text(this.importProgress)
          .fontSize(HDType.caption)
          .fontColor(HDColor.brand)
          .width('100%')
          .margin({ top: 10 })
      } else if (this.importArmed) {
        Text('这会覆盖内置方案，确定继续吗？')
          .fontSize(HDType.caption)
          .fontColor(HDColor.warning)
          .width('100%')
          .margin({ top: 10 })
        Row({ space: 12 }) {
          Button('确定导入')
            .fontSize(HDType.body)
            .backgroundColor(HDColor.warning)
            .layoutWeight(1)
            .onClick(() => {
              this.confirmFolderImport();
            })
          Button('取消')
            .fontSize(HDType.body)
            .backgroundColor(HDText.tertiary)
            .layoutWeight(1)
            .onClick(() => {
              this.cancelFolderImport();
            })
        }
        .width('100%')
        .margin({ top: 8 })
      } else {
        Row({ space: 12 }) {
          Button('导入配置文件夹')
            .fontSize(HDType.body)
            .layoutWeight(1)
            .onClick(() => {
              this.requestFolderImport();
            })
          Button('恢复内置配置')
            .fontSize(HDType.body)
            .backgroundColor(HDText.tertiary)
            .layoutWeight(1)
            .onClick(() => {
              this.restoreBundledConfig();
            })
        }
        .width('100%')
        .margin({ top: 10 })
      }

      if (this.configMessage.length > 0) {
        Text(this.configMessage)
          .fontSize(HDType.caption)
          .fontColor(HDColor.brand)
          .width('100%')
          .margin({ top: 8 })
      }

      Divider()
        .color(HDSurface.divider)
        .margin({ top: 14, bottom: 10 })

      // ---- individual patches -----------------------------------------
      Text('自定义补丁')
        .fontSize(HDType.caption)
        .fontWeight(FontWeight.Medium)
        .width('100%')

      Text('把 *.custom.yaml 等补丁文件放进下面的目录，导入后自动重新部署。')
        .fontSize(HDType.caption)
        .fontColor(HDText.secondary)
        .width('100%')
        .margin({ top: 4 })

      Text(this.configDir)
        .fontSize(HDType.footnote)
        .fontColor(HDText.primary)
        .width('100%')
        .padding(8)
        .margin({ top: 8 })
        .backgroundColor(HDSurface.page)
        .borderRadius(HDRadius.medium)
        .copyOption(CopyOptions.LocalDevice)

      Row({ space: 12 }) {
        Button('导入补丁文件')
          .fontSize(HDType.body)
          .layoutWeight(1)
          .onClick(() => {
            this.importPatchFiles();
          })
        Button('刷新列表')
          .fontSize(HDType.body)
          .backgroundColor(HDText.tertiary)
          .layoutWeight(1)
          .onClick(() => {
            this.refreshConfig();
          })
      }
      .width('100%')
      .margin({ top: 10 })

      if (this.configFiles.length === 0) {
        Text('暂无自定义补丁。')
          .fontSize(HDType.caption)
          .fontColor(HDText.tertiary)
          .width('100%')
          .margin({ top: 10 })
      } else {
        ForEach(this.configFiles, (file: UserConfigFile) => {
          Row() {
            Column() {
              Text(file.name)
                .fontSize(HDType.body)
                .fontColor(HDText.primary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(file.isCustomPatch
                ? '补丁文件'
                : (file.isRimeGenerated ? 'Rime 生成' : this.formatFileSize(file.sizeBytes)))
                .fontSize(HDType.mono)
                .fontColor(file.isRimeGenerated ? HDColor.warning : HDText.tertiary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('删除')
              .fontSize(HDType.caption)
              .fontColor(HDColor.warning)
              .padding({ left: 12, right: 4, top: 6, bottom: 6 })
              .onClick(() => {
                this.removeConfigFile(file.name);
              })
          }
          .width('100%')
          .padding({ top: HDSize.rowHeight / 4, bottom: HDSize.rowHeight / 4 })

          Divider()
            .color(HDSurface.divider)
            .strokeWidth(0.5)
        }, (file: UserConfigFile) => `${file.name}-${file.modifiedMs}`)
      }
    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDSurface.card)
    .borderRadius(HDRadius.large)
    .margin({ bottom: 12 })
  }

  private formatFileSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  @Builder
  EngineStatusCard() {
    Column() {
      Row() {
        Text('引擎状态')
          .fontSize(HDType.body)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text(this.engineReady ? '就绪' : (this.deploying ? '部署中' : '未就绪'))
          .fontSize(HDType.caption)
          .fontColor(this.engineReady ? HDColor.success : HDColor.warning)
      }
      .width('100%')

      if (this.engineVersion.length > 0) {
        Row() {
          Text('librime 版本')
            .fontSize(HDType.caption)
            .fontColor(HDText.secondary)
            .layoutWeight(1)
          Text(this.engineVersion)
            .fontSize(HDType.caption)
            .fontColor(HDText.primary)
        }
        .width('100%')
        .margin({ top: 8 })
      }

      if (this.engineMessage.length > 0) {
        Text(this.engineMessage)
          .fontSize(HDType.caption)
          .fontColor(HDColor.warning)
          .width('100%')
          .margin({ top: 8 })
      }

      Row({ space: 12 }) {
        Button(this.deploying ? '部署中…' : '重新部署')
          .fontSize(HDType.body)
          .enabled(!this.deploying)
          .layoutWeight(1)
          .onClick(() => {
            this.engine.redeploy();
            this.refreshEngineState();
          })

        Button('刷新')
          .fontSize(HDType.body)
          .backgroundColor(HDText.tertiary)
          .layoutWeight(1)
          .onClick(() => {
            this.refreshEngineState();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDSurface.card)
    .borderRadius(HDRadius.large)
    .margin({ bottom: 12 })
  }

  @Builder
  SchemaListCard() {
    Column() {
      Text('已安装方案')
        .fontSize(HDType.body)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 8 })

      if (this.schemas.length === 0) {
        Text('尚未部署完成，或没有可用的方案。')
          .fontSize(HDType.caption)
          .fontColor(HDText.tertiary)
          .width('100%')
      }

      ForEach(this.schemas, (schema: SchemaRow) => {
        Row() {
          Text(schema.name)
            .fontSize(HDType.body)
            .layoutWeight(1)
          Text(schema.schemaId)
            .fontSize(HDType.caption)
            .fontColor(HDText.tertiary)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      }, (schema: SchemaRow) => schema.schemaId)
    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDSurface.card)
    .borderRadius(HDRadius.large)
    .margin({ bottom: 12 })
  }

  /** Reads a bundled licence text out of rawfile. */
  private async loadLicense(fileName: string): Promise<void> {
    try {
      const content: Uint8Array =
        await this.context.resourceManager.getRawFileContent(`licenses/${fileName}`);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      this.licenseText = decoder.decodeToString(content);
      this.licenseName = fileName;
      AppLog.info(TAG, `opened licence ${fileName}`);
    } catch (error) {
      AppLog.exception(TAG, `cannot read licence ${fileName}`, error);
      this.licenseText = `无法读取 ${fileName}`;
      this.licenseName = fileName;
    }
  }

  private async openLicenses(): Promise<void> {
    try {
      this.licenseNames = await this.context.resourceManager.getRawFileList('licenses');
      AppLog.info(TAG, `bundled licences: ${this.licenseNames.length}`);
    } catch (error) {
      AppLog.exception(TAG, 'cannot list bundled licences', error);
      this.licenseNames = [];
    }
    this.licenseText = '';
    this.licenseName = '';
    this.licensesOpen = true;
  }

  /**
   * About and acknowledgements.
   *
   * The nickname is the project's branding; the licence line under it carries
   * the legal copyright name.
   */
  @Builder
  AboutCard() {
    Column() {
      Text('关于')
        .fontSize(HDType.body)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text('Blueberry\u{1FAD0}')
          .fontSize(HDType.subtitle)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ bottom: 4 })

      Text('\u00A9 2026 Haochen Xia · AGPL-3.0-or-later')
        .fontSize(HDType.caption)
        .fontColor(HDText.tertiary)
        .width('100%')
        .margin({ bottom: 8 })

      Text('本应用以 AGPL-3.0-or-later 发布。你可以自由学习、修改与再分发，' +
           '但分发衍生作品或通过网络提供服务时，必须以同一许可证公开完整源码。')
        .fontSize(HDType.caption)
        .fontColor(HDText.tertiary)
        .width('100%')
        .margin({ bottom: 12 })

      Text('致谢上游项目')
        .fontSize(HDType.caption)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      ForEach(CREDITS, (credit: Credit) => {
        Column() {
          Row() {
            Text(credit.name)
              .fontSize(HDType.caption)
              .fontColor(HDText.primary)
              .layoutWeight(1)
            Text(credit.license)
              .fontSize(HDType.footnote)
              .fontColor(HDColor.brand)
          }
          .width('100%')
          Text(`${credit.author} · ${credit.usage}`)
            .fontSize(HDType.footnote)
            .fontColor(HDText.tertiary)
            .width('100%')
            .margin({ top: 2 })
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }, (credit: Credit) => credit.name)

      Divider()
        .color(HDSurface.divider)
        .margin({ top: 8, bottom: 8 })

      Text('感谢所有上游项目的作者与贡献者。')
        .fontSize(HDType.caption)
        .fontColor(HDText.tertiary)
        .width('100%')

      Divider()
        .color(HDSurface.divider)
        .margin({ top: HDSpace.md, bottom: HDSpace.md })

      Text('反馈与联系')
        .fontSize(HDType.caption)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: HDSpace.xs })

      // Selectable so the address can be copied without retyping it.
      Text('blueberry_xia@qq.com')
        .fontSize(HDType.body)
        .fontColor(HDColor.brand)
        .copyOption(CopyOptions.LocalDevice)
        .width('100%')
        .margin({ bottom: HDSpace.sm })

      Text('发现侵权内容、错误或改进建议，欢迎邮件告知，也可在项目仓库提交 issue。' +
           '作者高三在读，回复可能不及时，敬请谅解。感谢每一份反馈。')
        .fontSize(HDType.footnote)
        .fontColor(HDText.tertiary)
        .width('100%')
    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDSurface.card)
    .borderRadius(HDRadius.large)
    .margin({ bottom: 12 })
  }

  @Builder
  LicenseCard() {
    Column() {
      Row() {
        Text('开源许可')
          .fontSize(HDType.body)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text('查看')
          .fontSize(HDType.caption)
          .fontColor(HDColor.brand)
          .onClick(() => {
            this.openLicenses();
          })
        Text('\u203A')
          .fontSize(HDType.body)
          .fontColor(HDText.tertiary)
          .padding({ left: 4 })
          .onClick(() => {
            this.openLicenses();
          })
      }
      .width('100%')
      .height(HDSize.headerHeight)

      Text('本应用以 AGPL-3.0-or-later 发布，并包含多个第三方组件。' +
           '点击「查看」可阅读随包分发的完整许可证文本。')
        .fontSize(HDType.caption)
        .fontColor(HDText.tertiary)
        .width('100%')
    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDSurface.card)
    .borderRadius(HDRadius.large)
    .margin({ bottom: 12 })
  }

  /** Full-screen licence reader, stacked over the page. */
  @Builder
  LicenseViewer() {
    Column() {
      Row() {
        Text(this.licenseName.length > 0 ? this.licenseName : '开源许可')
          .fontSize(HDType.subtitle)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.licenseName.length > 0) {
          Text('返回')
            .fontSize(HDType.body)
            .fontColor(HDColor.brand)
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              this.licenseName = '';
              this.licenseText = '';
            })
        }
        Text('关闭')
          .fontSize(HDType.body)
          .fontColor(HDColor.brand)
          .padding({ left: 4 })
          .onClick(() => {
            this.licensesOpen = false;
          })
      }
      .width('100%')
      .height(44)

      if (this.licenseName.length > 0) {
        Scroll() {
          Text(this.licenseText)
            .fontSize(HDType.footnote)
            .fontFamily('monospace')
            .fontColor(HDText.primary)
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .padding(8)
        .backgroundColor(HDSurface.sunken)
        .borderRadius(HDRadius.medium)
      } else {
        Scroll() {
          Column() {
            ForEach(this.licenseNames, (fileName: string) => {
              Text(fileName)
                .fontSize(HDType.caption)
                .fontColor(HDText.primary)
                .width('100%')
                .padding({ top: 12, bottom: 12 })
                .onClick(() => {
                  this.loadLicense(fileName);
                })
            }, (fileName: string) => fileName)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor(HDSurface.card)
  }

  @Builder
  EnableInputMethodCard() {
    Column() {
      Text('启用输入法')
        .fontSize(HDType.body)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 8 })

      Text('1. 打开「设置」→「系统」→「输入法」\n' +
           '2. 在输入法列表中选择「一个小输入法」\n' +
           '3. 在任意输入框中长按并切换输入法即可使用')
        .fontSize(HDType.caption)
        .fontColor(HDText.secondary)
        .width('100%')

      Button('打开输入法设置')
        .fontSize(HDType.body)
        .width('100%')
        .margin({ top: 12 })
        .onClick(() => {
          this.openInputMethodSettings();
        })
    }
    .width('100%')
    .padding(HDSpace.lg)
    .backgroundColor(HDSurface.card)
    .borderRadius(HDRadius.large)
  }

  /**
   * Opens the system input-method settings.
   *
   * The ability is asked for rather than hardcoded: a literally guessed
   * bundle/ability pair starts the Settings app on a URI it does not recognise,
   * which shows as a blank page.  If that still fails, the input-method picker is
   * used instead, since it at least lets the user switch keyboards.
   */
  private openInputMethodSettings(): void {
    try {
      const element: bundleManager.ElementName = inputMethod.getSystemInputMethodConfigAbility();
      const want: Want = {
        bundleName: element.bundleName,
        abilityName: element.abilityName,
        moduleName: element.moduleName
      };
      hilog.info(DOMAIN, TAG, 'opening IME settings: %{public}s/%{public}s',
                 element.bundleName, element.abilityName);
      this.context.startAbility(want)
        .catch((error: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'IME settings failed (%{public}s), falling back to picker',
                     error.message);
          this.showInputMethodPicker();
        });
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getSystemInputMethodConfigAbility failed: %{public}s', err.message);
      this.showInputMethodPicker();
    }
  }
}
