/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */
/*
 * The soft keyboard shown by the Rime input-method extension.
 *
 * Layout, key widths and colours follow fcitx5-android (see
 * inputmethod/keyboard/): the same four rows on the letter panel, the same
 * numpad arrangement on the number panel, MaterialLight colours, and paged
 * grids for symbols and emoji.
 *
 * ---------------------------------------------------------------------------
 * Two ArkUI rules shape this file; both caused visible bugs before.
 *
 * 1. Every @Builder here is ZERO-ARGUMENT.  A @Builder that takes parameters
 *    uses value semantics, and ArkUI will not re-run it when state changes: a
 *    parameterised "中/英" key kept its original label forever, and a
 *    parameterised page arrow froze its enabled flag at the first render and
 *    became permanently unclickable.  Passing constants instead of state does
 *    not make this safe -- the builder body still reads `this`, so it still has
 *    to be re-run.  Key rendering is therefore inlined inside ForEach, and panel
 *    switching reads `this.panel` rather than taking a flag.
 *
 * 2. Every key Row is explicitly `width('100%')`.  Without it a Row wraps its
 *    content, layoutWeight() has no definite parent size to divide, and keys end
 *    up sized by their text -- a different width per letter.
 * ---------------------------------------------------------------------------
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { KeyboardHub } from '../inputmethod/KeyboardHub';
import {
  CandidateEntry,
  RimeEngineService,
  RimeState,
  RimeStateListener,
  SchemaEntry,
  SwitchEntry,
  emptyRimeState
} from '../inputmethod/RimeEngineService';
import { FolderImportOutcome, ImportProgress } from '../inputmethod/RimeConfigStore';
import {
  CANDIDATE_BAR_HEIGHT_VP,
  KEYBOARD_HEIGHT_VP
} from '../inputmethod/KeyboardMetrics';
import { CANDIDATE_CHIP_HEIGHT_VP } from '../inputmethod/keyboard/KeyboardTheme';
import {
  GRID_TEXT_SIZE,
  KEY_ALT_TEXT_SIZE,
  KEY_GAP_VP,
  KEY_HINT_TEXT_SIZE,
  KEY_RADIUS_VP,
  KEY_ROW_HEIGHT_VP,
  KEY_TEXT_SIZE,
  KeyboardTheme,
  PICKER_TAB_HEIGHT_VP,
  ROW_GAP_VP
} from '../inputmethod/keyboard/KeyboardTheme';
import {
  KeyKind,
  KeySpec,
  LETTER_ROWS,
  NUMBER_ROWS,
  PanelKind,
  resolveRows
} from '../inputmethod/keyboard/KeyboardLayouts';
import {
  EMOJI_CATEGORIES,
  EMOJI_COLUMNS,
  EMOJI_PAGE_SIZE,
  PickerCategory,
  SYMBOL_CATEGORIES,
  SYMBOL_COLUMNS,
  SYMBOL_PAGE_SIZE
} from '../inputmethod/keyboard/PickerData';

const DOMAIN: number = 0x0000;
const TAG: string = 'KeyboardPanel';

// Rough per-character advance widths, in vp, used to guess a candidate chip's
// width without measuring the text.
const CJK_ADVANCE_VP: number = 18;
const LATIN_ADVANCE_VP: number = 9.5;
/** Padding inside a chip (left + right), and the gap between chips. */
const CANDIDATE_PADDING_VP: number = 20;
const CANDIDATE_GAP_VP: number = 6;
/** Bar width assumed until onAreaChange reports the real one. */
const DEFAULT_BAR_WIDTH_VP: number = 320;

/** Travel, in vp, before a horizontal drag counts as a page swipe. */
const PICKER_SWIPE_DISTANCE_VP: number = 24;

// Expanded once; the tables never change at runtime.
const LETTER_KEYS: KeySpec[][] = resolveRows(LETTER_ROWS);
const NUMBER_KEYS: KeySpec[][] = resolveRows(NUMBER_ROWS);

/** A run of candidates shown together. `start` indexes state.candidates. */
interface CandidatePage {
  start: number;
  count: number;
}

@Entry
@Component
struct KeyboardPanel {
  /** Latest snapshot from the engine; replacing it is what re-renders the UI. */
  @State state: RimeState = emptyRimeState();

  /** Shift behaves like a one-shot modifier, as on most soft keyboards. */
  @State shiftActive: boolean = false;

  /** Which panel is showing. */
  @State panel: PanelKind = PanelKind.Letter;

  /** Candidate pagination is ours, not librime's. */
  @State uiPage: number = 0;
  /** Width available to the candidate strip, measured at layout. */
  @State barWidth: number = DEFAULT_BAR_WIDTH_VP;

  /** Picker position: which category tab and which page within it. */
  @State symbolCategory: number = 0;
  @State symbolPage: number = 0;
  @State emojiCategory: number = 0;
  @State emojiPage: number = 0;

  // Settings panel, opened from the three-dot key.
  @State settingsOpen: boolean = false;
  @State switchEntries: SwitchEntry[] = [];
  @State schemaEntries: SchemaEntry[] = [];
  @State activeSchemaId: string = '';
  @State settingsNotice: string = '';
  @State diagnosticsOpen: boolean = false;
  @State importing: boolean = false;
  @State importStatus: string = '';

  private hub: KeyboardHub = KeyboardHub.getInstance();
  private engine: RimeEngineService = RimeEngineService.getInstance();

  private listener: RimeStateListener = (state: RimeState) => {
    const listChanged: boolean = KeyboardPanel.listChanged(this.state, state);
    const configChanged: boolean = state.configGeneration !== this.state.configGeneration;

    this.state = state;
    if (listChanged) {
      this.uiPage = 0;
    }
    if (configChanged) {
      hilog.info(DOMAIN, TAG, 'rime configuration changed; reloading settings');
      this.refreshSettings();
    }
  };

  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'keyboard panel appeared');
    this.engine.subscribe(this.listener);
  }

  aboutToDisappear(): void {
    hilog.info(DOMAIN, TAG, 'keyboard panel disappeared');
    this.engine.unsubscribe(this.listener);
  }

  build() {
    Stack() {
      Column() {
        this.CandidateBar()
        this.MessageLine()
        this.KeyboardBody()
      }
      .width('100%')
      .height('100%')

      if (this.settingsOpen) {
        this.SettingsPanel()
      }
    }
    .width('100%')
    .height(KEYBOARD_HEIGHT_VP)
    .backgroundColor(KeyboardTheme.keyboard)
  }

  // -----------------------------------------------------------------------
  // candidate strip, its pagination and the message line
  // -----------------------------------------------------------------------

  /** True when the preedit, the candidate count or the first candidate changed. */
  private static listChanged(previous: RimeState, next: RimeState): boolean {
    if (previous.preedit !== next.preedit) {
      return true;
    }
    if (previous.candidates.length !== next.candidates.length) {
      return true;
    }
    if (next.candidates.length > 0 && previous.candidates.length > 0) {
      return previous.candidates[0].text !== next.candidates[0].text;
    }
    return false;
  }

  private static estimatedWidth(text: string): number {
    let width: number = CANDIDATE_PADDING_VP;
    for (let i = 0; i < text.length; i++) {
      width += text.charCodeAt(i) >= 0x2e80 ? CJK_ADVANCE_VP : LATIN_ADVANCE_VP;
    }
    return width;
  }

  /**
   * Cuts the candidate list into pages that fit the available width.
   *
   * A page always holds at least one candidate, even one wider than the bar, so
   * an unusually long candidate cannot produce an empty page and stall paging.
   */
  private static paginate(candidates: CandidateEntry[], availableWidth: number): CandidatePage[] {
    const pages: CandidatePage[] = [];
    if (candidates.length === 0) {
      return pages;
    }

    let start: number = 0;
    while (start < candidates.length) {
      let usedWidth: number = 0;
      let candidateCount: number = 0;
      while (start + candidateCount < candidates.length) {
        const width: number = KeyboardPanel.estimatedWidth(candidates[start + candidateCount].text) +
          CANDIDATE_GAP_VP;
        if (candidateCount > 0 && usedWidth + width > availableWidth) {
          break;
        }
        usedWidth += width;
        candidateCount++;
      }
      const page: CandidatePage = { start: start, count: candidateCount };
      pages.push(page);
      start += candidateCount;
    }
    return pages;
  }

  private candidatePages(): CandidatePage[] {
    return KeyboardPanel.paginate(this.state.candidates, this.barWidth);
  }

  private candidatePageCount(): number {
    return this.candidatePages().length;
  }

  private currentCandidatePage(): CandidatePage | null {
    const pages: CandidatePage[] = this.candidatePages();
    if (pages.length === 0) {
      return null;
    }
    return pages[Math.min(this.uiPage, pages.length - 1)];
  }

  /** Global candidate index shown first on the current page. */
  private firstVisibleIndex(): number {
    const page: CandidatePage | null = this.currentCandidatePage();
    if (page === null || this.state.candidates.length === 0) {
      return 0;
    }
    return this.state.candidates[page.start].index;
  }

  private visibleCandidates(): CandidateEntry[] {
    const page: CandidatePage | null = this.currentCandidatePage();
    if (page === null) {
      return [];
    }
    return this.state.candidates.slice(page.start, page.start + page.count);
  }

  @Builder
  CandidateBar() {
    Row() {
      this.MenuKey()

      Scroll() {
        Row({ space: CANDIDATE_GAP_VP }) {
          if (this.state.candidates.length === 0) {
            Text(this.state.preedit)
              .fontSize(16)
              .fontColor(KeyboardTheme.candidateText)
              .padding({ left: 12, right: 12 })
              .height('100%')
          }
          ForEach(this.visibleCandidates(), (candidate: CandidateEntry) => {
            Text(candidate.text)
              .fontSize(18)
              .fontColor(KeyboardTheme.candidateText)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 10, right: 10 })
              .height(CANDIDATE_CHIP_HEIGHT_VP)
              .backgroundColor(KeyboardTheme.key)
              .borderRadius(KEY_RADIUS_VP)
              .onClick(() => {
                this.hub.onSelectCandidate(candidate.index);
              })
          }, (candidate: CandidateEntry) => `${candidate.index}-${candidate.text}`)
        }
        .padding({ left: 6, right: 6 })
        .height('100%')
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height('100%')
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const measured: number = Number(newValue.width);
        if (!Number.isNaN(measured) && measured > 0) {
          this.barWidth = measured;
        }
      })

      if (this.state.candidates.length > 0) {
        this.PreviousPageKey()
        this.NextPageKey()
      }

      this.HideKey()
    }
    .width('100%')
    .height(CANDIDATE_BAR_HEIGHT_VP)
    .backgroundColor(KeyboardTheme.bar)
  }

  @Builder
  MenuKey() {
    Text('\u22ee')
      .fontSize(20)
      .fontColor(KeyboardTheme.keyText)
      .padding({ left: 12, right: 8 })
      .height('100%')
      .onClick(() => {
        this.openSettings();
      })
  }

  @Builder
  /**
   * Top-right key: clear the pending input, or close the keyboard.
   *
   * With uncommitted input in play the useful action is to discard it, so the
   * glyph changes to a cross and the press clears the composition (the raw
   * pinyin and its candidates) together with the editor's preview text, which is
   * the part already resolved to characters but not yet written into the
   * document.  Nothing already committed is touched.  Once the composition is
   * gone the key reverts to the chevron on its own, because this builder reads
   * the same state the engine just cleared.
   */
  @Builder
  HideKey() {
    if (this.hasPendingInput()) {
      Text('\u2715')
        .fontSize(20)
        .fontColor(KeyboardTheme.keyText)
        .padding({ left: 10, right: 12 })
        .height('100%')
        .onClick(() => {
          this.hub.onEscape();
        })
    } else {
      Text('\u2304')
        .fontSize(20)
        .fontColor(KeyboardTheme.keyText)
        .padding({ left: 10, right: 12 })
        .height('100%')
        .onClick(() => {
          this.hub.hideKeyboard();
        })
    }
  }

  /**
   * True while there is input the clear key would discard.
   *
   * `preedit` is the raw pinyin and `candidates` the resolved words; either one
   * being present means the button should offer to clear rather than to close.
   */
  private hasPendingInput(): boolean {
    return this.state.preedit.length > 0 || this.state.candidates.length > 0;
  }

  @Builder
  PreviousPageKey() {
    Text('‹')
      .fontSize(20)
      .fontColor(this.uiPage > 0 ? KeyboardTheme.link : KeyboardTheme.candidateComment)
      .padding({ left: 10, right: 10 })
      .height('100%')
      .onClick(() => {
        if (this.uiPage > 0) {
          this.uiPage = this.uiPage - 1;
        }
      })
  }

  @Builder
  NextPageKey() {
    Text('›')
      .fontSize(20)
      .fontColor(this.uiPage < this.candidatePageCount() - 1
        ? KeyboardTheme.link : KeyboardTheme.candidateComment)
      .padding({ left: 10, right: 10 })
      .height('100%')
      .onClick(() => {
        if (this.uiPage < this.candidatePageCount() - 1) {
          this.uiPage = this.uiPage + 1;
        }
      })
  }

  @Builder
  MessageLine() {
    if (this.state.message.length > 0 && !this.state.ready) {
      Text(this.state.message)
        .fontSize(12)
        .fontColor(KeyboardTheme.message)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .backgroundColor(KeyboardTheme.messageBackground)
    }
  }

  // -----------------------------------------------------------------------
  // key panels
  // -----------------------------------------------------------------------

  @Builder
  KeyboardBody() {
    Column() {
      if (this.panel === PanelKind.Symbol || this.panel === PanelKind.Emoji) {
        this.PickerPanel()
      } else {
        this.KeyGrid()
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 3, right: 3, top: 4, bottom: 6 })
  }

  /** Letters or digits, depending on the active panel. */
  private currentRows(): KeySpec[][] {
    return this.panel === PanelKind.Number ? NUMBER_KEYS : LETTER_KEYS;
  }

  /**
   * Renders the active key table.
   *
   * Key appearance is written inline rather than behind a per-key @Builder: the
   * appearance depends on Shift and ASCII mode, and a parameterised builder
   * would not be re-run when those change (see the file header).
   */
  @Builder
  KeyGrid() {
    Column({ space: ROW_GAP_VP }) {
      ForEach(this.currentRows(), (row: KeySpec[]) => {
        Row({ space: KEY_GAP_VP }) {
          ForEach(row, (key: KeySpec) => {
            if (key.kind === KeyKind.Char) {
              Stack({ alignContent: Alignment.TopEnd }) {
                Text(this.charLabel(key))
                  .fontSize(KEY_TEXT_SIZE)
                  .fontColor(KeyboardTheme.keyText)
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .height('100%')
                if (key.hint.length > 0) {
                  Text(key.hint)
                    .fontSize(KEY_HINT_TEXT_SIZE)
                    .fontColor(KeyboardTheme.altKeyLabel)
                    .margin({ top: 4, right: 6 })
                }
              }
              .layoutWeight(key.renderWeight)
              .height(KEY_ROW_HEIGHT_VP)
              .backgroundColor(KeyboardTheme.key)
              .borderRadius(KEY_RADIUS_VP)
              .onClick(() => {
                this.pressChar(key);
              })
            } else if (key.kind === KeyKind.Shift) {
              Text('⇧')
                .fontSize(KEY_ALT_TEXT_SIZE + 3)
                .fontColor(this.shiftActive ? KeyboardTheme.activeKeyText : KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height(KEY_ROW_HEIGHT_VP)
                .backgroundColor(this.shiftActive
                  ? KeyboardTheme.activeKey : KeyboardTheme.altKey)
                .borderRadius(KEY_RADIUS_VP)
                .onClick(() => {
                  this.shiftActive = !this.shiftActive;
                })
            } else if (key.kind === KeyKind.Backspace) {
              Text('⌫')
                .fontSize(KEY_ALT_TEXT_SIZE + 3)
                .fontColor(KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height(KEY_ROW_HEIGHT_VP)
                .backgroundColor(KeyboardTheme.altKey)
                .borderRadius(KEY_RADIUS_VP)
                .onClick(() => {
                  this.hub.onBackspace();
                })
            } else if (key.kind === KeyKind.Enter) {
              Text('↵')
                .fontSize(KEY_ALT_TEXT_SIZE + 5)
                .fontColor(KeyboardTheme.accentKeyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height(KEY_ROW_HEIGHT_VP)
                .backgroundColor(KeyboardTheme.accentKey)
                .borderRadius(KEY_RADIUS_VP)
                .onClick(() => {
                  this.hub.onEnter();
                })
            } else if (key.kind === KeyKind.Space) {
              Text('空格')
                .fontSize(KEY_ALT_TEXT_SIZE)
                .fontColor(KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height(KEY_ROW_HEIGHT_VP)
                .backgroundColor(KeyboardTheme.spaceBar)
                .borderRadius(KEY_RADIUS_VP)
                .onClick(() => {
                  this.hub.onSpace(this.firstVisibleIndex());
                })
            } else if (key.kind === KeyKind.Ascii) {
              Text(this.state.asciiMode ? '英' : '中')
                .fontSize(KEY_ALT_TEXT_SIZE)
                .fontColor(this.state.asciiMode
                  ? KeyboardTheme.activeKeyText : KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height(KEY_ROW_HEIGHT_VP)
                .backgroundColor(this.state.asciiMode
                  ? KeyboardTheme.activeKey : KeyboardTheme.altKey)
                .borderRadius(KEY_RADIUS_VP)
                .onClick(() => {
                  this.hub.onToggleAsciiMode();
                })
            } else {
              // KeyKind.Switch: '?123', '!?#', 'ABC'.
              Text(key.label)
                .fontSize(KEY_ALT_TEXT_SIZE)
                .fontColor(KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height(KEY_ROW_HEIGHT_VP)
                .backgroundColor(KeyboardTheme.altKey)
                .borderRadius(KEY_RADIUS_VP)
                .onClick(() => {
                  this.panel = key.target;
                  this.uiPage = 0;
                })
            }
          }, (key: KeySpec) => `${key.kind}-${key.label}-${key.text}`)
        }
        .width('100%')
      }, (row: KeySpec[]) => row.map((key: KeySpec) => key.label).join(''))
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
  }

  /** Label of a Char key; A-Z are upper-cased only while Shift is active. */
  private charLabel(key: KeySpec): string {
    const isLetter: boolean = key.text.length === 1 && key.text >= 'A' && key.text <= 'Z';
    if (isLetter) {
      return this.shiftActive ? key.text : key.text.toLowerCase();
    }
    return key.text;
  }

  private pressChar(key: KeySpec): void {
    // Letter and digit keys carry a key code, so Rime sees a real key event;
    // symbol keys carry only text and go through code-point mapping.
    if (key.keyCode !== 0) {
      // Same A-Z case rule as charLabel(), so the typed letter matches the label.
      const text: string = key.text.length === 1 && key.text >= 'A' && key.text <= 'Z' &&
        this.shiftActive ? key.text : key.text.toLowerCase();
      this.hub.onKey(key.keyCode, text.charCodeAt(0));
    } else {
      this.hub.typeCharacter(key.text);
    }
    if (this.shiftActive) {
      this.shiftActive = false;
    }
  }

  // -----------------------------------------------------------------------
  // symbol and emoji pickers
  // -----------------------------------------------------------------------

  /** True while the symbol grid (rather than emoji) is active. */
  private isSymbolPanel(): boolean {
    return this.panel === PanelKind.Symbol;
  }

  private pickerCategories(): PickerCategory[] {
    return this.isSymbolPanel() ? SYMBOL_CATEGORIES : EMOJI_CATEGORIES;
  }

  private activeCategoryIndex(): number {
    return this.isSymbolPanel() ? this.symbolCategory : this.emojiCategory;
  }

  private activePageIndex(): number {
    return this.isSymbolPanel() ? this.symbolPage : this.emojiPage;
  }

  private pickerPageSize(): number {
    return this.isSymbolPanel() ? SYMBOL_PAGE_SIZE : EMOJI_PAGE_SIZE;
  }

  private pickerColumns(): number {
    return this.isSymbolPanel() ? SYMBOL_COLUMNS : EMOJI_COLUMNS;
  }

  private activeCategoryEntries(): string[] {
    const list: PickerCategory[] = this.pickerCategories();
    if (list.length === 0) {
      return [];
    }
    return list[Math.min(this.activeCategoryIndex(), list.length - 1)].entries;
  }

  private pickerPageCount(): number {
    const entryCount: number = this.activeCategoryEntries().length;
    const pageSize: number = this.pickerPageSize();
    return entryCount === 0 ? 1 : Math.ceil(entryCount / pageSize);
  }

  /** Entries of the current page, already cut into display rows. */
  private pickerRows(): string[][] {
    const pageSize: number = this.pickerPageSize();
    const columnCount: number = this.pickerColumns();
    const pageIndex: number = Math.min(this.activePageIndex(), this.pickerPageCount() - 1);
    const pageEntries: string[] = this.activeCategoryEntries()
      .slice(pageIndex * pageSize, (pageIndex + 1) * pageSize);

    const rows: string[][] = [];
    for (let start = 0; start < pageEntries.length; start += columnCount) {
      rows.push(pageEntries.slice(start, start + columnCount));
    }
    // Pad the final row so a short page keeps the grid's column widths.
    if (rows.length > 0) {
      const lastRow: string[] = rows[rows.length - 1];
      while (lastRow.length < columnCount) {
        lastRow.push('');
      }
    }
    return rows;
  }

  private setPickerCategory(index: number): void {
    if (this.isSymbolPanel()) {
      this.symbolCategory = index;
      this.symbolPage = 0;
    } else {
      this.emojiCategory = index;
      this.emojiPage = 0;
    }
  }

  /** Moves `delta` pages, stopping at either end. */
  private stepPickerPage(delta: number): void {
    const target: number = this.activePageIndex() + delta;
    if (target < 0 || target > this.pickerPageCount() - 1) {
      return;
    }
    this.setPickerPage(target);
  }

  private setPickerPage(page: number): void {
    if (this.isSymbolPanel()) {
      this.symbolPage = page;
    } else {
      this.emojiPage = page;
    }
  }

  @Builder
  PickerPanel() {
    Column({ space: ROW_GAP_VP }) {
      Scroll() {
        Row({ space: KEY_GAP_VP }) {
          ForEach(this.pickerCategories(), (category: PickerCategory, index: number) => {
            Text(category.label)
              .fontSize(14)
              .fontColor(this.activeCategoryIndex() === index
                ? KeyboardTheme.accentKeyText : KeyboardTheme.keyText)
              .textAlign(TextAlign.Center)
              .padding({ left: 12, right: 12 })
              .height(PICKER_TAB_HEIGHT_VP)
              .backgroundColor(this.activeCategoryIndex() === index
                ? KeyboardTheme.accentKey : KeyboardTheme.altKey)
              .borderRadius(KEY_RADIUS_VP)
              .onClick(() => {
                this.setPickerCategory(index);
              })
          }, (category: PickerCategory) => category.label)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(PICKER_TAB_HEIGHT_VP)

      // Grid: takes the space the tab strip and the control row leave, so the
      // three rows always fit instead of overflowing by a fixed amount.
      Column({ space: ROW_GAP_VP }) {
        ForEach(this.pickerRows(), (row: string[]) => {
          Row({ space: KEY_GAP_VP }) {
            ForEach(row, (entry: string) => {
              Text(entry)
                .fontSize(GRID_TEXT_SIZE)
                .fontColor(KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height('100%')
                .backgroundColor(entry.length > 0 ? KeyboardTheme.key : KeyboardTheme.keyboard)
                .borderRadius(KEY_RADIUS_VP)
                .onClick(() => {
                  this.commitPickerEntry(entry);
                })
            }, (entry: string, index: number) => `${index}-${entry}`)
          }
          .width('100%')
          .layoutWeight(1)
        }, (row: string[], index: number) => `${this.activeCategoryIndex()}-${this.activePageIndex()}-${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      // Horizontal swipe pages the grid, matching the ‹ › buttons below.  The
      // distance threshold keeps taps on the cells working: a tap never travels
      // far enough to arm the pan.
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: PICKER_SWIPE_DISTANCE_VP })
          .onActionEnd((event: GestureEvent) => {
            if (event.offsetX <= -PICKER_SWIPE_DISTANCE_VP) {
              this.stepPickerPage(1);
            } else if (event.offsetX >= PICKER_SWIPE_DISTANCE_VP) {
              this.stepPickerPage(-1);
            }
          })
      )

      // Bottom row: back to the letters, paging, and backspace.
      Row({ space: KEY_GAP_VP }) {
        Text('返回')
          .fontSize(KEY_ALT_TEXT_SIZE)
          .fontColor(KeyboardTheme.keyText)
          .textAlign(TextAlign.Center)
          .layoutWeight(15)
          .height(KEY_ROW_HEIGHT_VP)
          .backgroundColor(KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)
          .onClick(() => {
            this.panel = PanelKind.Letter;
            this.uiPage = 0;
          })

        Text('‹')
          .fontSize(20)
          .fontColor(this.activePageIndex() > 0 ? KeyboardTheme.link : KeyboardTheme.altKeyText)
          .textAlign(TextAlign.Center)
          .layoutWeight(15)
          .height(KEY_ROW_HEIGHT_VP)
          .backgroundColor(KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)
          .onClick(() => {
            this.stepPickerPage(-1);
          })

        Text(`${Math.min(this.activePageIndex(), this.pickerPageCount() - 1) + 1}` +
          `/${this.pickerPageCount()}`)
          .fontSize(12)
          .fontColor(KeyboardTheme.keyText)
          .textAlign(TextAlign.Center)
          .layoutWeight(20)
          .height(KEY_ROW_HEIGHT_VP)
          .backgroundColor(KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)

        Text('›')
          .fontSize(20)
          .fontColor(this.activePageIndex() < this.pickerPageCount() - 1
            ? KeyboardTheme.link : KeyboardTheme.altKeyText)
          .textAlign(TextAlign.Center)
          .layoutWeight(15)
          .height(KEY_ROW_HEIGHT_VP)
          .backgroundColor(KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)
          .onClick(() => {
            this.stepPickerPage(1);
          })

        Text('⌫')
          .fontSize(KEY_ALT_TEXT_SIZE + 3)
          .fontColor(KeyboardTheme.keyText)
          .textAlign(TextAlign.Center)
          .layoutWeight(20)
          .height(KEY_ROW_HEIGHT_VP)
          .backgroundColor(KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)
          .onClick(() => {
            this.hub.onBackspace();
          })
      }
      .width('100%')
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
  }

  private commitPickerEntry(entry: string): void {
    if (entry.length === 0) {
      return;
    }
    if (this.isSymbolPanel()) {
      // Symbols go through Rime so its punctuator can apply full-shape rules,
      // matching how the reference implementation sends them.
      this.hub.typeCharacter(entry);
    } else {
      // Emoji go straight to the editor: they are often several code points and
      // would be truncated to the first one otherwise.
      this.hub.commitDirect(entry);
    }
  }

  // -----------------------------------------------------------------------
  // settings panel
  // -----------------------------------------------------------------------

  private refreshSettings(): void {
    this.schemaEntries = this.engine.getSchemas();
    this.activeSchemaId = this.engine.getActiveSchemaId();
    this.switchEntries = this.engine.getSwitches();
    hilog.info(DOMAIN, TAG, 'settings: %{public}d schemas, %{public}d switches',
               this.schemaEntries.length, this.switchEntries.length);
  }

  private openSettings(): void {
    this.engine.syncExternalConfig();
    this.refreshSettings();
    this.settingsOpen = true;
  }

  private toggleSwitch(entry: SwitchEntry): void {
    this.engine.advanceSwitch(entry);
    this.refreshSettings();
  }

  private chooseSchema(schemaId: string): void {
    if (!this.engine.setActiveSchema(schemaId)) {
      hilog.error(DOMAIN, TAG, 'cannot activate schema %{public}s', schemaId);
      this.settingsNotice = '无法切换到该方案：它没有被成功部署，或依赖的引擎组件缺失';
      this.refreshSettings();
      return;
    }
    this.settingsNotice = '';
    this.refreshSettings();
  }

  private async importFolder(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    this.importStatus = '正在读取文件夹…';
    this.settingsNotice = '';

    try {
      const outcome: FolderImportOutcome | null = await this.engine.importConfigFolder(
        (progress: ImportProgress) => {
          this.importStatus = progress.total > 0
            ? `已复制 ${progress.copied}/${progress.total}：${progress.current}`
            : `已复制 ${progress.copied}：${progress.current}`;
        });

      if (outcome === null) {
        this.importStatus = '';
        this.settingsNotice = '未选择文件夹';
        return;
      }
      const directorySuffix: string = outcome.directories.length > 0
        ? `，含目录 ${outcome.directories.join('、')}`
        : '';
      const unreadableSuffix: string = outcome.unreachable > 0
        ? `，${outcome.unreachable} 个条目无法读取`
        : '';
      this.importStatus = '';
      this.settingsNotice = `已导入 ${outcome.copied} 个文件${directorySuffix}${unreadableSuffix}，正在部署…`;
      this.refreshSettings();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'import from keyboard failed: %{public}s', err.message);
      this.importStatus = '';
      // This route uses the picker from an extension context, which some devices
      // refuse (error 13900042).  Say which route does work.
      this.settingsNotice = `导入失败：${err.message}。` +
        '请改用应用里的「导入配置文件夹」，选择后打开一次键盘即可接收。';
    } finally {
      this.importing = false;
    }
  }

  @Builder
  SettingsPanel() {
    Column() {
      Row() {
        Text('方案设置')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text('关闭')
          .fontSize(14)
          .fontColor(KeyboardTheme.link)
          .padding({ left: 12, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.settingsOpen = false;
          })
      }
      .width('100%')
      .height(40)

      Row({ space: 8 }) {
        Button(this.importing ? '导入中…' : '导入配置文件夹')
          .fontSize(13)
          .layoutWeight(1)
          .enabled(!this.importing)
          .onClick(() => {
            this.importFolder();
          })
        Button('重新加载')
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor(KeyboardTheme.altKey)
          .fontColor(KeyboardTheme.keyText)
          .onClick(() => {
            this.engine.forceReload();
            this.settingsNotice = '已重新加载引擎';
            this.refreshSettings();
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (this.importStatus.length > 0) {
        Text(this.importStatus)
          .fontSize(11)
          .fontColor(KeyboardTheme.link)
          .width('100%')
          .padding({ bottom: 6 })
      }

      if (this.settingsNotice.length > 0) {
        Text(this.settingsNotice)
          .fontSize(12)
          .fontColor(KeyboardTheme.message)
          .width('100%')
          .padding({ bottom: 8 })
      }

      Scroll() {
        Column() {
          Text('方案')
            .fontSize(12)
            .fontColor(KeyboardTheme.candidateComment)
            .width('100%')
            .margin({ top: 4, bottom: 4 })

          if (this.schemaEntries.length === 0) {
            Text('没有可用方案')
              .fontSize(12)
              .fontColor(KeyboardTheme.candidateComment)
              .width('100%')
          }
          ForEach(this.schemaEntries, (entry: SchemaEntry) => {
            Row() {
              Text(entry.name)
                .fontSize(15)
                .fontColor(KeyboardTheme.keyText)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (entry.schemaId === this.activeSchemaId) {
                Text('当前')
                  .fontSize(11)
                  .fontColor(KeyboardTheme.link)
              }
            }
            .width('100%')
            .height(42)
            .onClick(() => {
              this.chooseSchema(entry.schemaId);
            })
          }, (entry: SchemaEntry) => entry.schemaId)

          Divider()
            .color(KeyboardTheme.divider)
            .margin({ top: 8, bottom: 8 })

          Row() {
            Text('诊断')
              .fontSize(12)
              .fontColor(KeyboardTheme.candidateComment)
              .layoutWeight(1)
            Text(this.diagnosticsOpen ? '收起' : '展开')
              .fontSize(12)
              .fontColor(KeyboardTheme.link)
              .onClick(() => {
                this.diagnosticsOpen = !this.diagnosticsOpen;
              })
          }
          .width('100%')
          .height(28)

          if (this.diagnosticsOpen) {
            Text(this.engine.getDiagnostics())
              .fontSize(10)
              .fontFamily('monospace')
              .fontColor(KeyboardTheme.keyText)
              .copyOption(CopyOptions.LocalDevice)
              .width('100%')
              .padding(8)
              .backgroundColor('#F7F8FA')
              .borderRadius(KEY_RADIUS_VP)
              .margin({ bottom: 8 })
          }

          Text('选项')
            .fontSize(12)
            .fontColor(KeyboardTheme.candidateComment)
            .width('100%')
            .margin({ bottom: 4 })

          if (this.switchEntries.length === 0) {
            Text('当前方案的 switches 中没有可切换的选项')
              .fontSize(12)
              .fontColor(KeyboardTheme.candidateComment)
              .width('100%')
          }
          ForEach(this.switchEntries, (entry: SwitchEntry) => {
            Row() {
              Text(entry.title)
                .fontSize(15)
                .fontColor(KeyboardTheme.keyText)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(entry.currentLabel)
                .fontSize(13)
                .fontColor(entry.enabled ? KeyboardTheme.accentKeyText : KeyboardTheme.keyText)
                .backgroundColor(entry.enabled ? KeyboardTheme.accentKey : KeyboardTheme.altKey)
                .borderRadius(4)
                .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            }
            .width('100%')
            .height(42)
            .onClick(() => {
              this.toggleSwitch(entry);
            })
          }, (entry: SwitchEntry) => `${entry.title}-${entry.activeIndex}-${entry.currentLabel}`)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, bottom: 8 })
    .backgroundColor('#FFFFFF')
  }
}
