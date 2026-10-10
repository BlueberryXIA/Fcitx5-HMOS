/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * Backup extension.
 *
 * Declared in module.json5 as EntryBackupAbility.  The Rime user directory is
 * intentionally left mostly to the default backup behaviour: the deployed
 * tables under rime/user/build are excluded through backup_config.json because
 * they are rebuilt on first run and would waste the backup quota.
 */

import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryBackupAbility';

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'onBackup');
  }

  async onRestore(bundleVersion: BundleVersion): Promise<void> {
    hilog.info(DOMAIN, TAG, 'onRestore from %{public}s', JSON.stringify(bundleVersion));
  }
}
