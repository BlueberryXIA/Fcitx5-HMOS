/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * User-supplied Rime configuration.
 *
 * Rime reads its customisation from the *user data directory*: `*.custom.yaml`
 * files patch the matching file in the shared data directory, and whole new
 * schemas or dictionaries can simply be dropped in.  That directory is therefore
 * the folder users are meant to put files into, exactly as Rime works on the
 * desktop.
 *
 * The directory is inside the application sandbox
 * (<filesDir>/rime/user).  No ordinary file manager can reach inside that
 * sandbox, so files arrive one of two ways:
 *
 *   - through the file picker, which copies them in (this is what end users use);
 *   - by pushing them directly, e.g. `hdc file send <local> <sandbox path>`
 *     (handy while developing, and the path is shown in the UI).
 *
 * A README is written alongside them so the folder explains itself.
 *
 * The class also handles the opposite direction: importing a whole configuration
 * folder, which *replaces* the shared data directory instead of patching it.
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { RimePaths } from './RimePaths';
import { AppLog } from '../common/AppLog';

const DOMAIN: number = 0x0000;
const TAG: string = 'RimeConfigStore';

/** File name of the guidance note written into the configuration folder. */
export const CONFIG_README_NAME: string = 'README.txt';

/** One file the user placed in the Rime configuration folder. */
export interface UserConfigFile {
  name: string;
  sizeBytes: number;
  modifiedMs: number;
  /** True for `*.custom.yaml`, which patch a schema rather than replace it. */
  isCustomPatch: boolean;
  /**
   * True for files Rime maintains itself (installation.yaml, user.yaml).
   * Deleting those loses settings rather than a customisation.
   */
  isRimeGenerated: boolean;
}

/** Result of copying picked files into the configuration folder. */
export interface ImportOutcome {
  imported: string[];
  skipped: string[];
}

/** Progress of a whole-folder import. */
export interface ImportProgress {
  /** Files copied so far. */
  copied: number;
  /** Files discovered during the sizing pass. */
  total: number;
  failed: number;
  /** Name of the file currently being copied, for display. */
  current: string;
}

/**
 * What a quick scan of a picked folder found.
 *
 * Used to refuse an import that would leave the engine with nothing to read,
 * *before* the existing configuration is deleted.
 */
export interface TreeProbe {
  /** False when the folder could not be listed at all. */
  readable: boolean;
  files: number;
  hasYaml: boolean;
  hasDefaultYaml: boolean;
}

/** Result of replacing the shared data directory with a picked folder. */
export interface FolderImportOutcome {
  copied: number;
  failed: number;
  /** Bytes copied, for the summary line. */
  bytes: number;
  /**
   * Entries the provider refused to hand over.
   *
   * Counted separately from `failed` because an unreachable directory loses a
   * whole subtree, which the user has to be told about rather than discovering
   * when the schema will not deploy.
   */
  unreachable: number;
  /** Top-level directory names recorded as they are created, for confirmation. */
  directories: string[];
  /** The resolved import root; used internally to identify the top level. */
  root: string;
}

export class RimeConfigStore {
  /**
   * Guidance written next to the user's files.
   *
   * Kept as a plain text file (not .yaml) so it can never be picked up by Rime
   * as configuration.
   */
  private static readonly README: string =
    'Rime 自定义配置\n' +
    '================\n' +
    '\n' +
    '把 Rime 配置文件放在本目录下，然后回到「一个小输入法」应用点击「重新部署」即可生效。\n' +
    '\n' +
    '常用文件：\n' +
    '\n' +
    '  default.custom.yaml\n' +
    '      全局设置补丁。例如只保留拼音方案：\n' +
    '        patch:\n' +
    '          schema_list:\n' +
    '            - schema: luna_pinyin\n' +
    '\n' +
    '  <方案名>.custom.yaml\n' +
    '      单个方案的补丁，例如 luna_pinyin.custom.yaml。\n' +
    '\n' +
    '  自定义短语\n' +
    '      在 <方案名>.custom.yaml 中：\n' +
    '        patch:\n' +
    '          engine/translators/@next: table_translator@custom_phrase\n' +
    '          custom_phrase:\n' +
    '            db_class: stabledb\n' +
    '            dictionary: ""\n' +
    '            user_dict: custom_phrase\n' +
    '            enable_completion: false\n' +
    '      然后把自定义短语写入 custom_phrase.txt（制表符分隔：文字<Tab>编码<Tab>权重）。\n' +
    '\n' +
    '  新方案\n' +
    '      直接放入 <方案名>.schema.yaml 与配套的 <方案名>.dict.yaml。\n' +
    '\n' +
    '注意：\n' +
    '  * custom 文件是「补丁」，不是完整配置，写错会导致部署失败；\n' +
    '  * build/、sync/、*.userdb/ 由 Rime 自动生成，请勿手工修改；\n' +
    '  * 文件需为 UTF-8 编码，YAML 缩进必须用空格。\n';

  /** Absolute path of the Rime user data directory under a files directory. */
  static getUserDir(filesDir: string): string {
    return `${filesDir}/rime/user`;
  }

  /**
   * Ensures the user directory exists and carries its README.
   *
   * Returns the directory path so callers do not have to recompute it.
   */
  static ensureUserDir(filesDir: string): string {
    const dir: string = RimeConfigStore.getUserDir(filesDir);
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'cannot create %{public}s: %{public}s', dir, err.message);
      return dir;
    }

    const readmePath: string = `${dir}/${CONFIG_README_NAME}`;
    try {
      if (!fs.accessSync(readmePath)) {
        const file = fs.openSync(readmePath,
                                 fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, RimeConfigStore.README);
        } finally {
          fs.closeSync(file);
        }
        hilog.info(DOMAIN, TAG, 'wrote configuration README');
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot write README: %{public}s', err.message);
    }
    return dir;
  }

  /**
   * Lists the configuration files the user has provided.
   *
   * Directories (build/, sync/, *.userdb/) and the README are filtered out: they
   * are either generated or not configuration.
   */
  static list(filesDir: string): UserConfigFile[] {
    const dir: string = RimeConfigStore.getUserDir(filesDir);
    const files: UserConfigFile[] = [];

    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot list %{public}s: %{public}s', dir, err.message);
      return files;
    }

    for (const name of names) {
      if (!RimeConfigStore.isConfigFile(name)) {
        continue;
      }
      try {
        const stat: fs.Stat = fs.statSync(`${dir}/${name}`);
        if (!stat.isFile()) {
          continue;
        }
        const entry: UserConfigFile = {
          name: name,
          sizeBytes: stat.size,
          // fs.Stat.mtime is in seconds.
          modifiedMs: stat.mtime * 1000,
          isCustomPatch: name.endsWith('.custom.yaml'),
          isRimeGenerated: name === 'installation.yaml' || name === 'user.yaml'
        };
        files.push(entry);
      } catch (error) {
        // A file that vanished or cannot be stat'ed is simply not listed.
        continue;
      }
    }

    files.sort((left: UserConfigFile, right: UserConfigFile) =>
      left.name.localeCompare(right.name));
    return files;
  }

  /** True for names that look like Rime configuration. */
  static isConfigFile(name: string): boolean {
    if (name === CONFIG_README_NAME) {
      return false;
    }
    const lower: string = name.toLowerCase();
    return lower.endsWith('.yaml') || lower.endsWith('.yml') ||
           lower.endsWith('.txt') || lower.endsWith('.dict') ||
           lower.endsWith('.json');
  }

  /**
   * Lets the user pick files and copies them into the configuration folder.
   *
   * No suffix filter is applied: Rime accepts several extensions and a wrong
   * filter would hide legitimate files.  Anything that is not a plausible
   * configuration name is reported back as skipped rather than silently dropped.
   */
  static async pickAndImport(context: common.Context): Promise<ImportOutcome> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 50;

    const uris: string[] = await documentPicker.select(options);
    return RimeConfigStore.importUris(context.filesDir, uris);
  }

  /**
   * Copies the given document URIs into the configuration folder.
   *
   * Existing files with the same name are overwritten, which is what makes
   * "import a corrected file" work.
   */
  static importUris(filesDir: string, uris: string[]): ImportOutcome {
    const dir: string = RimeConfigStore.getUserDir(filesDir);
    RimeConfigStore.ensureUserDir(filesDir);
    const imported: string[] = [];
    const skipped: string[] = [];

    for (const uri of uris) {
      const name: string = RimeConfigStore.fileNameOf(uri);
      if (!RimeConfigStore.isSafeFileName(name)) {
        hilog.warn(DOMAIN, TAG, 'skipping suspicious file name: %{public}s', name);
        skipped.push(name.length > 0 ? name : uri);
        continue;
      }
      if (!RimeConfigStore.isConfigFile(name)) {
        hilog.warn(DOMAIN, TAG, 'skipping non-configuration file: %{public}s', name);
        skipped.push(name);
        continue;
      }

      if (RimeConfigStore.copyInto(uri, `${dir}/${name}`)) {
        imported.push(name);
      } else {
        skipped.push(name);
      }
    }

    hilog.info(DOMAIN, TAG, 'import: %{public}d copied, %{public}d skipped',
               imported.length, skipped.length);
    return { imported: imported, skipped: skipped };
  }

  /** Deletes a configuration file the user added. */
  static remove(filesDir: string, name: string): boolean {
    if (!RimeConfigStore.isSafeFileName(name)) {
      return false;
    }
    const path: string = `${RimeConfigStore.getUserDir(filesDir)}/${name}`;
    try {
      fs.unlinkSync(path);
      hilog.info(DOMAIN, TAG, 'removed %{public}s', name);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot remove %{public}s: %{public}s', name, err.message);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // whole-folder import (config bundles)
  // -------------------------------------------------------------------------

  /**
   * Picks a folder and returns its URI without copying anything.
   *
   * The settings page calls this: it cannot put the files where the keyboard can
   * read them, so it hands the URI to the input method extension, which performs
   * the copy into its own sandbox.
   */
  static async pickFolder(context: common.Context): Promise<string | null> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    options.maxSelectNumber = 1;

    const uris: string[] = await documentPicker.select(options);
    AppLog.info(TAG, `pickFolder: ${uris.length} uri(s) returned`);
    return uris.length > 0 ? uris[0] : null;
  }

  /**
   * Replaces the contents of `destDir` with the contents of `sourceDir`.
   *
   * A complete configuration set is routinely tens of megabytes, so the picked
   * tree is copied as a whole instead of file by file.
   *
   * The destination is cleared first, so files that the imported set does not
   * contain do not survive -- the imported folder becomes the configuration
   * rather than being merged into the bundled one.  RimeConfigStore.restoreBundled()
   * puts the shipped configuration back.
   *
   * The source folder itself is not recreated inside the destination: a picked
   * folder named rime-ice must put its default.yaml at <dest>/default.yaml, not
   * at <dest>/rime-ice/default.yaml.
   *
   * Throws when the folder cannot be read or does not look like Rime
   * configuration, in both cases before anything has been deleted.
   */
  static async mergeFolderInto(sourceDir: string,
                               destDir: string,
                               onProgress: (progress: ImportProgress) => void)
    : Promise<FolderImportOutcome> {
    const root: string | null = await RimeConfigStore.resolveListableRoot(sourceDir);
    AppLog.info(TAG, `import: picked uri=${sourceDir}`);
    AppLog.info(TAG, `import: resolved root=${root === null ? '(unresolvable)' : root}`);
    if (root === null) {
      hilog.error(DOMAIN, TAG, 'cannot enumerate picked folder %{public}s', sourceDir);
      throw new Error('无法读取所选文件夹，请换一个位置重试（例如先下载到本机存储）');
    }

    // Size and sanity-check the job before destroying anything.
    const probe: TreeProbe = await RimeConfigStore.probeTree(root);
    if (probe.files === 0) {
      throw new Error('所选文件夹为空');
    }
    if (!probe.hasYaml) {
      throw new Error('所选文件夹内没有 .yaml 配置，已取消导入');
    }
    if (!probe.hasDefaultYaml) {
      hilog.warn(DOMAIN, TAG, 'imported set has no default.yaml; Rime may fail to deploy');
    }

    const progress: ImportProgress = { copied: 0, total: probe.files, failed: 0, current: '' };
    onProgress(progress);

    // Replace rather than merge.  rmdirSync removes the directory and everything
    // under it.
    try {
      if (fs.accessSync(destDir)) {
        fs.rmdirSync(destDir);
      }
      fs.mkdirSync(destDir, true);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'cannot reset %{public}s: %{public}s', destDir, err.message);
      throw new Error(`无法清空内置配置目录：${err.message}`);
    }

    const outcome: FolderImportOutcome = {
      copied: 0,
      failed: 0,
      bytes: 0,
      unreachable: 0,
      directories: [],
      root: root
    };
    await RimeConfigStore.copyTree(root, destDir, progress, outcome, onProgress);

    hilog.info(DOMAIN, TAG, 'folder import: %{public}d copied, %{public}d failed, %{public}d bytes',
               outcome.copied, outcome.failed, outcome.bytes);
    AppLog.info(TAG, `import: ${outcome.copied} copied, ${outcome.failed} failed, ` +
      `${outcome.unreachable} unreachable, ${outcome.bytes} bytes`);
    AppLog.info(TAG, `import: directories=[${outcome.directories.join(', ')}]`);
    AppLog.info(TAG, `import: diagnostics=${probe.files} files, hasYaml=${probe.hasYaml}, ` +
      `hasDefaultYaml=${probe.hasDefaultYaml}`);
    if (outcome.unreachable > 0) {
      AppLog.error(TAG, `import: ${outcome.unreachable} entries could not be read; ` +
        'the imported configuration is incomplete');
    }
    return outcome;
  }

  /**
   * Converts a document URI to a plain filesystem path, or returns the input.
   *
   * Document URIs are not ordinary paths.  Joining a child onto one
   * ("file://docs/.../folder" + "/cn_dicts") and handing the result to fs fails
   * on most providers, which silently loses every file that lives in a
   * subdirectory -- and rime-ice keeps its dictionaries in cn_dicts/ and
   * en_dicts/, and its scripts in lua/.  Working with real paths from the root
   * down makes every descendant an ordinary path.
   */
  private static toFilesystemPath(uriOrPath: string): string {
    try {
      const path: string = new fileUri.FileUri(uriOrPath).path;
      return path.length > 0 ? path : uriOrPath;
    } catch (error) {
      return uriOrPath;
    }
  }

  private static toFileUri(pathOrUri: string): string {
    if (pathOrUri.startsWith('file://')) {
      return pathOrUri;
    }
    try {
      return fileUri.getUriFromPath(pathOrUri);
    } catch (error) {
      return pathOrUri;
    }
  }

  /**
   * Resolves the picked folder into something fs can enumerate.
   *
   * The plain path form is preferred because descendants of a path are paths
   * too; the document URI form is tried next, and the path form once more after
   * that, since providers differ in which of the two they accept.
   */
  private static async resolveListableRoot(uri: string): Promise<string | null> {
    const pathForm: string = RimeConfigStore.toFilesystemPath(uri);
    if (pathForm !== uri && await RimeConfigStore.canEnumerate(pathForm)) {
      hilog.info(DOMAIN, TAG, 'listing via path form: %{public}s', pathForm);
      return pathForm;
    }
    if (await RimeConfigStore.canEnumerate(uri)) {
      return uri;
    }
    if (pathForm !== uri && await RimeConfigStore.canEnumerate(pathForm)) {
      return pathForm;
    }
    return null;
  }

  private static async canEnumerate(target: string): Promise<boolean> {
    try {
      await fs.listFile(target);
      return true;
    } catch (error) {
      return false;
    }
  }

  /**
   * Resolves one entry inside an already-enumerable directory.
   *
   * The parent may be reachable as a path while a child needs the URI form, or
   * the other way round, so both are attempted before giving up.  A null result
   * means the entry is genuinely unreachable and must be reported rather than
   * silently dropped.
   */
  private static async resolveChild(parent: string, name: string): Promise<string | null> {
    const joined: string = `${parent}/${name}`;
    const candidates: string[] = [joined];
    if (joined.startsWith('file://')) {
      const pathForm: string = RimeConfigStore.toFilesystemPath(joined);
      if (pathForm !== joined) {
        candidates.push(pathForm);
      }
    } else {
      const uriForm: string = RimeConfigStore.toFileUri(joined);
      if (uriForm !== joined) {
        candidates.push(uriForm);
      }
    }

    for (const candidate of candidates) {
      if (await RimeConfigStore.isReachable(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  /**
   * True when the entry can be opened, listed or stat'ed.
   *
   * Three probes because document providers differ in what they allow: stat()
   * for most, open() for files whose provider refuses stat(), listFile() for
   * directories.
   */
  private static async isReachable(target: string): Promise<boolean> {
    try {
      fs.statSync(target);
      return true;
    } catch (error) {
      // fall through to the weaker probes
    }
    try {
      const file = fs.openSync(target, fs.OpenMode.READ_ONLY);
      fs.closeSync(file);
      return true;
    } catch (error) {
      // fall through
    }
    return RimeConfigStore.canEnumerate(target);
  }

  /**
   * Decides whether a picked entry is a directory.
   *
   * stat() is tried first because it is cheap and authoritative, but the file
   * APIs document themselves as taking sandbox paths while a picked folder
   * arrives as a document URI, and some document providers refuse stat() on
   * those.  listFile() is the fallback: it succeeds for a directory and fails
   * for a regular file.
   */
  private static async isDirectory(target: string): Promise<boolean> {
    try {
      return fs.statSync(target).isDirectory();
    } catch (error) {
      // Providers that refuse stat() on a document URI still answer listFile()
      // for directories, and open() succeeds for regular files.
      if (await RimeConfigStore.canEnumerate(target)) {
        return true;
      }
      try {
        const file = fs.openSync(target, fs.OpenMode.READ_ONLY);
        fs.closeSync(file);
        return false;
      } catch (nested) {
        return false;
      }
    }
  }

  /** Size of a picked file, or 0 when the provider cannot report one. */
  private static fileSizeOrZero(target: string): number {
    try {
      return fs.statSync(target).size;
    } catch (error) {
      return 0;
    }
  }

  /**
   * Scans a folder before it is imported.
   *
   * The import replaces the bundled schemas, so the folder has to at least look
   * like Rime configuration; otherwise the engine would be left with nothing to
   * deploy.
   */
  private static async probeTree(root: string): Promise<TreeProbe> {
    const probe: TreeProbe = {
      readable: false,
      files: 0,
      hasYaml: false,
      hasDefaultYaml: false
    };
    await RimeConfigStore.probeInto(root, probe, true);
    return probe;
  }

  private static async probeInto(dir: string, probe: TreeProbe, isRoot: boolean): Promise<void> {
    let names: string[] = [];
    try {
      names = await fs.listFile(dir);
    } catch (error) {
      if (isRoot) {
        const err = error as BusinessError;
        hilog.warn(DOMAIN, TAG, 'cannot list picked folder %{public}s: %{public}s',
                   dir, err.message);
      }
      return;
    }
    if (isRoot) {
      probe.readable = true;
    }

    for (const name of names) {
      const child: string | null = await RimeConfigStore.resolveChild(dir, name);
      if (child === null) {
        continue;
      }
      if (await RimeConfigStore.isDirectory(child)) {
        await RimeConfigStore.probeInto(child, probe, false);
        continue;
      }
      probe.files += 1;
      const lower: string = name.toLowerCase();
      if (lower.endsWith('.yaml') || lower.endsWith('.yml')) {
        probe.hasYaml = true;
        if (lower === 'default.yaml') {
          probe.hasDefaultYaml = true;
        }
      }
    }
  }

  /**
   * Recursive worker for mergeFolderInto().
   *
   * A file that cannot be copied is counted and skipped rather than aborting the
   * whole import: a large bundle should not be lost to one bad entry.
   */
  private static async copyTree(sourceDir: string,
                                destDir: string,
                                progress: ImportProgress,
                                outcome: FolderImportOutcome,
                                onProgress: (progress: ImportProgress) => void)
    : Promise<void> {
    let names: string[] = [];
    try {
      names = await fs.listFile(sourceDir);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot list %{public}s: %{public}s', sourceDir, err.message);
      return;
    }

    for (const name of names) {
      if (!RimeConfigStore.isSafeFileName(name)) {
        progress.failed++;
        outcome.failed++;
        continue;
      }

      const destChild: string = `${destDir}/${name}`;
      // Resolve before stat'ing: a child of a document URI is not necessarily
      // reachable by concatenation, and treating an unreachable directory as a
      // file used to lose whole subtrees silently.
      const sourceChild: string | null = await RimeConfigStore.resolveChild(sourceDir, name);
      if (sourceChild === null) {
        hilog.warn(DOMAIN, TAG, 'unreachable entry %{public}s/%{public}s', sourceDir, name);
        progress.failed++;
        outcome.failed++;
        outcome.unreachable++;
        continue;
      }

      const childIsDirectory: boolean = await RimeConfigStore.isDirectory(sourceChild);
      const fileSize: number = childIsDirectory ? 0 : RimeConfigStore.fileSizeOrZero(sourceChild);

      if (childIsDirectory) {
        try {
          if (!fs.accessSync(destChild)) {
            fs.mkdirSync(destChild, true);
          }
          if (sourceDir === outcome.root) {
            outcome.directories.push(name);
          }
        } catch (error) {
          const err = error as BusinessError;
          hilog.warn(DOMAIN, TAG, 'cannot create %{public}s: %{public}s', destChild, err.message);
          progress.failed++;
          outcome.failed++;
          continue;
        }
        await RimeConfigStore.copyTree(sourceChild, destChild, progress, outcome, onProgress);
        continue;
      }

      progress.current = name;
      if (await RimeConfigStore.overwriteFile(sourceChild, destChild)) {
        progress.copied++;
        outcome.copied++;
        outcome.bytes += fileSize;
      } else {
        progress.failed++;
        outcome.failed++;
      }
      onProgress(progress);
    }
  }

  /**
   * Copies one file, overwriting any existing destination.
   *
   * copyFile()'s default mode (0, documented as the only supported value)
   * already overwrites the target and truncates whatever is left over, which is
   * what replacing the shared data directory needs.
   */
  private static async overwriteFile(sourceFile: string, destination: string): Promise<boolean> {
    try {
      fs.copyFileSync(sourceFile, destination);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'copy %{public}s failed (code %{public}d): %{public}s',
                 destination, err.code, err.message);
      return false;
    }
  }

  /**
   * Deletes the shared data directory so the bundled data is extracted again.
   *
   * This is the escape hatch for a folder import that replaced the schemas with
   * something unusable.
   */
  static async restoreBundled(context: common.Context, sharedDir: string): Promise<void> {
    try {
      if (fs.accessSync(sharedDir)) {
        fs.rmdirSync(sharedDir);
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot clear %{public}s: %{public}s', sharedDir, err.message);
    }
    await RimePaths.reinstallSharedData(context, sharedDir);
  }

  // -------------------------------------------------------------------------
  // internals
  // -------------------------------------------------------------------------

  /** Extracts the file name from a document URI. */
  private static fileNameOf(uri: string): string {
    try {
      return new fileUri.FileUri(uri).name;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot resolve name of %{public}s: %{public}s', uri, err.message);
      return '';
    }
  }

  /**
   * Rejects names that would escape the configuration folder.
   *
   * The name comes from the picked document, or from an entry inside a picked
   * folder, so it is untrusted input even though the picker usually returns a
   * plain name.
   */
  private static isSafeFileName(name: string): boolean {
    if (name.length === 0 || name === '.' || name === '..') {
      return false;
    }
    return name.indexOf('/') < 0 && name.indexOf('\\') < 0 && name.indexOf('\u0000') < 0;
  }

  private static copyInto(sourceUri: string, destination: string): boolean {
    let source: fs.File | null = null;
    let target: fs.File | null = null;
    try {
      source = fs.openSync(sourceUri, fs.OpenMode.READ_ONLY);
      target = fs.openSync(destination,
                           fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.copyFileSync(source.fd, target.fd);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot copy into %{public}s: %{public}s',
                 destination, err.message);
      return false;
    } finally {
      if (target !== null) {
        try {
          fs.closeSync(target);
        } catch (ignored) {
        }
      }
      if (source !== null) {
        try {
          fs.closeSync(source);
        } catch (ignored) {
        }
      }
    }
  }
}
