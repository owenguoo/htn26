import { Color } from 'expo-router';
import { Platform, type ColorValue } from 'react-native';

/**
 * The design system for the Expo layer.
 *
 * The rule: **use Apple's semantic colours wherever one exists.** `Color` from
 * expo-router is a type-safe wrapper over `PlatformColor`, so every value below
 * is a UIKit dynamic colour that re-resolves on a trait change — light mode,
 * dark mode and increased contrast are the system's problem, not ours. The app
 * used to hand-copy Apple's dark palette by eye (`#1c1c1e`, `#8e8e93`,
 * `#0a84ff`, `#38383a`); those literals are what this file exists to delete.
 *
 * `Platform.select` is still how the pattern is written even on an iOS-only app
 * — it keeps the fallback honest and the types `ColorValue` rather than `any`.
 */
const ios = (value: ColorValue, fallback: string): ColorValue =>
  Platform.select({ ios: value, default: fallback }) ?? fallback;

export const colors = {
  // Surfaces
  background: ios(Color.ios.systemBackground, '#000000'),
  groupedBackground: ios(Color.ios.systemGroupedBackground, '#000000'),
  row: ios(Color.ios.secondarySystemGroupedBackground, '#1c1c1e'),
  fill: ios(Color.ios.secondarySystemFill, '#2c2c2e'),

  // Text
  label: ios(Color.ios.label, '#ffffff'),
  labelSecondary: ios(Color.ios.secondaryLabel, '#8e8e93'),
  labelTertiary: ios(Color.ios.tertiaryLabel, '#5c5c60'),
  placeholder: ios(Color.ios.placeholderText, '#666666'),

  // Lines
  separator: ios(Color.ios.separator, '#38383a'),
  opaqueSeparator: ios(Color.ios.opaqueSeparator, '#38383a'),

  // Meaning. These carry the OperatorStatus.level mapping.
  accent: ios(Color.ios.systemBlue, '#0a84ff'),
  link: ios(Color.ios.link, '#0a84ff'),
  ok: ios(Color.ios.systemGreen, '#30d158'),
  attention: ios(Color.ios.systemOrange, '#ff9f0a'),
  problem: ios(Color.ios.systemRed, '#ff453a'),
} as const;

/**
 * Chrome drawn over the live camera feed. Deliberately **not** adaptive: the
 * backdrop is arbitrary video, not a themed surface, so a semantic colour would
 * flip to dark-on-light and vanish against a bright frame. Legibility governs
 * here, not theme. Everything else in the app uses `colors` above.
 */
export const hud = {
  ink: '#ffffff',
  inkSecondary: 'rgba(255,255,255,0.72)',
  scrim: 'rgba(0,0,0,0.55)',
} as const;

/**
 * A `foregroundStyle` shorthand for the system's own de-emphasis. Preferred
 * over `colors.labelSecondary` inside a SwiftUI tree, because SwiftUI resolves
 * hierarchical styles against whatever the row's foreground already is.
 */
export const secondaryStyle = { type: 'hierarchical', style: 'secondary' } as const;

/** 4pt grid. Spend it through `gap`/`spacing`, never `margin` on children. */
export const space = { xs: 4, s: 8, m: 12, l: 16, xl: 20, xxl: 24 } as const;

/** Always paired with `borderCurve: 'continuous'` (RN) / `.continuous` (SwiftUI). */
export const radius = { control: 10, card: 14, sheet: 22 } as const;

/**
 * SwiftUI text styles for `font({ textStyle })`. Roles, not sizes: a raw
 * `fontSize` ignores the user's Dynamic Type setting, which the old join screen
 * did three times over (13/15/17).
 */
export const textStyles = {
  /** Drawn by the Stack's `headerLargeTitleEnabled`, never by a `Text` in the body. */
  screenTitle: 'largeTitle',
  cardTitle: 'title3',
  sectionAction: 'headline',
  /** 17pt — field text and list rows. The default; do not restate it. */
  body: 'body',
  rowValue: 'subheadline',
  footnote: 'footnote',
  hint: 'caption',
} as const;
