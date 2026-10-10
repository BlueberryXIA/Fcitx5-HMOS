/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Haochen Xia
 */

/*
 * Design tokens for the settings page, following HarmonyOS Design.
 *
 * The page is built from ArkUI primitives rather than Huawei's UIDesignKit
 * (@hms.hds.*).  That keeps every line of the UI readable and buildable from
 * public sources, without a dependency on the HMS layer -- which matters for a
 * project meant to be learned from, and avoids the licence question of linking
 * a proprietary widget library into an AGPL work.
 *
 * The values below mirror the design system's published tokens: the text
 * emphasis levels are black at decreasing opacity (plus white for text on a
 * coloured surface), surfaces are white over a tinted page background, and radii
 * and spacing come from the 4vp grid.
 */

/** Text, by emphasis.  HarmonyOS expresses these as alpha over black. */
export class HDText {
  /** Titles and primary content. */
  static readonly primary: string = '#E5000000';
  /** Supporting text. */
  static readonly secondary: string = '#99000000';
  /** Hints, timestamps, captions. */
  static readonly tertiary: string = '#66000000';
  /** Disabled. */
  static readonly disabled: string = '#33000000';
  /** Text on a coloured surface. */
  static readonly onAccent: string = '#FFFFFF';
}

/** Surfaces. */
export class HDSurface {
  /** Page background. */
  static readonly page: string = '#F1F3F5';
  /** Card and sheet background. */
  static readonly card: string = '#FFFFFF';
  /** Nested or recessed area, e.g. a log view. */
  static readonly sunken: string = '#F5F6F7';
  /** Divider / hairline. */
  static readonly divider: string = '#0D000000';
}

/** Semantic colours. */
export class HDColor {
  /** Brand blue, for links and selected states. */
  static readonly brand: string = '#007DFF';
  /** Brand at 10%, for selected backgrounds. */
  static readonly brandTint: string = '#1A007DFF';
  /** Success, e.g. full-access mode. */
  static readonly success: string = '#64BB5C';
  /** Warning, e.g. basic input-method mode. */
  static readonly warning: string = '#E84026';
  /** Warning at 10%, for alert surfaces. */
  static readonly warningTint: string = '#1AE84026';
  /** Filled button background. */
  static readonly button: string = '#0A59F7';
  /** Secondary (tonal) button background. */
  static readonly buttonTonal: string = '#0D0A59F7';
}

/** Corner radii, on the 4vp grid. */
export class HDRadius {
  /** Chips, small badges. */
  static readonly small: number = 8;
  /** Inputs, list rows, buttons. */
  static readonly medium: number = 12;
  /** Cards and sheets. */
  static readonly large: number = 16;
  /** Pills. */
  static readonly full: number = 100;
}

/** Spacing, on the 4vp grid. */
export class HDSpace {
  static readonly xs: number = 4;
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 16;
  static readonly xl: number = 24;
}

/** Type scale. */
export class HDType {
  /** Page title. */
  static readonly title: number = 24;
  /** Card title. */
  static readonly subtitle: number = 16;
  /** Body and list rows. */
  static readonly body: number = 15;
  /** Secondary rows and descriptions. */
  static readonly caption: number = 13;
  /** Hints and footnotes. */
  static readonly footnote: number = 11;
  /** Monospaced diagnostics. */
  static readonly mono: number = 10;
}

/** Standard metrics. */
export class HDSize {
  /** Height of a tappable list row. */
  static readonly rowHeight: number = 48;
  /** Height of the card header row when it is itself tappable. */
  static readonly headerHeight: number = 40;
  /** Minimum height of a filled button. */
  static readonly buttonHeight: number = 40;
}
