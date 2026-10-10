/*
 * Type declarations for libentry.so -- the Rime engine bindings.
 *
 * Keep this file in sync with entry/src/main/cpp/rime_napi/napi_init.cpp: it is
 * the contract between the native engine and the ArkTS input method.
 *
 * The `export const name: (...) => ...` form (rather than `export function`) is
 * the convention DevEco uses for native modules, because ArkTS exposes the
 * module's exports as a single default-imported object.
 */

/**
 * Where librime keeps its data.
 *
 * `sharedDataDir` holds the schema and dictionary sources shipped with the
 * application; `userDataDir` must be writable and holds the deployed
 * dictionaries plus user history.
 */
export interface RimeConfig {
  /** Directory containing default.yaml, *.schema.yaml and friends. */
  sharedDataDir: string;
  /** Writable directory for deployed data and user records. */
  userDataDir: string;
  /** Where librime writes its logs. Empty means stderr only. */
  logDir?: string;
  /** Client name passed to librime; must start with "rime.". */
  appName?: string;
  /** 0 = INFO, 1 = WARNING, 2 = ERROR, 3 = FATAL. */
  minLogLevel?: number;
}

export interface RimeCandidate {
  text: string;
  comment: string;
}

export interface RimeMenu {
  pageSize: number;
  pageNo: number;
  isLastPage: boolean;
  highlightedCandidateIndex: number;
  numCandidates: number;
  candidates: RimeCandidate[];
  /** Keys that select candidates on the current page, e.g. "1234567890". */
  selectKeys: string;
}

export interface RimeComposition {
  /** Length of the input in characters. */
  length: number;
  cursorPos: number;
  selStart: number;
  selEnd: number;
  /** The raw input being composed. */
  preedit: string;
}

export interface RimeContext {
  composition: RimeComposition;
  menu: RimeMenu;
  /** What would be committed if the highlighted candidate were chosen. */
  commitTextPreview: string;
}

export interface RimeStatus {
  schemaId: string;
  schemaName: string;
  isDisabled: boolean;
  isComposing: boolean;
  isAsciiMode: boolean;
  isFullShape: boolean;
  isSimplified: boolean;
  isTraditional: boolean;
  isAsciiPunct: boolean;
}

export interface RimeSchemaItem {
  schemaId: string;
  name: string;
}

/**
 * Deployment/schema/option events raised by librime.
 *
 * - schema:  value is "<schema_id>/<schema_name>"
 * - option:  value is the option name, optionally prefixed with "!" when the
 *            option is being turned off
 * - deploy:  value is "start", "success" or "failure" (sessionId is 0)
 */
export interface RimeNotification {
  sessionId: number;
  type: string;
  value: string;
}

/** Rime key modifier bits, mirroring librime's `RimeModifier` enum. */
export interface RimeModifierConstants {
  readonly NONE: number;
  readonly SHIFT: number;
  readonly LOCK: number;
  readonly CONTROL: number;
  readonly ALT: number;
  readonly MOD2: number;
  readonly MOD3: number;
  readonly MOD4: number;
  readonly MOD5: number;
  readonly SUPER: number;
  readonly HYPER: number;
  readonly META: number;
  readonly RELEASE: number;
  readonly MODIFIER_MASK: number;
}

/** Points librime at its data directories. Must precede `initialize`. */
export const configure: (config: RimeConfig) => boolean;

/** Brings librime up. Returns false if `configure` was not called first. */
export const initialize: () => boolean;

/** Shuts librime down. */
export const finalize: () => boolean;

/**
 * Tears librime down and brings it back up with the same directories.
 *
 * librime caches parsed config files for the lifetime of the engine, so a
 * redeploy is only visible after this: without it schema_open() keeps returning
 * the configuration parsed at start-up.
 */
export const restart: () => boolean;

/**
 * Whether a named engine component is registered.
 *
 * Plugins register components at start-up, so this distinguishes "the plugin is
 * built in" from "the schema asked for something that does not exist" -- both
 * look identical from the configuration alone.
 */
export const hasComponent: (name: string) => boolean;

/**
 * The `grammar/language` the session's schema declares, or "" when it declares
 * none.  The grammar plugin loads `<language>.gram` from the data directories.
 */
export const getGrammarLanguage: (sessionId: number) => string;

export const isInitialized: () => boolean;

/** Runs the deployer synchronously. Slow on first use; prefer maintenance. */
export const deploy: () => boolean;

/** Starts deployment on librime's maintenance thread and returns immediately. */
export const startMaintenance: (fullCheck: boolean) => boolean;

export const isMaintenanceMode: () => boolean;

/** Blocks until the maintenance thread finishes. */
export const joinMaintenanceThread: () => boolean;

/** Creates an input session. Throws if the engine is not ready. */
export const createSession: () => number;

export const destroySession: (sessionId: number) => boolean;

/**
 * Sends a keystroke to the engine.
 *
 * `keysym` is an X11 key symbol (ASCII for printable characters, 0xFFxx for
 * special keys) and `modifiers` is a bitmask of librime's modifier constants.
 */
export const processKey: (sessionId: number, keysym: number, modifiers: number) => boolean;

export const commitComposition: (sessionId: number) => boolean;

export const clearComposition: (sessionId: number) => void;

export interface RimeCandidateListItem {
  /** Index into the whole candidate list, as accepted by selectCandidate. */
  index: number;
  text: string;
  comment: string;
}

/** Returns null when the session has no context. */
export const getContext: (sessionId: number) => RimeContext | null;

/**
 * The entire candidate list, not just the current page.
 *
 * The keyboard paginates on its own so the number of candidates per page can
 * follow how wide they are; `index` is the global index to pass to
 * selectCandidate.
 */
export const getCandidateList: (sessionId: number) => RimeCandidateListItem[];

/** Returns the pending commit text, or null when there is nothing to commit. */
export const getCommit: (sessionId: number) => string | null;

export const getStatus: (sessionId: number) => RimeStatus | null;

export const selectCandidate: (sessionId: number, index: number) => boolean;

export const deleteCandidate: (sessionId: number, index: number) => boolean;

export const changePage: (sessionId: number, backward: boolean) => boolean;

export const setOption: (sessionId: number, name: string, value: boolean) => void;

export const getOption: (sessionId: number, name: string) => boolean;

export const getSchemaList: () => RimeSchemaItem[];

export const getCurrentSchema: (sessionId: number) => string;

/** A toggle declared by a schema's `switches:` block. */
export interface RimeSchemaSwitch {
  /** Option name for a plain on/off switch; empty for a radio group. */
  name: string;
  /**
   * Option names for a radio group (the schema's `options:` form), where exactly
   * one is on at a time. Empty for a plain switch.
   */
  options: string[];
  /** State labels; the option's value indexes into this list. */
  states: string[];
  /** Value the schema asks for on reset, or -1 when unspecified. */
  reset: number;
}

/**
 * The toggles a schema declares, read from its YAML with user patches applied.
 *
 * This is what the in-keyboard settings panel is built from, so the panel
 * follows the Rime configuration instead of a hardcoded list.
 */
export const getSchemaSwitches: (schemaId: string) => RimeSchemaSwitch[];

export const selectSchema: (sessionId: number, schemaId: string) => boolean;

export const getVersion: () => string;

export const getUserDataDir: () => string;

export const getSharedDataDir: () => string;

/** Registers the deployment/option notification callback. */
export const setNotificationCallback: (callback: (notification: RimeNotification) => void) => void;

/** Polling alternative to `setNotificationCallback`. */
export const pollNotification: () => RimeNotification | null;

/** librime's modifier bit values. */
export const RimeModifier: RimeModifierConstants;
