/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Process-wide owner of the Rime engine for the input-method extension.
 *
 * Responsibilities:
 *   - materialise the schema data that ships in rawfile/ into a real directory
 *     the native engine can read;
 *   - configure, initialise and deploy librime;
 *   - own the single input session and turn HarmonyOS key events into Rime
 *     commits and candidate lists;
 *   - publish the resulting state to whoever is observing it.
 *
 * State distribution note: the engine runs in an extension, which has no UI
 * context of its own, so neither AppStorage nor a LocalStorage handed to
 * setUiContent() is a dependable channel.  Instead the service keeps a plain
 * in-process listener list; the keyboard page subscribes on appear and copies
 * each snapshot into @State.  The panel and the extension always live in the
 * same process, so this needs no state-management machinery at all.
 */

import { common } from '@kit.AbilityKit';
import { inputMethodEngine } from '@kit.IMEKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import rime from 'libentry.so';
import { AppLog, LogEntry } from '../common/AppLog';
import { VERSION_NAME } from '../common/AppInfo';
import { FolderImportOutcome, ImportProgress, RimeConfigStore } from './RimeConfigStore';
import { RimeKeys, RimeModifier } from './RimeKeys';
import { RimePaths } from './RimePaths';

const DOMAIN: number = 0x0000;
const TAG: string = 'RimeEngineService';

/** Upper bound on how many files the fingerprint scan will look at. */
const FINGERPRINT_MAX_ENTRIES: number = 4000;
/** How deep the fingerprint scan descends below the two data directories. */
const FINGERPRINT_MAX_DEPTH: number = 3;

/** Accumulator for the configuration fingerprint scan. */
interface FingerprintTotals {
  fileCount: number;
  totalBytes: number;
  newestMtime: number;
}

/**
 * One candidate, decoupled from the native module's own type.
 *
 * `index` is the position in the whole candidate list and is what
 * selectCandidate() must be given.
 */
export interface CandidateEntry {
  index: number;
  text: string;
  comment: string;
}

/** A schema entry as offered by the settings panel. */
export interface SchemaEntry {
  schemaId: string;
  name: string;
}

/**
 * One toggle from a schema's `switches:` block, with its current value.
 *
 * `name`, `options` and `states` come from the schema; the remaining fields are
 * derived here from the live option values, with the titles prettified for the
 * well-known names.
 */
export interface SwitchEntry {
  /** Option name for a plain switch; empty for a radio group. */
  name: string;
  /** Option names for a radio group; empty for a plain switch. */
  options: string[];
  /** Human-readable title for the row. */
  title: string;
  /** Labels for the option's values, straight from the schema. */
  states: string[];
  /** True when the option is currently on (any of them, for a radio group). */
  enabled: boolean;
  /**
   * Radio group: index of the active option within `options`, or -1 when none
   * of them is on.  Plain switch: 0 or 1, indexing `states` (off / on).
   */
  activeIndex: number;
  /** Label of the current value, or a dash placeholder. */
  currentLabel: string;
}

/**
 * Friendly titles for the toggles Rime schemas use most often: RADIO_TITLES is
 * keyed by radio-group option name, SWITCH_TITLES by plain switch name.
 *
 * The *set* of toggles still comes entirely from the schema; these only avoid
 * showing raw option names for the common ones.
 */
const RADIO_TITLES: Map<string, string> = new Map<string, string>([
  ['zh_trad', '字形'],
  ['zh_simp', '字形'],
  ['zh_hk', '字形'],
  ['zh_tw', '字形']
]);

const SWITCH_TITLES: Map<string, string> = new Map<string, string>([
  ['ascii_mode', '中/英'],
  ['full_shape', '全角/半角'],
  ['simplification', '简繁'],
  ['ascii_punct', '标点'],
  ['extended_charset', '扩展字符集'],
  ['emoji', 'Emoji'],
  ['prediction', '联想'],
  ['zh_hans', '简体'],
  ['zh_hant', '繁體']
]);

/**
 * Immutable snapshot of everything the keyboard UI renders.
 *
 * Listeners receive a fresh object on every change; replacing the whole value is
 * what makes an @State field re-render.
 */
export interface RimeState {
  /** Engine is initialised and not deploying: keystrokes can be composed. */
  ready: boolean;
  deploying: boolean;
  /** Human-readable status, e.g. a deployment message. */
  message: string;
  /** Composing text, mirrored into the editor as preview text. */
  preedit: string;
  commitPreview: string;
  /**
   * Every candidate for the session, each with the global index that
   * selectCandidate() expects.
   *
   * The keyboard pages through this itself, so the number of candidates shown
   * per page can follow how wide they are rather than librime's fixed menu page
   * size.
   */
  candidates: CandidateEntry[];
  /** Highlighted index as librime reports it, relative to its own page. */
  highlighted: number;
  asciiMode: boolean;
  schemaName: string;
  /**
   * Incremented whenever anything read out of the Rime configuration may have
   * changed: a deployment finished, or the active schema was switched.
   *
   * The settings panel watches this and reloads; without it the panel keeps
   * showing the switches of whatever schema was active when it was opened.
   */
  configGeneration: number;
}

/** Receives a new snapshot whenever the engine state changes. */
export type RimeStateListener = (state: RimeState) => void;

/** Neutral state, used as the initial value of the UI's @State field. */
export function emptyRimeState(): RimeState {
  const state: RimeState = {
    ready: false,
    deploying: false,
    message: '',
    preedit: '',
    commitPreview: '',
    candidates: [],
    highlighted: 0,
    asciiMode: false,
    schemaName: '',
    configGeneration: 0
  };
  return state;
}

/**
 * Singleton façade over libentry.so.
 *
 * Call `bootstrap` once in each process that needs the engine -- the
 * input-method extension and the app's settings page both do -- then drive input
 * with `handleKey`.  All state changes are pushed to registered listeners so the
 * keyboard UI stays in sync without polling.
 */
export class RimeEngineService {
  private static instance: RimeEngineService | null = null;

  private listeners: RimeStateListener[] = [];

  /** Resolved data directories, available once bootstrap() has run. */
  private paths: RimePaths | null = null;
  /**
   * The context this instance bootstrapped with.
   *
   * Kept so the keyboard can import a configuration folder itself: an input
   * method extension has its own sandbox, so a folder copied by the settings
   * page lands somewhere the keyboard cannot read.
   */
  private context: common.Context | null = null;
  private sessionId: number = 0;
  private initialized: boolean = false;
  private deploying: boolean = false;
  private deploymentFailed: boolean = false;

  private preedit: string = '';
  private commitPreview: string = '';
  private candidates: CandidateEntry[] = [];
  private highlighted: number = 0;
  private asciiMode: boolean = false;
  private schemaName: string = '';
  private message: string = '';
  /** Bumped whenever the Rime configuration may have changed. */
  private configGeneration: number = 0;
  /** Last deployment stamp observed on disk. */
  private lastDeployStamp: string = '';
  /**
   * Fingerprint of the configuration files, used to notice edits that were made
   * without going through the app (files pushed straight into the sandbox, which
   * produce no deployment notification).
   */
  private lastConfigFingerprint: string = '';
  /** Set when the on-disk configuration changed; drives the lazy engine restart. */
  private configDirty: boolean = false;
  /** Set when a deployment was requested while one was already running. */
  private pendingDeploy: boolean = false;
  /**
   * The folder this instance last imported, read by hasImportedUri().
   *
   * The settings page hands the picked URI over and the keyboard copies the
   * folder itself, so the same URI can arrive more than once (a repeated pick,
   * or a reply on the request/reply path); that copy must not happen twice.
   */
  private lastImportedUri: string = '';
  /** Human-readable outcome of the last import, shown in the keyboard's panel. */
  private lastImportStatus: string = '';

  /** Bumped whenever the user directory's deployed data changes. */

  private constructor() {
  }

  static getInstance(): RimeEngineService {
    if (RimeEngineService.instance === null) {
      RimeEngineService.instance = new RimeEngineService();
    }
    return RimeEngineService.instance;
  }

  /** Data directories, or null before bootstrap() completes. */
  getPaths(): RimePaths | null {
    return this.paths;
  }

  /** Registers a listener and immediately delivers the current state. */
  subscribe(listener: RimeStateListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
    listener(this.getState());
  }

  unsubscribe(listener: RimeStateListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** Current state; useful for a first render before any change arrives. */
  getState(): RimeState {
    const state: RimeState = {
      ready: this.isReady(),
      deploying: this.deploying,
      message: this.message,
      preedit: this.preedit,
      commitPreview: this.commitPreview,
      candidates: this.candidates,
      highlighted: this.highlighted,
      asciiMode: this.asciiMode,
      schemaName: this.schemaName,
      configGeneration: this.configGeneration
    };
    return state;
  }

  isReady(): boolean {
    // A failed deployment leaves librime unable to compose, so it belongs in
    // this predicate rather than in a field nobody reads.  The keyboard notices
    // !isReady() and falls back to committing keystrokes verbatim, and its
    // message line renders the failure text, which is otherwise never seen.
    return this.initialized && !this.deploying && !this.deploymentFailed;
  }

  isDeploying(): boolean {
    return this.deploying;
  }

  /**
   * Configures and starts the engine.  Safe to call repeatedly; later calls
   * return immediately once the engine is up.
   */
  async bootstrap(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }

    const paths: RimePaths = await RimePaths.prepare(context);
    this.paths = paths;
    this.context = context;
    // Creates the folder users drop their Rime configuration into, plus a README
    // explaining what belongs there.
    RimeConfigStore.ensureUserDir(context.filesDir);

    rime.configure({
      sharedDataDir: paths.sharedDataDir,
      userDataDir: paths.userDataDir,
      logDir: paths.logDir,
      appName: 'rime.fcitx5_ohos',
      // Warnings and above: INFO logging is very chatty during deployment.
      minLogLevel: 1
    });

    rime.setNotificationCallback((notification: rime.RimeNotification) => {
      this.onNotification(notification);
    });

    if (!rime.initialize()) {
      hilog.error(DOMAIN, TAG, 'librime failed to initialize');
      AppLog.error(TAG, 'rime.initialize() returned false');
      this.publishMessage('Rime 引擎初始化失败');
      return;
    }

    this.initialized = true;
    // Adopt whatever stamp is already on disk, so a deployment performed earlier
    // by the app's settings page is not mistaken for a fresh change.
    this.lastDeployStamp = this.readDeployStamp();
    this.lastConfigFingerprint = this.configFingerprint();
    hilog.info(DOMAIN, TAG, 'librime %{public}s initialized', rime.getVersion());
    // Logged so each component's own view of the sandbox is in the log trail.
    // Equal path strings do not prove a shared sandbox -- an extension can report
    // the same paths with different contents -- so the [live] listing in
    // getDiagnostics() is what actually distinguishes shared from isolated.
    hilog.info(DOMAIN, TAG, 'shared=%{public}s user=%{public}s',
               paths.sharedDataDir, paths.userDataDir);
    AppLog.info(TAG, `librime ${rime.getVersion()} ready`);
    AppLog.info(TAG, `shared=${paths.sharedDataDir}`);
    AppLog.info(TAG, `user=${paths.userDataDir}`);

    // A full check is cheap when the deployed data is current and rebuilds
    // everything when it is not, which covers first run and schema upgrades.
    this.beginDeployment(true);
  }

  /**
   * Drops the compiled schema artifacts librime produced from the old data.
   *
   * Deployment is incremental: a schema is rebuilt only when its source looks
   * newer than the corresponding file under <user>/build.  Replacing the whole
   * configuration makes that comparison meaningless, and a leftover
   * *.table.bin / *.prism.bin would be loaded instead of the imported schema.
   */
  clearDeployedArtifacts(): void {
    const paths: RimePaths | null = this.paths;
    if (paths === null) {
      return;
    }
    const buildDir: string = `${paths.userDataDir}/build`;
    try {
      if (fs.accessSync(buildDir)) {
        fs.rmdirSync(buildDir);
        hilog.info(DOMAIN, TAG, 'cleared deployed artifacts at %{public}s', buildDir);
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot clear %{public}s: %{public}s', buildDir, err.message);
    }
    // The next session must be built from the new artifacts.
    this.endSession();
    this.configDirty = true;
  }

  private beginDeployment(fullCheck: boolean): void {
    this.deploying = true;
    this.deploymentFailed = false;
    this.publishMessage(fullCheck ? '正在部署 Rime 数据…' : '正在更新 Rime 数据…');
    this.publish();

    if (!rime.startMaintenance(fullCheck)) {
      this.deploying = false;
      this.publishMessage('无法启动 Rime 部署');
      this.publish();
    }
  }

  /**
   * Re-runs a full deployment; called after the configuration is replaced.
   *
   * A request that arrives while another deployment is running is queued rather
   * than dropped: silently ignoring it would leave the freshly imported
   * configuration undeployed, which looks exactly like the import not working.
   */
  redeploy(): void {
    if (!this.initialized) {
      return;
    }
    if (this.deploying) {
      hilog.info(DOMAIN, TAG, 'deployment already running; queueing another');
      this.pendingDeploy = true;
      return;
    }
    // Every caller is reacting to a configuration change, so the artifacts built
    // from the previous configuration are worthless and must not be reused.
    this.clearDeployedArtifacts();
    this.beginDeployment(true);
  }

  private onNotification(notification: rime.RimeNotification): void {
    if (notification.type === 'deploy') {
      if (notification.value === 'start') {
        this.deploying = true;
        this.message = '正在部署 Rime 数据…';
        AppLog.info(TAG, 'deployment started');
      } else if (notification.value === 'success') {
        this.deploying = false;
        this.deploymentFailed = false;
        this.message = '';
        // Write the stamp before anything reloads, and remember it as our own so
        // this deployment does not later look like an external one.
        this.writeDeployStamp();
        // Snapshot the files as they are now, so this deployment is not later
        // mistaken for an out-of-band edit and redeployed a second time.
        this.lastConfigFingerprint = this.configFingerprint();
        // Sessions created before a deployment refer to stale tables, and the
        // parsed configs librime holds are stale too.
        this.endSession();
        this.configDirty = true;
        this.configGeneration++;
        AppLog.info(TAG, `deployment succeeded; schemas=${this.describeSchemas()}`);
      } else if (notification.value === 'failure') {
        this.deploying = false;
        this.deploymentFailed = true;
        this.message = 'Rime 数据部署失败，请查看日志';
        AppLog.error(TAG, 'deployment FAILED (see librime log for details)');
        // A failed deploy can still have rewritten part of the user data.
        this.configDirty = true;
        this.configGeneration++;
      }
      this.publish();

      if (this.pendingDeploy) {
        this.pendingDeploy = false;
        hilog.info(DOMAIN, TAG, 'running queued deployment');
        this.redeploy();
      }
      return;
    }

    if (notification.type === 'schema') {
      this.schemaName = RimeEngineService.schemaNameFromNotification(notification.value);
      AppLog.info(TAG, `schema changed to ${notification.value}`);
      // A schema change swaps the entire switch set.
      this.configGeneration++;
      this.publish();
      return;
    }

    if (notification.type === 'option') {
      // Values are "option" when enabled and "!option" when disabled.
      const disabled: boolean = notification.value.startsWith('!');
      const name: string = disabled ? notification.value.substring(1) : notification.value;
      if (name === 'ascii_mode') {
        this.asciiMode = !disabled;
        this.publish();
      }
    }
  }

  private static schemaNameFromNotification(notificationValue: string): string {
    // "<schema_id>/<schema_name>"
    const slash: number = notificationValue.indexOf('/');
    return slash >= 0 ? notificationValue.substring(slash + 1) : notificationValue;
  }

  // -------------------------------------------------------------------------
  // deployment stamp
  //
  // The engine can be driven from two places: this module inside the input
  // method extension, and the app's settings page, which may live in a different
  // process.  Whichever one deploys leaves a stamp on disk; the other notices the
  // change here and reloads instead of serving stale configuration.
  // -------------------------------------------------------------------------

  private writeDeployStamp(): void {
    const paths: RimePaths | null = this.paths;
    if (paths === null) {
      return;
    }
    const stamp: string = `${Date.now()}`;
    try {
      const path: string = RimePaths.deployMarkerPath(paths.userDataDir);
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, stamp);
      } finally {
        fs.closeSync(file);
      }
      this.lastDeployStamp = stamp;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot write deploy stamp: %{public}s', err.message);
    }
  }

  private readDeployStamp(): string {
    const paths: RimePaths | null = this.paths;
    if (paths === null) {
      return '';
    }
    try {
      const path: string = RimePaths.deployMarkerPath(paths.userDataDir);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(64);
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
      // No stamp yet simply means nobody has deployed from this sandbox view.
      return '';
    }
  }

  /**
   * Fingerprint of the configuration as it exists on disk.
   *
   * File count, total size and the newest modification time across the shared
   * and user directories.  Catches edits that produce no deployment
   * notification, such as files pushed straight into the sandbox.
   */
  private configFingerprint(): string {
    const paths: RimePaths | null = this.paths;
    if (paths === null) {
      return '';
    }
    const totals: FingerprintTotals = { fileCount: 0, totalBytes: 0, newestMtime: 0 };
    RimeEngineService.scanForFingerprint(paths.sharedDataDir, totals, 0);
    RimeEngineService.scanForFingerprint(paths.userDataDir, totals, 0);
    return `${totals.fileCount}-${totals.totalBytes}-${totals.newestMtime}`;
  }

  private static scanForFingerprint(dir: string, totals: FingerprintTotals, depth: number): void {
    if (depth > FINGERPRINT_MAX_DEPTH || totals.fileCount > FINGERPRINT_MAX_ENTRIES) {
      return;
    }

    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (error) {
      return;
    }

    for (const name of names) {
      if (name.length === 0 || name.charAt(0) === '.') {
        continue;
      }
      // Generated trees churn on every deployment and say nothing about the
      // user's configuration.
      if (name === 'build' || name === 'sync' || name.endsWith('.userdb')) {
        continue;
      }

      const full: string = `${dir}/${name}`;
      try {
        const stat: fs.Stat = fs.statSync(full);
        if (stat.isDirectory()) {
          RimeEngineService.scanForFingerprint(full, totals, depth + 1);
          continue;
        }
        totals.fileCount += 1;
        totals.totalBytes += stat.size;
        if (stat.mtime > totals.newestMtime) {
          totals.newestMtime = stat.mtime;
        }
      } catch (error) {
        continue;
      }
    }
  }

  /**
   * Picks up configuration changes made outside this instance.
   *
   * Two signals are checked, because they cover different situations:
   *
   *   - the deployment stamp, written whenever anything completes a deploy
   *     (the engine can be driven from the extension and from the app's settings
   *     page, which may be different processes);
   *   - a fingerprint of the files, which catches edits that never triggered a
   *     deployment at all.
   *
   * A change marks the configuration dirty, so the engine is rebuilt on next use
   * -- librime caches parsed configs and would otherwise keep serving the old
   * ones.  Returns true when something changed.
   */
  syncExternalConfig(): boolean {
    if (!this.initialized || this.deploying) {
      return false;
    }

    const stamp: string = this.readDeployStamp();
    const fingerprint: string = this.configFingerprint();

    if (this.lastConfigFingerprint.length === 0) {
      // First look since start-up: adopt the current state rather than
      // reporting it as a change.
      this.lastConfigFingerprint = fingerprint;
      if (stamp.length > 0) {
        this.lastDeployStamp = stamp;
      }
      return false;
    }

    const stampChanged: boolean = stamp.length > 0 && stamp !== this.lastDeployStamp;
    const filesChanged: boolean = fingerprint !== this.lastConfigFingerprint;
    if (!stampChanged && !filesChanged) {
      return false;
    }

    hilog.info(DOMAIN, TAG,
               'configuration changed (stamp %{public}s, files %{public}s)',
               String(stampChanged), String(filesChanged));
    this.lastDeployStamp = stamp;
    this.lastConfigFingerprint = fingerprint;
    this.configGeneration++;
    this.configDirty = true;
    this.endSession();
    this.publish();

    // Always verify the deployed data, not only when the files changed without a
    // stamp: the process that imported the configuration may have deployed it in
    // a different sandbox, or its deployment may not have finished.  A light
    // check costs nothing when everything is already current.
    hilog.info(DOMAIN, TAG, 'verifying deployment after configuration change');
    this.deploying = true;
    this.message = filesChanged && !stampChanged
      ? '检测到配置变更，正在部署…'
      : '正在校验部署…';
    this.publish();
    if (!rime.startMaintenance(false)) {
      this.deploying = false;
      this.message = '';
      this.publish();
    }
    return true;
  }

  private publishMessage(message: string): void {
    this.message = message;
    this.publish();
  }

  // -------------------------------------------------------------------------
  // session handling
  // -------------------------------------------------------------------------

  private ensureSession(): boolean {
    if (!this.initialized || this.deploying) {
      return false;
    }
    if (this.configDirty) {
      // Deferred until here on purpose: restarting from inside the deployment
      // notification callback would tear librime down while its maintenance
      // thread is still finishing.
      this.restartEngine();
    }
    if (this.sessionId !== 0 && rime.getStatus(this.sessionId) !== null) {
      return true;
    }
    try {
      this.sessionId = rime.createSession();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'createSession failed: %{public}s', err.message);
      this.sessionId = 0;
    }
    return this.sessionId !== 0;
  }

  /**
   * Rebuilds the librime instance so it re-reads the configuration files.
   *
   * librime caches parsed configs per config id inside ConfigComponent, which
   * lives as long as the engine does, so schema_open() keeps returning whatever
   * was parsed at start-up until the component graph is rebuilt.
   */
  private restartEngine(): void {
    this.configDirty = false;
    if (!this.initialized) {
      return;
    }
    this.sessionId = 0;
    hilog.info(DOMAIN, TAG, 'restarting librime to pick up new configuration');
    if (!rime.restart()) {
      hilog.error(DOMAIN, TAG, 'librime restart failed');
    } else {
      this.sessionId = 0;
    }
  }

  private endSession(): void {
    if (this.sessionId !== 0) {
      rime.destroySession(this.sessionId);
      this.sessionId = 0;
    }
    this.clearCompositionState();
    this.publish();
  }

  /** Called when the input connection goes away. */
  reset(): void {
    this.endSession();
  }

  // -------------------------------------------------------------------------
  // input
  // -------------------------------------------------------------------------

  /**
   * Feeds one keystroke to Rime.
   *
   * Returns the text the caller must insert into the editor: the commit Rime
   * produced, or the plain character when Rime declined the key.  Returns null
   * when Rime consumed the key, the key has no usable character, or the engine
   * is not ready.
   */
  handleKey(keyCode: number, unicodeChar: number, modifiers: number): string | null {
    if (!this.ensureSession()) {
      // No session (engine not ready yet, or creation failed): nothing to insert.
      return null;
    }

    const keysym: number = RimeKeys.keysymFromKeyCode(keyCode, unicodeChar);
    if (keysym === 0) {
      return null;
    }

    const consumed: boolean = rime.processKey(this.sessionId, keysym, modifiers);
    const commit: string | null = rime.getCommit(this.sessionId);
    this.refreshState();

    if (commit !== null && commit.length > 0) {
      // A commit always ends the current composition.
      this.clearCompositionState();
      this.publish();
      return commit;
    }

    if (!consumed) {
      // Rime declined the key: the editor should handle it itself.
      return RimeEngineService.textForKey(keyCode, unicodeChar, modifiers);
    }
    return null;
  }

  /**
   * Fallback text for a key Rime declined, so plain Latin characters still reach
   * the editor.  Modified keys and keys with no printable character yield null:
   * they are not text.
   */
  private static textForKey(keyCode: number, unicodeChar: number, modifiers: number): string | null {
    if (modifiers !== RimeModifier.NONE) {
      return null;
    }
    if (unicodeChar > 0) {
      return String.fromCodePoint(unicodeChar);
    }
    const keysym: number = RimeKeys.keysymFromKeyCode(keyCode, 0);
    if (keysym >= 0x20 && keysym <= 0x7e) {
      return String.fromCharCode(keysym);
    }
    return null;
  }

  /**
   * Selects a candidate by its index in the *whole* candidate list.
   *
   * The keyboard derives that index from its own pagination, so this must not be
   * translated to a page-relative position.
   */
  selectCandidate(globalIndex: number): string | null {
    if (!this.ensureSession()) {
      return null;
    }
    rime.selectCandidate(this.sessionId, globalIndex);
    const commit: string | null = rime.getCommit(this.sessionId);
    this.refreshState();
    if (commit !== null && commit.length > 0) {
      this.clearCompositionState();
      this.publish();
      return commit;
    }
    return null;
  }

  /** Commits whatever is currently being composed. */
  commitComposition(): string | null {
    if (!this.ensureSession()) {
      return null;
    }
    rime.commitComposition(this.sessionId);
    const commit: string | null = rime.getCommit(this.sessionId);
    this.refreshState();
    this.clearCompositionState();
    this.publish();
    return commit;
  }

  /** Abandons the current composition. */
  clearComposition(): void {
    if (this.sessionId !== 0) {
      rime.clearComposition(this.sessionId);
    }
    this.clearCompositionState();
    this.publish();
  }

  private clearCompositionState(): void {
    this.preedit = '';
    this.commitPreview = '';
    this.candidates = [];
    this.highlighted = 0;
  }

  // -------------------------------------------------------------------------
  // options and schemas
  // -------------------------------------------------------------------------

  /**
   * Switches between Chinese and direct (ASCII) input.
   *
   * The new value is read back from the engine instead of being assumed, so the
   * Chinese/English indicator cannot drift out of sync with what typing does.
   */
  toggleAsciiMode(): void {
    if (!this.ensureSession()) {
      return;
    }
    const next: boolean = !this.asciiMode;
    rime.setOption(this.sessionId, 'ascii_mode', next);

    const applied: boolean = rime.getOption(this.sessionId, 'ascii_mode');
    if (applied !== this.asciiMode) {
      this.asciiMode = applied;
      hilog.info(DOMAIN, TAG, 'ascii_mode set to %{public}s', String(applied));
    } else {
      hilog.warn(DOMAIN, TAG, 'ascii_mode did not change from %{public}s', String(this.asciiMode));
    }
    this.refreshState();
  }

  setOption(optionName: string, value: boolean): void {
    if (!this.ensureSession()) {
      return;
    }
    rime.setOption(this.sessionId, optionName, value);
    this.refreshState();
  }

  getOption(optionName: string): boolean {
    if (!this.ensureSession()) {
      return false;
    }
    return rime.getOption(this.sessionId, optionName);
  }

  getSchemaList(): rime.RimeSchemaItem[] {
    if (!this.initialized) {
      return [];
    }
    return rime.getSchemaList();
  }

  /**
   * Comma-separated schema ids the engine reports.
   *
   * Shown in the diagnostics panels; if the imported schemas are missing here,
   * the deployment did not produce them, which is the difference between "the
   * import did not copy the files" and "the files are there but unusable".
   */
  private describeSchemas(): string {
    const schemas: rime.RimeSchemaItem[] = this.getSchemaList();
    if (schemas.length === 0) {
      return '(none)';
    }
    return schemas.map((item: rime.RimeSchemaItem) => item.schemaId).join(',');
  }

  /** Schemas offered by the settings panel. */
  getSchemas(): SchemaEntry[] {
    return this.getSchemaList().map((item: rime.RimeSchemaItem) => {
      const entry: SchemaEntry = { schemaId: item.schemaId, name: item.name };
      return entry;
    });
  }

  /**
   * Imports a configuration folder that the settings page picked.
   *
   * The copy always happens here, inside the input method process, because this
   * is where librime looks for its data.  Doing it here is also correct when the
   * two components do share a data directory -- in that case the write simply
   * lands in the directory the settings page was looking at anyway.
   */
  async importFromUri(sourceUri: string,
                       onProgress: (progress: ImportProgress) => void)
    : Promise<FolderImportOutcome> {
    const paths: RimePaths | null = this.paths;
    if (paths === null) {
      throw new Error('引擎尚未就绪，请稍后再试');
    }

    AppLog.info(TAG, `importFromUri: ${sourceUri} -> ${paths.sharedDataDir}`);
    this.lastImportStatus = '正在复制文件…';
    this.lastImportedUri = sourceUri;
    const outcome: FolderImportOutcome =
      await RimeConfigStore.mergeFolderInto(sourceUri, paths.sharedDataDir, onProgress);
    AppLog.info(TAG, `importFromUri: ${outcome.copied} copied, ${outcome.failed} failed, ` +
      `${outcome.unreachable} unreachable, directories=[${outcome.directories.join(', ')}]`);
    this.lastImportStatus = `已导入 ${outcome.copied} 个文件，含目录 ` +
      `[${outcome.directories.join(', ')}]` +
      (outcome.unreachable > 0 ? `，${outcome.unreachable} 个条目无法读取` : '');
    this.configGeneration++;
    this.redeploy();
    return outcome;
  }

  /**
   * True when this instance has already applied `folderUri`.
   *
   * Used to avoid copying the same folder twice.
   */
  hasImportedUri(folderUri: string): boolean {
    return folderUri.length > 0 && folderUri === this.lastImportedUri;
  }

  /**
   * Imports a configuration folder using the input method's own context to run
   * the document picker.
   *
   * This is the SECOND of two routes.  The reliable one goes through the
   * settings page, which picks a folder and hands the URI over (see
   * common/ConfigHandoff.ets); the keyboard then copies from that URI, because
   * an extension is a separate process with its own data directory and anything
   * the settings page copies is invisible here.
   *
   * This route exists for when the keyboard is the only thing on screen.  Whether
   * the picker can complete a round-trip from an extension context is platform
   * dependent: InputMethodExtensionContext has no startAbilityForResult(), and
   * this call was observed to fail with error 13900042 on a real device.  Prefer
   * the hand-off route; keep this one only as a fallback.
   *
   * Resolves to null when the user cancels.
   */
  async importConfigFolder(onProgress: (progress: ImportProgress) => void)
    : Promise<FolderImportOutcome | null> {
    const context: common.Context | null = this.context;
    const paths: RimePaths | null = this.paths;
    if (context === null || paths === null) {
      AppLog.error(TAG, 'importConfigFolder: engine not bootstrapped');
      throw new Error('引擎尚未就绪，请稍后重试');
    }

    AppLog.info(TAG, `importConfigFolder: picking into ${paths.sharedDataDir}`);
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const pickerOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    pickerOptions.selectMode = picker.DocumentSelectMode.FOLDER;
    pickerOptions.maxSelectNumber = 1;

    const uris: string[] = await documentPicker.select(pickerOptions);
    if (uris.length === 0) {
      AppLog.info(TAG, 'importConfigFolder: nothing picked');
      return null;
    }

    const outcome: FolderImportOutcome =
      await RimeConfigStore.mergeFolderInto(uris[0], paths.sharedDataDir, onProgress);
    AppLog.info(TAG, `importConfigFolder: ${outcome.copied} copied, ` +
      `${outcome.failed} failed, ${outcome.unreachable} unreachable`);
    this.configGeneration++;
    this.redeploy();
    return outcome;
  }

  /**
   * Throws away every cached view of the configuration and rebuilds from disk.
   *
   * Exposed as a button in the keyboard because automatic change detection can
   * only work if the keyboard's process can see the same files as the settings
   * page.  Whether this button helps is itself diagnostic: if it does, detection
   * is at fault; if it does not, the two processes are reading different data.
   */
  forceReload(): void {
    if (!this.initialized) {
      AppLog.warn(TAG, 'forceReload ignored: engine not initialised');
      return;
    }
    AppLog.info(TAG, 'forceReload: re-reading configuration from disk');
    this.lastDeployStamp = this.readDeployStamp();
    this.lastConfigFingerprint = this.configFingerprint();
    this.endSession();
    this.restartEngine();
    this.configGeneration++;
    this.publish();
    this.beginDeployment(true);
  }

  /**
   * The security mode the system is running this input method in.
   *
   * In BASIC mode an input method extension is a pure typing tool: it may not
   * touch files outside its own sandbox, which is why an imported configuration
   * never becomes visible and why a picked folder URI cannot be read.  FULL mode
   * lifts that restriction.  The switch belongs to the user (Settings > System >
   * Input methods), so the app can only report it and explain what to do.
   */
  getSecurityMode(): string {
    try {
      const mode: inputMethodEngine.SecurityMode =
        inputMethodEngine.getInputMethodAbility().getSecurityMode();
      return mode === inputMethodEngine.SecurityMode.FULL ? 'FULL' : 'BASIC';
    } catch (error) {
      const err = error as BusinessError;
      AppLog.warn(TAG, `getSecurityMode failed: ${err.code} ${err.message}`);
      return `unknown(${err.code})`;
    }
  }

  /** True when the keyboard may read files outside its own sandbox. */
  isFullAccessMode(): boolean {
    return this.getSecurityMode() === 'FULL';
  }

  /**
   * Multi-line status for the keyboard's diagnostics panel.
   *
   * Rendered inside the keyboard rather than logged, because the input method
   * runs in its own process with its own sandbox: only what this process can
   * actually list proves which configuration files it is really reading.
   */
  getDiagnostics(): string {
    const paths: RimePaths | null = this.paths;
    const lines: string[] = [];
    lines.push(`version ${VERSION_NAME}`);
    lines.push(`securityMode=${this.getSecurityMode()}` +
      (this.isFullAccessMode() ? '' : '  <-- 基础模式：无法读取沙箱外文件'));
    lines.push(`initialized=${this.initialized} deploying=${this.deploying}`);
    lines.push(`ready=${this.isReady()}`);
    lines.push(`shared=${paths !== null ? paths.sharedDataDir : '(unset)'}`);
    lines.push(`user=${paths !== null ? paths.userDataDir : '(unset)'}`);
    if (this.ensureSession()) {
      const currentSchemaId: string = rime.getCurrentSchema(this.sessionId);
      lines.push(`current=${currentSchemaId.length > 0 ? currentSchemaId : '(none)'}`);
    } else {
      lines.push('current=(no session)');
    }
    // Plugin-provided components.  A schema that references one which is not
    // registered still loads, it just quietly does less, so the availability has
    // to be reported explicitly.
    lines.push(`component.lua_translator=${rime.hasComponent('lua_translator')}`);
    lines.push(`component.grammar=${rime.hasComponent('grammar')}`);
    lines.push(`component.simplifier=${rime.hasComponent('simplifier')}`);
    lines.push(`grammarLanguage=${this.describeGrammar()}`);
    lines.push(`schemas=${this.describeSchemas()}`);
    lines.push(`switches=${this.getSwitches().map((entry: SwitchEntry) => entry.title).join(', ')}`);
    lines.push('');
    // The [live] lines re-read the disk now.  The [cached] stamp and fingerprint
    // further down only say what this process last adopted, which cannot
    // distinguish "the files did not change" from "this process cannot see the
    // files the settings page wrote".
    if (paths !== null) {
      lines.push(`[live] sharedEntries=${RimeEngineService.listEntries(paths.sharedDataDir)}`);
      lines.push(`[live] userBuild=${RimeEngineService.listEntries(`${paths.userDataDir}/build`)}`);
      lines.push(`[live] fingerprint=${this.configFingerprint()}`);
      lines.push(`[live] stampFile=${this.readDeployStamp()}`);
    }
    lines.push(`[cached] deployStamp=${this.lastDeployStamp.length > 0 ? this.lastDeployStamp : '(none)'}`);
    lines.push(`[cached] fingerprint=${this.lastConfigFingerprint}`);
    lines.push(`lastImportUri=${this.lastImportedUri.length > 0 ? this.lastImportedUri : '(none)'}`);
    lines.push(`lastImportStatus=${this.lastImportStatus.length > 0 ? this.lastImportStatus : '(none)'}`);

    // The keyboard's own log.  Nothing else records whether a handed-off folder
    // ever reached this process, and the device's hilog cannot be read back.
    lines.push('--- 最近日志 ---');
    const recent: LogEntry[] = AppLog.snapshot().slice(-14);
    for (const entry of recent) {
      lines.push(`${entry.time} ${entry.tag}: ${entry.message}`);
    }
    return lines.join('\n');
  }

  /**
   * The grammar language the schema declares, and whether its .gram file is on
   * disk.
   *
   * The grammar plugin looks for `<user>/<language>.gram` first and
   * `<shared>/<language>.gram` second; without either it logs a failure and
   * quietly falls back to no grammar, which is otherwise indistinguishable from
   * grammar being switched off.
   */
  private describeGrammar(): string {
    if (this.sessionId === 0) {
      return '(no session)';
    }
    const grammarLanguage: string = rime.getGrammarLanguage(this.sessionId);
    if (grammarLanguage.length === 0) {
      return '(schema declares none)';
    }

    const paths: RimePaths | null = this.paths;
    if (paths === null) {
      return `${grammarLanguage} (paths unknown)`;
    }

    const gramFilePaths: string[] = [
      `${paths.userDataDir}/${grammarLanguage}.gram`,
      `${paths.sharedDataDir}/${grammarLanguage}.gram`
    ];
    for (const gramFilePath of gramFilePaths) {
      try {
        const stat = fs.statSync(gramFilePath);
        return `${grammarLanguage} file=${gramFilePath} (${stat.size} bytes)`;
      } catch (error) {
        continue;
      }
    }
    return `${grammarLanguage} file=MISSING (looked in user/ and shared/)`;
  }

  /** Comma-separated directory listing, or a marker explaining why there is none. */
  private static listEntries(dir: string): string {
    try {
      const names: string[] = fs.listFileSync(dir);
      return names.length === 0 ? '(empty)' : names.join(', ');
    } catch (error) {
      return '(unreadable)';
    }
  }

  /** The id of the schema the session is currently using. */
  getActiveSchemaId(): string {
    if (!this.ensureSession()) {
      return '';
    }
    return rime.getCurrentSchema(this.sessionId);
  }

  /**
   * Toggles declared by the current schema, with their live values.
   *
   * Read on demand rather than cached: the schema can change under us, and the
   * option values change as the user types (Rime flips ascii_mode on its own).
   */
  getSwitches(): SwitchEntry[] {
    if (!this.ensureSession()) {
      return [];
    }
    const schemaId: string = rime.getCurrentSchema(this.sessionId);
    if (schemaId.length === 0) {
      AppLog.warn(TAG, 'getSwitches: no active schema');
      return [];
    }

    const sessionId: number = this.sessionId;
    const declaredSwitches: rime.RimeSchemaSwitch[] = rime.getSchemaSwitches(schemaId);
    if (declaredSwitches.length === 0) {
      AppLog.warn(TAG, `schema '${schemaId}' declares no switches`);
    }
    return declaredSwitches.map((declaredSwitch: rime.RimeSchemaSwitch) => {
      if (declaredSwitch.options.length > 0) {
        return RimeEngineService.radioSwitchEntry(sessionId, declaredSwitch);
      }
      const enabled: boolean = rime.getOption(sessionId, declaredSwitch.name);
      const entry: SwitchEntry = {
        name: declaredSwitch.name,
        options: [],
        title: SWITCH_TITLES.has(declaredSwitch.name)
          ? SWITCH_TITLES.get(declaredSwitch.name)!
          : declaredSwitch.name,
        states: declaredSwitch.states,
        enabled: enabled,
        activeIndex: enabled ? 1 : 0,
        currentLabel: RimeEngineService.booleanSwitchLabel(declaredSwitch.states, enabled)
      };
      return entry;
    });
  }

  /** Builds the row for a schema switch written in the `options:` radio form. */
  private static radioSwitchEntry(sessionId: number,
                                  declaredSwitch: rime.RimeSchemaSwitch): SwitchEntry {
    let activeIndex: number = -1;
    for (let i = 0; i < declaredSwitch.options.length; i++) {
      if (rime.getOption(sessionId, declaredSwitch.options[i])) {
        activeIndex = i;
        break;
      }
    }

    const firstOptionName: string = declaredSwitch.options[0];
    let title: string = firstOptionName;
    if (RADIO_TITLES.has(firstOptionName)) {
      title = RADIO_TITLES.get(firstOptionName)!;
    }

    let currentLabel: string = '—';
    if (activeIndex >= 0 && activeIndex < declaredSwitch.states.length) {
      currentLabel = declaredSwitch.states[activeIndex];
    }

    const entry: SwitchEntry = {
      name: '',
      options: declaredSwitch.options,
      title: title,
      states: declaredSwitch.states,
      enabled: activeIndex >= 0,
      activeIndex: activeIndex,
      currentLabel: currentLabel
    };
    return entry;
  }

  /** Label of the value a boolean switch currently holds. */
  private static booleanSwitchLabel(states: string[], enabled: boolean): string {
    if (states.length === 0) {
      return enabled ? '开' : '关';
    }
    const index: number = enabled ? Math.min(1, states.length - 1) : 0;
    return states[index];
  }

  /**
   * Advances a switch to its next value.
   *
   * A plain switch flips; a radio group turns the current option off and the
   * next one on, which is the only way to change such a switch.
   */
  advanceSwitch(entry: SwitchEntry): void {
    if (!this.ensureSession()) {
      return;
    }

    if (entry.options.length === 0) {
      rime.setOption(this.sessionId, entry.name, !entry.enabled);
      this.refreshState();
      return;
    }

    const nextIndex: number = (entry.activeIndex + 1) % entry.options.length;
    for (let i = 0; i < entry.options.length; i++) {
      rime.setOption(this.sessionId, entry.options[i], i === nextIndex);
    }
    this.refreshState();
  }

  setActiveSchema(schemaId: string): boolean {
    return this.selectSchema(schemaId);
  }

  selectSchema(schemaId: string): boolean {
    if (!this.ensureSession()) {
      return false;
    }
    const selected: boolean = rime.selectSchema(this.sessionId, schemaId);
    if (selected) {
      AppLog.info(TAG, `selected schema ${schemaId}`);
    } else {
      // A schema that will not load is almost always a deployment that did not
      // produce its tables; say so instead of failing silently.
      AppLog.error(TAG, `selectSchema('${schemaId}') failed; deployed schemas: ${this.describeSchemas()}`);
    }
    // The switch list belongs to the schema, so it changed too.
    this.configGeneration++;
    this.refreshState();
    return selected;
  }

  getVersion(): string {
    return this.initialized ? rime.getVersion() : '';
  }

  getSchemaName(): string {
    return this.schemaName;
  }

  /** Current composing text, mirrored into the editor as preview text. */
  getPreedit(): string {
    return this.preedit;
  }

  /**
   * True while there is an active composition.
   *
   * The backspace key uses this to decide whether Rime should consume the
   * deletion (shortening the composition) or whether the editor should delete
   * real text.
   */
  isComposing(): boolean {
    return this.preedit.length > 0;
  }

  /** Every candidate, each with its global index for selectCandidate(). */
  getCandidates(): CandidateEntry[] {
    return this.candidates;
  }

  isAsciiMode(): boolean {
    return this.asciiMode;
  }

  // -------------------------------------------------------------------------
  // state publication
  // -------------------------------------------------------------------------

  private refreshState(): void {
    if (this.sessionId === 0) {
      this.clearCompositionState();
      this.publish();
      return;
    }

    const rimeContext: rime.RimeContext | null = rime.getContext(this.sessionId);
    if (rimeContext === null) {
      this.clearCompositionState();
      this.publish();
      return;
    }

    this.preedit = rimeContext.composition.preedit;
    this.commitPreview = rimeContext.commitTextPreview;
    // Take the whole list rather than the context's current page: the keyboard
    // does its own pagination.
    const candidateItems: rime.RimeCandidateListItem[] = rime.getCandidateList(this.sessionId);
    this.candidates = candidateItems.map((item: rime.RimeCandidateListItem) => {
      const entry: CandidateEntry = {
        index: item.index,
        text: item.text,
        comment: item.comment
      };
      return entry;
    });
    this.highlighted = rimeContext.menu.highlightedCandidateIndex;

    const status: rime.RimeStatus | null = rime.getStatus(this.sessionId);
    if (status !== null) {
      this.asciiMode = status.isAsciiMode;
      this.schemaName = status.schemaName;
    }

    this.publish();
  }

  private publish(): void {
    if (this.listeners.length === 0) {
      return;
    }
    const state: RimeState = this.getState();
    // Iterate over a copy: a listener may unsubscribe while being notified.
    const listeners: RimeStateListener[] = this.listeners.slice();
    for (const listener of listeners) {
      listener(state);
    }
  }
}
