/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * In-app log buffer.
 *
 * The device's hilog cannot be read back by the user, so anything worth
 * diagnosing is also kept here and shown in the settings page's log card and in
 * the keyboard's diagnostics panel, where it can be read and copied.  Messages
 * are mirrored to hilog so a connected debugger still sees them.
 *
 * The buffer is process-local.  The input-method extension deliberately runs in
 * its own process (see module.json5), so the app page and the keyboard each keep
 * their own buffer and neither can read the other's.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;

/** Kept small: this is a diagnostic aid, not a record. */
const MAX_ENTRIES: number = 400;

export enum LogLevel {
  Debug = 0,
  Info = 1,
  Warn = 2,
  Error = 3
}

export interface LogEntry {
  /** Wall-clock time, HH:MM:SS.mmm. */
  time: string;
  level: LogLevel;
  tag: string;
  message: string;
}

function timestamp(): string {
  const now: Date = new Date();
  const pad = (value: number, width: number): string => value.toString().padStart(width, '0');
  return `${pad(now.getHours(), 2)}:${pad(now.getMinutes(), 2)}:${pad(now.getSeconds(), 2)}` +
    `.${pad(now.getMilliseconds(), 3)}`;
}

function levelName(level: LogLevel): string {
  switch (level) {
    case LogLevel.Debug: return 'D';
    case LogLevel.Info: return 'I';
    case LogLevel.Warn: return 'W';
    default: return 'E';
  }
}

export class AppLog {
  private static entries: LogEntry[] = [];
  private static listeners: (() => void)[] = [];

  static write(level: LogLevel, tag: string, message: string): void {
    const entry: LogEntry = { time: timestamp(), level: level, tag: tag, message: message };

    // Mirror to hilog first: if the buffer overflows or the UI is never opened,
    // the message is still reachable through a debugger.
    switch (level) {
      case LogLevel.Error:
        hilog.error(DOMAIN, tag, '%{public}s', message);
        break;
      case LogLevel.Warn:
        hilog.warn(DOMAIN, tag, '%{public}s', message);
        break;
      default:
        hilog.info(DOMAIN, tag, '%{public}s', message);
        break;
    }

    AppLog.entries.push(entry);
    if (AppLog.entries.length > MAX_ENTRIES) {
      AppLog.entries.splice(0, AppLog.entries.length - MAX_ENTRIES);
    }
    for (const listener of AppLog.listeners) {
      listener();
    }
  }

  static debug(tag: string, message: string): void {
    AppLog.write(LogLevel.Debug, tag, message);
  }

  static info(tag: string, message: string): void {
    AppLog.write(LogLevel.Info, tag, message);
  }

  static warn(tag: string, message: string): void {
    AppLog.write(LogLevel.Warn, tag, message);
  }

  static error(tag: string, message: string): void {
    AppLog.write(LogLevel.Error, tag, message);
  }

  /** Records an exception with its stack, which is what makes a bug report useful. */
  static exception(tag: string, operation: string, error: Object): void {
    const err = error as Error;
    const detail: string = err !== undefined && err.message !== undefined
      ? err.message
      : String(error);
    const stack: string = err !== undefined && err.stack !== undefined ? `\n${err.stack}` : '';
    AppLog.write(LogLevel.Error, tag, `${operation}: ${detail}${stack}`);
  }

  static snapshot(): LogEntry[] {
    return AppLog.entries.slice();
  }

  static clear(): void {
    AppLog.entries = [];
    for (const listener of AppLog.listeners) {
      listener();
    }
  }

  static subscribe(listener: () => void): void {
    AppLog.listeners.push(listener);
  }

  static unsubscribe(listener: () => void): void {
    const index: number = AppLog.listeners.indexOf(listener);
    if (index >= 0) {
      AppLog.listeners.splice(index, 1);
    }
  }

  /** Whole buffer as plain text, for the clipboard. */
  static asText(): string {
    if (AppLog.entries.length === 0) {
      return '(no log entries)';
    }
    const lines: string[] = AppLog.entries.map((entry: LogEntry) =>
      `${entry.time} ${levelName(entry.level)}/${entry.tag}: ${entry.message}`);
    return lines.join('\n');
  }

  static errorCount(): number {
    let count: number = 0;
    for (const entry of AppLog.entries) {
      if (entry.level === LogLevel.Error) {
        count++;
      }
    }
    return count;
  }
}
