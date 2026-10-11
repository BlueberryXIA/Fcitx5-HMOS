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
import { longPressChoices } from '../inputmethod/keyboard/LongPressOptions';
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

/**
 * How long a character key must be held before its popup opens, in ms.
 *
 * Long enough not to fire during ordinary typing -- including a fast double tap,
 * which is two short presses in quick succession -- while still feeling
 * deliberate.  Android's default long-press delay is 400ms.
 */
const LONG_PRESS_MS: number = 500;

/** Travel, in vp, that counts as sliding off a key before the hold completes. */
const LONG_PRESS_TOLERANCE_VP: number = 20;

/**
 * Size of one cell in the long-press popup.
 *
 * The popup holds three cells, so its width is roughly
 * 3 * (cell + gap) + 2 * padding.  Kept small: a wide popup gets clamped when
 * it is placed above a key near the edge of the screen, and the clamped frame
 * then cuts into the highlighted cell.
 */
const LONG_PRESS_CELL_VP: number = 26;

/** Gap between cells in the long-press popup, and its padding. */
const LONG_PRESS_GAP_VP: number = 2;

/** Centre-to-centre distance between cells; this much travel moves one choice. */
const LONG_PRESS_STEP_VP: number = LONG_PRESS_CELL_VP + LONG_PRESS_GAP_VP;

/** Text size inside a popup cell, scaled to fit the cell height. */
const LONG_PRESS_TEXT_SIZE: number = 13;

/** Corner radius of a popup cell. */
const LONG_PRESS_CELL_RADIUS_VP: number = 3;

/**
 * Height of the pinyin line above the candidates, in vp.
 *
 * Always laid out, even with nothing to show, so the keys below never move when
 * a composition starts.
 */
const PINYIN_BAR_HEIGHT_VP: number = 14;

/**
 * Line height of the pinyin text, set explicitly.
 *
 * Left to the default, the text box is noticeably taller than the glyphs, and
 * that leading is what opened the visible gap between the pinyin and the
 * candidates below it.  Matching the box to the row removes it.
 */
const PINYIN_LINE_HEIGHT_VP: number = 14;

/** Text size of the pinyin; smaller than the candidates, but not by much. */
const PINYIN_TEXT_SIZE: number = 11;

/**
 * The collapse key's chevron, drawn rather than typed.
 *
 * Every glyph that looks like one -- U+2304, U+25BE, U+02C5 -- is missing from
 * the HarmonyOS fonts and was drawn by a fallback font, which is also why it
 * would not line up with the menu beside it.  The one chevron-shaped glyph that
 * IS present (U+2228 LOGICAL OR) is a mathematical operator and reads as a
 * letter "v".  A path gives the button the shape it should have and no font can
 * redraw it.
 */
const CHEVRON_WIDTH_VP: number = 16;

/** Depth of the chevron's V, in vp. */
const CHEVRON_HEIGHT_VP: number = 9;

/** Stroke width of the chevron, in vp. */
const CHEVRON_STROKE_VP: number = 2.5;

/** Box that holds the chevron, leaving half a stroke of margin on each side. */
const CHEVRON_BOX_WIDTH_VP: number = CHEVRON_WIDTH_VP + CHEVRON_STROKE_VP;
const CHEVRON_BOX_HEIGHT_VP: number = CHEVRON_HEIGHT_VP + CHEVRON_STROKE_VP;

/** Width of the top-right key, fixed so the strip does not shift with its glyph. */
const HIDE_KEY_WIDTH_VP: number = 44;

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

  /** Label of the key being held, so it can be drawn pressed. Empty when none. */
  @State pressedKeyLabel: string = '';

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

  // Long-press popup over a letter key.
  /** The choices offered; empty when no popup is open. */
  @State longPressChoices: string[] = [];
  /** Which choice the finger is currently over. */
  @State longPressIndex: number = 0;
  @State longPressVisible: boolean = false;
  /** Label of the key the popup belongs to, so only that key binds it. */
  @State longPressAnchor: string = '';

  private hub: KeyboardHub = KeyboardHub.getInstance();
  private engine: RimeEngineService = RimeEngineService.getInstance();

  /**
   * The keyboard's one and only hold timer, or -1 when none is armed.
   *
   * There is deliberately a single timer for the whole keyboard rather than one
   * per finger or per key.  Anything keyed by finger had to be matched up again
   * on release, and the touch id ArkUI reports cannot be relied on to match --
   * every mismatch stranded a timer that later opened the popup on its own,
   * which is what fast two-thumb typing kept hitting.  With one timer there is
   * nothing to match: any press resets it, any release clears it.
   */
  private longPressTimer: number = -1;

  /** The last key pressed; the timer opens this key's popup when it fires. */
  private pendingLongPressKey: KeySpec | null = null;

  /** windowX where that key was pressed, so travel can pick a popup choice. */
  private longPressOriginX: number = 0;

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
    this.clearLongPressTimer();
    this.engine.unsubscribe(this.listener);
  }

  build() {
    Stack() {
      Column() {
        this.HeaderBar()
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

  /**
   * True while there is input the clear key would discard.
   *
   * `preedit` is the raw pinyin and `candidates` the words it resolved to;
   * either one being present means the key should offer to clear rather than to
   * close, and that the three-dot menu should give up its place at the left.
   */
  private hasPendingInput(): boolean {
    return this.state.preedit.length > 0 || this.state.candidates.length > 0;
  }

  /** Opens the settings panel; hidden while a composition is in progress. */
  @Builder
  MenuKey() {
    // U+2261 IDENTICAL TO -- three stacked bars, the closest thing to a menu
    // icon that the system font actually contains.
    //
    // That last part is the whole point.  The glyph this used to draw (U+22EE,
    // a vertical ellipsis) is ABSENT from HarmonyOS Sans, so it was rendered by
    // whichever fallback font the system picked, with that font's own ascent and
    // descent.  The close key's glyph was absent too and came from a different
    // fallback, so the two texts had different line boxes and their ink landed at
    // different heights however the sizes were tuned.  Both glyphs are now taken
    // from the system font, and it gives them the same metrics in the Latin and
    // the Simplified Chinese face alike, so the two line up by construction.
    Text('\u2261')
      .fontSize(KEY_ALT_TEXT_SIZE + 3)
      .fontColor(KeyboardTheme.keyText)
      .textAlign(TextAlign.Center)
      .padding({ left: 10, right: 8 })
      .height(CANDIDATE_BAR_HEIGHT_VP)
      .onClick(() => {
        this.openSettings();
      })
  }

  @Builder
  PreviousPageKey() {
    Text('\u2039')
      .fontSize(KEY_ALT_TEXT_SIZE + 4)
      .fontColor(this.uiPage > 0 ? KeyboardTheme.keyText : KeyboardTheme.altKeyText)
      .textAlign(TextAlign.Center)
      .width(30)
      .height('100%')
      .onClick(() => {
        if (this.uiPage > 0) {
          this.uiPage--;
        }
      })
  }

  @Builder
  NextPageKey() {
    Text('\u203A')
      .fontSize(KEY_ALT_TEXT_SIZE + 4)
      .fontColor(this.uiPage < this.candidatePageCount() - 1
        ? KeyboardTheme.keyText : KeyboardTheme.altKeyText)
      .textAlign(TextAlign.Center)
      .width(30)
      .height('100%')
      .onClick(() => {
        if (this.uiPage < this.candidatePageCount() - 1) {
          this.uiPage++;
        }
      })
  }

  /**
   * Top-right key: clear the pending input, or close the keyboard.
   *
   * With uncommitted input in play the useful action is to discard it, so the
   * glyph changes to a cross and the press clears the composition (the raw
   * pinyin and its candidates).  Nothing already committed is touched.  Once the
   * composition is gone the key reverts to the chevron on its own, because this
   * builder reads the same state the engine just cleared.
   */
  @Builder
  HideKey() {
    if (this.hasPendingInput()) {
      // U+00D7 MULTIPLICATION SIGN, not U+2715.  Both are crosses, but U+2715 is
      // a mathematical operator drawn to fill its em box, so at the intended size
      // it towered over the page arrows; U+00D7 is a text-sized glyph and sits
      // where a slightly-larger-than-the-arrows cross should.
      Text('\u00D7')
        .fontSize(KEY_ALT_TEXT_SIZE + 5)
        .fontColor(KeyboardTheme.keyText)
        .textAlign(TextAlign.Center)
        .width(HIDE_KEY_WIDTH_VP)
        .height(CANDIDATE_BAR_HEIGHT_VP)
        .onClick(() => {
          this.hub.onEscape();
        })
    } else {
      Stack() {
        Path()
          .commands(this.chevronCommands())
          .width(CHEVRON_BOX_WIDTH_VP)
          .height(CHEVRON_BOX_HEIGHT_VP)
          .fill(Color.Transparent)
          .stroke(KeyboardTheme.keyText)
          .strokeWidth(CHEVRON_STROKE_VP)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
      .width(HIDE_KEY_WIDTH_VP)
      .height(CANDIDATE_BAR_HEIGHT_VP)
      .onClick(() => {
        this.hub.hideKeyboard();
      })
    }
  }

  /**
   * The chevron's path, built from the constants above so the two cannot drift.
   *
   * A single polyline: down from the left end to the middle, then back up to the
   * right end.  The whole shape is inset by half the stroke, which keeps the
   * stroke inside the drawing box instead of bleeding past it.
   *
   * Every coordinate goes through vp2px().  Path commands are the one place in
   * ArkUI that takes raw PIXELS rather than vp, and writing them straight from
   * the vp constants drew a chevron about a third of the intended size on a
   * 3x screen -- and left it tucked in the corner of a box measured in vp, which
   * is what made it look misaligned as well.  strokeWidth() below IS a Length,
   * so it stays in vp.
   */
  private chevronCommands(): string {
    const inset: number = CHEVRON_STROKE_VP / 2;
    const topY: number = vp2px(inset);
    const bottomY: number = vp2px(inset + CHEVRON_HEIGHT_VP);
    const leftX: number = vp2px(inset);
    const middleX: number = vp2px(inset + CHEVRON_WIDTH_VP / 2);
    const rightX: number = vp2px(inset + CHEVRON_WIDTH_VP);
    return `M${leftX} ${topY} L${middleX} ${bottomY} L${rightX} ${topY}`;
  }

  /**
   * A transient line for deployment progress and failures.
   *
   * It sits between the header strip and the keys; the key rows divide whatever
   * height it leaves, so showing it can never clip the bottom row.
   */
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

  /**
   * The strip above the keys: the composing string, the candidates, and the
   * key that either clears the composition or closes the keyboard.
   *
   * While anything is being composed the three-dot menu is hidden, so the pinyin
   * and the candidates both begin at the very left edge -- the line being typed
   * and the words replacing it start from the same place.  The menu returns as
   * soon as nothing is pending.
   *
   * The clear-or-close key lives in this row rather than in the candidate row
   * below it, which is what puts its glyph in the middle of the whole strip.
   */
  @Builder
  HeaderBar() {
    Row() {
      // Hidden while composing so the pinyin and the candidates both start at the
      // very left edge.
      if (!this.hasPendingInput()) {
        this.MenuKey()
      }

      Column() {
        this.PinyinRow()

        Row() {
          Scroll() {
            Row({ space: CANDIDATE_GAP_VP }) {
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
        }
        .width('100%')
        .height(CANDIDATE_BAR_HEIGHT_VP)
      }
      .layoutWeight(1)
      .height('100%')

      this.HideKey()
    }
    .width('100%')
    .height(PINYIN_BAR_HEIGHT_VP + CANDIDATE_BAR_HEIGHT_VP)
    // Both buttons are one candidate-row tall.  While composing, the clear key
    // is pushed to the bottom so it shares the candidates' band and lines up with
    // them; with nothing composing, the menu and the close key centre themselves
    // over the whole strip instead.
    .alignItems(this.hasPendingInput() ? VerticalAlign.Bottom : VerticalAlign.Center)
    .backgroundColor(KeyboardTheme.bar)
  }

  /**
   * The composing string.
   *
   * Left aligned so it starts where the candidates do, and drawn in the same
   * colour as them -- only smaller, so the two are still told apart.  It sits on
   * the strip's own background rather than on a band of its own.
   */
  @Builder
  PinyinRow() {
    Row() {
      Text(this.state.preedit)
        .fontSize(PINYIN_TEXT_SIZE)
        .lineHeight(PINYIN_LINE_HEIGHT_VP)
        .fontColor(KeyboardTheme.candidateText)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 12, right: 8 })
    }
    .width('100%')
    .height(PINYIN_BAR_HEIGHT_VP)
    .justifyContent(FlexAlign.Start)
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
              .height('100%')
              .backgroundColor(this.keyBackground(key))
              .borderRadius(KEY_RADIUS_VP)
              .onTouch((event: TouchEvent) => {
                this.trackPress(key.label, event);
                this.onCharKeyTouch(key, event);
              })
              .bindPopup(this.longPressVisible && this.longPressAnchor === key.text, {
                builder: () => {
                  this.LongPressPopup();
                },
                placement: Placement.Top,
                // The builder draws the whole background itself, so the
                // platform's own popup surface must not draw a second one.
                // It did, and it carries a corner radius of the platform's
                // choosing which cannot be set from here: the white behind the
                // cells was that surface, rounder than the frame drawn below,
                // and the highlighted cell showed past it at the corners.
                popupColor: Color.Transparent,
                enableArrow: false,
                // The finger stays on the key for the whole gesture, so the
                // popup must not dismiss itself or take the touch stream.
                autoCancel: false
              })
            } else if (key.kind === KeyKind.Shift) {
              Text('⇧')
                .fontSize(KEY_ALT_TEXT_SIZE + 3)
                .fontColor(this.shiftActive ? KeyboardTheme.activeKeyText : KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height('100%')
                .backgroundColor(this.keyBackground(key))
                .borderRadius(KEY_RADIUS_VP)
                .onTouch((event: TouchEvent) => {
                  this.trackPress(key.label, event);
                })
                .onClick(() => {
                  this.shiftActive = !this.shiftActive;
                })
            } else if (key.kind === KeyKind.Backspace) {
              Text('⌫')
                .fontSize(KEY_ALT_TEXT_SIZE + 3)
                .fontColor(KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height('100%')
                .backgroundColor(this.keyBackground(key))
                .borderRadius(KEY_RADIUS_VP)
                .onTouch((event: TouchEvent) => {
                  this.trackPress(key.label, event);
                })
                .onClick(() => {
                  this.hub.onBackspace();
                })
            } else if (key.kind === KeyKind.Enter) {
              Text('↵')
                .fontSize(KEY_ALT_TEXT_SIZE + 5)
                .fontColor(KeyboardTheme.accentKeyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height('100%')
                .backgroundColor(this.keyBackground(key))
                .borderRadius(KEY_RADIUS_VP)
                .onTouch((event: TouchEvent) => {
                  this.trackPress(key.label, event);
                })
                .onClick(() => {
                  this.hub.onEnter();
                })
            } else if (key.kind === KeyKind.Space) {
              Text('空格')
                .fontSize(KEY_ALT_TEXT_SIZE)
                .fontColor(KeyboardTheme.keyText)
                .textAlign(TextAlign.Center)
                .layoutWeight(key.renderWeight)
                .height('100%')
                .backgroundColor(this.keyBackground(key))
                .borderRadius(KEY_RADIUS_VP)
                .onTouch((event: TouchEvent) => {
                  this.trackPress(key.label, event);
                })
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
                .height('100%')
                .backgroundColor(this.keyBackground(key))
                .borderRadius(KEY_RADIUS_VP)
                .onTouch((event: TouchEvent) => {
                  this.trackPress(key.label, event);
                })
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
                .height('100%')
                .backgroundColor(this.keyBackground(key))
                .borderRadius(KEY_RADIUS_VP)
                .onTouch((event: TouchEvent) => {
                  this.trackPress(key.label, event);
                })
                .onClick(() => {
                  this.panel = key.target;
                  this.uiPage = 0;
                })
            }
          }, (key: KeySpec) => `${key.kind}-${key.label}-${key.text}`)
        }
        .width('100%')
        // Rows divide whatever the header leaves, so the grid always fits and
        // never wastes a strip at the bottom.
        .layoutWeight(1)
      }, (row: KeySpec[]) => row.map((key: KeySpec) => key.label).join(''))
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
  }

  /** Label of a Char key; A-Z are upper-cased only while Shift is active. */
  /**
   * Background for a key, taking the held state into account.
   *
   * Every kind keeps its own colour and only darkens while held; a shared
   * highlight would make a pressed Return indistinguishable from a pressed
   * letter.
   */
  private keyBackground(key: KeySpec): string {
    const pressed: boolean = this.pressedKeyLabel === key.label;
    if (key.kind === KeyKind.Char) {
      return pressed ? KeyboardTheme.keyPressed : KeyboardTheme.key;
    }
    if (key.kind === KeyKind.Enter) {
      return pressed ? KeyboardTheme.accentKeyPressed : KeyboardTheme.accentKey;
    }
    if (key.kind === KeyKind.Space) {
      return pressed ? KeyboardTheme.spaceBarPressed : KeyboardTheme.spaceBar;
    }
    // Shift and the language key light up while they are engaged.
    const engaged: boolean = (key.kind === KeyKind.Shift && this.shiftActive) ||
      (key.kind === KeyKind.Ascii && this.state.asciiMode);
    if (engaged) {
      return pressed ? KeyboardTheme.activeKeyPressed : KeyboardTheme.activeKey;
    }
    return pressed ? KeyboardTheme.altKeyPressed : KeyboardTheme.altKey;
  }

  /**
   * Watches a press for its start and end, for the held highlight.
   *
   * Added alongside the key's own onClick rather than replacing it: onClick
   * still carries the action, and this only tracks the press around it.
   */
  private trackPress(label: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressedKeyLabel = label;
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.pressedKeyLabel === label) {
        this.pressedKeyLabel = '';
      }
    }
  }

  private charLabel(key: KeySpec): string {
    const isLetter: boolean = key.text.length === 1 && key.text >= 'A' && key.text <= 'Z';
    if (isLetter) {
      return this.shiftActive ? key.text : key.text.toLowerCase();
    }
    return key.text;
  }

  /**
   * Touch handling for character keys.
   *
   * These keys deliberately do not use onClick: a hold has to be told apart
   * from a tap, and onClick would still fire on release after the popup had
   * been used, typing the plain letter a second time.  The whole press lives
   * here instead -- a quick release types the key, a hold opens the popup,
   * travel across the popup picks a choice, and the release types that one.
   */
  private onCharKeyTouch(key: KeySpec, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (event.touches.length === 0) {
        return;
      }
      // Any press replaces whatever was pending.  Fast typing keeps resetting
      // this timer, so it only ever fires for a key that is genuinely held.
      this.clearLongPressTimer();
      this.dismissLongPressPopup();
      this.pendingLongPressKey = key;
      this.longPressOriginX = event.touches[0].windowX;
      this.longPressTimer = setTimeout(() => {
        this.longPressTimer = -1;
        this.openLongPressPopup();
      }, LONG_PRESS_MS);
      return;
    }

    if (event.type === TouchType.Move) {
      if (event.touches.length === 0) {
        return;
      }
      if (this.longPressVisible) {
        this.updateLongPressChoice(event.touches[0].windowX);
      }
      return;
    }

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      // Any release clears the timer, whatever finger it came from.  Nothing has
      // to be matched, so nothing can be left behind.
      this.clearLongPressTimer();
      if (this.longPressVisible) {
        this.commitLongPressChoice();
        return;
      }
      // No popup: this was an ordinary press, so type it.  `key` is the key this
      // handler is bound to, which is the one the finger went down on.
      if (event.type === TouchType.Up) {
        this.pressChar(key);
      }
      return;
    }
  }

  /** Disarms the hold timer, if one is armed. */
  private clearLongPressTimer(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
    this.pendingLongPressKey = null;
  }

  /** Closes the popup without choosing anything. */
  private dismissLongPressPopup(): void {
    if (!this.longPressVisible) {
      return;
    }
    this.longPressVisible = false;
    this.longPressChoices = [];
    this.longPressAnchor = '';
  }

  /**
   * Opens the popup for whichever key was pressed last.
   *
   * Called only from the hold timer.  A key with nothing to offer simply does not
   * open one -- its release still types it, because the release path types any
   * key whose popup is not showing.
   */
  private openLongPressPopup(): void {
    const key: KeySpec | null = this.pendingLongPressKey;
    if (key === null) {
      return;
    }
    const choices: string[] = longPressChoices(this.charLabel(key));
    if (choices.length === 0) {
      return;
    }
    this.longPressChoices = choices;
    this.longPressIndex = 0;
    this.longPressAnchor = key.text;
    this.longPressVisible = true;
  }

  /**
   * Turns horizontal travel from the press point into a choice.
   *
   * The popup sits above the finger, so the first cell is at the press point and
   * each cell of travel moves the highlight one choice along.
   */
  private updateLongPressChoice(touchX: number): void {
    const steps: number = Math.round((touchX - this.longPressOriginX) / LONG_PRESS_STEP_VP);
    const last: number = this.longPressChoices.length - 1;
    const wanted: number = Math.max(0, Math.min(last, steps));
    if (wanted !== this.longPressIndex) {
      this.longPressIndex = wanted;
    }
  }

  private commitLongPressChoice(): void {
    const chosen: string = this.longPressChoices[this.longPressIndex];
    this.longPressVisible = false;
    this.longPressChoices = [];
    this.longPressAnchor = '';
    if (chosen.length > 0) {
      this.hub.typeCharacter(chosen);
    }
  }

  /**
   * The floating row shown above a long-pressed key.
   *
   * Zero-argument like every builder in this file, so it re-runs when
   * `longPressIndex` changes and the highlight follows the finger.
   */
  @Builder
  LongPressPopup() {
    Row({ space: LONG_PRESS_GAP_VP }) {
      ForEach(this.longPressChoices, (choice: string, index: number) => {
        Text(choice)
          .fontSize(LONG_PRESS_TEXT_SIZE)
          .fontColor(index === this.longPressIndex
            ? KeyboardTheme.activeKeyText : KeyboardTheme.keyText)
          .textAlign(TextAlign.Center)
          .width(LONG_PRESS_CELL_VP)
          .height(LONG_PRESS_CELL_VP)
          .backgroundColor(index === this.longPressIndex
            ? KeyboardTheme.activeKey : KeyboardTheme.key)
          .borderRadius(LONG_PRESS_CELL_RADIUS_VP)
      }, (choice: string, index: number) => `${index}-${choice}-${index === this.longPressIndex}`)
    }
    // The only background in the popup is this one.
    //
    // The cells are inset by exactly this padding and their radius is smaller by
    // the same amount, which makes the outermost cell's corner concentric with
    // the frame's -- so no cell can reach past the rounded edge, whatever the
    // highlight is.
    .padding(LONG_PRESS_GAP_VP)
    .backgroundColor(KeyboardTheme.key)
    .borderRadius(LONG_PRESS_CELL_RADIUS_VP + LONG_PRESS_GAP_VP)
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
                .backgroundColor(entry.length === 0
                  ? KeyboardTheme.keyboard
                  : (this.pressedKeyLabel === entry
                    ? KeyboardTheme.keyPressed : KeyboardTheme.key))
                .borderRadius(KEY_RADIUS_VP)
                .onTouch((event: TouchEvent) => {
                  // The padding cells of a part-filled last row are not keys.
                  if (entry.length > 0) {
                    this.trackPress(entry, event);
                  }
                })
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
          .backgroundColor(this.pressedKeyLabel === '返回'
            ? KeyboardTheme.altKeyPressed : KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)
          .onTouch((event: TouchEvent) => {
            this.trackPress('返回', event);
          })
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
          .backgroundColor(this.pressedKeyLabel === '‹'
            ? KeyboardTheme.altKeyPressed : KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)
          .onTouch((event: TouchEvent) => {
            this.trackPress('‹', event);
          })
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
          .backgroundColor(this.pressedKeyLabel === '›'
            ? KeyboardTheme.altKeyPressed : KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)
          .onTouch((event: TouchEvent) => {
            this.trackPress('›', event);
          })
          .onClick(() => {
            this.stepPickerPage(1);
          })

        Text('⌫')
          .fontSize(KEY_ALT_TEXT_SIZE + 3)
          .fontColor(KeyboardTheme.keyText)
          .textAlign(TextAlign.Center)
          .layoutWeight(20)
          .height(KEY_ROW_HEIGHT_VP)
          .backgroundColor(this.pressedKeyLabel === '⌫'
            ? KeyboardTheme.altKeyPressed : KeyboardTheme.altKey)
          .borderRadius(KEY_RADIUS_VP)
          .onTouch((event: TouchEvent) => {
            this.trackPress('⌫', event);
          })
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
