/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Filesystem layout librime works with.
 *
 * Rime needs a read-only "shared" data directory (schemas, dictionaries, grammar
 * models) and a writable "user" directory (deployed tables, user history, and the
 * *.custom.yaml patches the user supplies).  The shared half ships inside the HAP
 * as rawfile content, which is not a filesystem path, so it is extracted into the
 * application's files directory on first run and topped up with files the bundle
 * gained later.
 *
 * This lives in its own module rather than inside RimeEngineService so that
 * RimeConfigStore can re-extract the shared data without importing the engine,
 * which would be a cycle.
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'RimePaths';

/** Name of the rawfile directory holding the Rime data. */
const RAWFILE_RIME_ROOT: string = 'rime';

/**
 * The directories librime is configured with, resolved by prepare().
 */
export class RimePaths {
  sharedDataDir: string = '';
  userDataDir: string = '';
  logDir: string = '';

  /**
   * Marker file rewritten after every successful deployment.
   *
   * Its contents are a timestamp.  An input-method extension and the app's own
   * UI can run in different processes, so a component that did not itself run
   * the deployment can tell from this file that the on-disk Rime configuration
   * changed and reload.  The leading dot keeps it out of sight, and the name
   * matches no configuration suffix, so RimeConfigStore.list() never shows it.
   */
  static deployMarkerPath(userDataDir: string): string {
    return `${userDataDir}/.deploy-stamp`;
  }

  static async prepare(context: common.Context): Promise<RimePaths> {
    const paths: RimePaths = new RimePaths();
    const filesDir: string = context.filesDir;
    paths.sharedDataDir = `${filesDir}/rime/shared`;
    paths.userDataDir = `${filesDir}/rime/user`;
    paths.logDir = `${context.cacheDir}/rime/log`;

    RimePaths.ensureDir(paths.sharedDataDir);
    // Doubles as the folder users drop their own Rime configuration into.
    // RimeConfigStore adds the README once the engine boots.
    RimePaths.ensureDir(paths.userDataDir);
    RimePaths.ensureDir(paths.logDir);

    await RimePaths.extractSharedData(context, paths.sharedDataDir);
    // Then fill in anything the bundle gained since this install was created.
    // Additive only: existing files are never overwritten or deleted.
    await RimePaths.repairSharedData(context, paths.sharedDataDir);
    return paths;
  }

  private static ensureDir(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  }

  /**
   * Copies the bundled Rime data into `destination`, overwriting the files it
   * contains.  Anything in `destination` that the bundle does not provide is
   * left alone.
   *
   * Used to undo a configuration-folder import that replaced the bundled schemas
   * with something Rime cannot deploy.  The caller clears `destination` first.
   */
  static async reinstallSharedData(context: common.Context, destination: string): Promise<void> {
    RimePaths.ensureDir(destination);
    await RimePaths.copyRawDirectory(context, RAWFILE_RIME_ROOT, destination);
    hilog.info(DOMAIN, TAG, 'bundled shared data restored');
  }

  /**
   * Copies the bundled Rime data into `destination` on a fresh installation.
   *
   * The presence of default.yaml is the marker: librime cannot start without it,
   * so a directory that already has it is treated as already extracted.
   */
  static async extractSharedData(context: common.Context, destination: string): Promise<void> {
    const defaultYamlPath: string = `${destination}/default.yaml`;
    if (fs.accessSync(defaultYamlPath)) {
      hilog.info(DOMAIN, TAG, 'Rime shared data already extracted');
      return;
    }

    hilog.info(DOMAIN, TAG, 'Extracting Rime shared data into %{public}s', destination);
    RimePaths.ensureDir(destination);
    await RimePaths.copyRawDirectory(context, RAWFILE_RIME_ROOT, destination);
    hilog.info(DOMAIN, TAG, 'Rime shared data extracted');
  }

  /**
   * Copies bundled files that are missing from `destination`, adding nothing
   * else and overwriting nothing.
   *
   * extractSharedData() only runs on a fresh install, so an installation that
   * already has default.yaml would never receive files added to the bundle
   * later -- the opencc/ conversion data, for instance, without which the
   * schema's simplifier filters silently do nothing.  Existing files are left
   * alone because the user may have replaced them on purpose.
   */
  static async repairSharedData(context: common.Context, destination: string): Promise<void> {
    RimePaths.ensureDir(destination);
    const added: number = await RimePaths.copyMissingRawFiles(
        context, RAWFILE_RIME_ROOT, destination);
    if (added > 0) {
      hilog.info(DOMAIN, TAG, 'restored %{public}d missing bundled Rime file(s)', added);
    }
  }

  /** Recursively copies a rawfile directory into an ordinary directory. */
  private static async copyRawDirectory(context: common.Context, rawDir: string, destDir: string): Promise<void> {
    let entries: string[] = [];
    try {
      entries = await context.resourceManager.getRawFileList(rawDir);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getRawFileList(%{public}s) failed: %{public}s', rawDir, err.message);
      return;
    }

    for (const name of entries) {
      const rawPath: string = `${rawDir}/${name}`;
      const destPath: string = `${destDir}/${name}`;
      if (await RimePaths.isRawDirectory(context, rawPath)) {
        RimePaths.ensureDir(destPath);
        await RimePaths.copyRawDirectory(context, rawPath, destPath);
      } else {
        await RimePaths.copyRawFile(context, rawPath, destPath);
      }
    }
  }

  /**
   * Worker for repairSharedData(): copies only what is absent, and returns how
   * many files it added.
   */
  private static async copyMissingRawFiles(context: common.Context,
                                           rawDir: string,
                                           destDir: string): Promise<number> {
    let entries: string[] = [];
    try {
      entries = await context.resourceManager.getRawFileList(rawDir);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getRawFileList(%{public}s) failed: %{public}s', rawDir, err.message);
      return 0;
    }

    let added: number = 0;
    for (const name of entries) {
      const rawPath: string = `${rawDir}/${name}`;
      const destPath: string = `${destDir}/${name}`;
      if (await RimePaths.isRawDirectory(context, rawPath)) {
        RimePaths.ensureDir(destPath);
        added += await RimePaths.copyMissingRawFiles(context, rawPath, destPath);
        continue;
      }
      if (fs.accessSync(destPath)) {
        continue;
      }
      await RimePaths.copyRawFile(context, rawPath, destPath);
      added += 1;
    }
    return added;
  }

  /**
   * True when a rawfile path is a directory.
   *
   * getRawFileList() succeeds for directories and throws for regular files,
   * which is what this probe relies on.
   */
  private static async isRawDirectory(context: common.Context, rawPath: string): Promise<boolean> {
    try {
      const children: string[] = await context.resourceManager.getRawFileList(rawPath);
      return children !== undefined;
    } catch (error) {
      return false;
    }
  }

  private static async copyRawFile(context: common.Context, rawPath: string, destPath: string): Promise<void> {
    const content: Uint8Array = await context.resourceManager.getRawFileContent(rawPath);
    const file = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(file);
    }
  }
}

