import { Host } from '@expo/ui';
import { Button, Image } from '@expo/ui/swift-ui';
import {
  accessibilityLabel,
  background,
  buttonStyle,
  font,
  foregroundStyle,
  padding,
  shapes,
} from '@expo/ui/swift-ui/modifiers';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import SwarmSight, { OperatorView } from '../../modules/swarm-sight';
import { usePreferences } from '../preferences';
import { hud, space } from '../theme/tokens';

/**
 * One native view, the whole screen. Everything the operator sees at rate —
 * camera, arrow, flash, seat picker, mini-map — is SwiftUI inside it. React
 * only mounts it and handles leaving.
 *
 * The one piece of React chrome left is the settings button, and it should not
 * be here either: it belongs beside the leave button in `OperatorView.chrome`,
 * which would also delete the magic `bottom: 132` below. That is a change to
 * `OperatorView.swift` — see `scratchpad/HANDOFF-R.md`. Until then it is at
 * least a real SF Symbol on a real SwiftUI button, not a text glyph.
 *
 * Its ink is fixed white on a fixed scrim, in both themes: the backdrop is a
 * live camera frame, so a semantic colour would flip and vanish.
 */
export default function Operator() {
  const { showDebug, showMiniMap } = usePreferences();
  const [leaving, setLeaving] = useState(false);

  const leave = useCallback(async () => {
    if (leaving) return;
    setLeaving(true);
    await SwarmSight.leave();
    router.replace('/join');
  }, [leaving]);

  return (
    <View style={styles.fill}>
      <StatusBar hidden />
      <OperatorView style={styles.fill} showDebug={showDebug} showMiniMap={showMiniMap} onRequestLeave={leave} />
      <Host style={styles.gear} matchContents>
        <Button
          onPress={() => router.push('/settings')}
          testID="settings"
          modifiers={[buttonStyle('plain'), accessibilityLabel('Settings')]}>
          <Image
            systemName="gearshape.fill"
            modifiers={[
              font({ textStyle: 'footnote', weight: 'bold' }),
              foregroundStyle(hud.ink),
              padding({ all: 9 }),
              background(hud.scrim, shapes.circle()),
            ]}
          />
        </Button>
      </Host>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  // `bottom: 132` clears the mini-map by guessing at a SwiftUI layout. It goes
  // away when the button moves into `OperatorView.chrome`.
  gear: { position: 'absolute', right: space.l, bottom: 132 },
});
