import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import SwarmSight, { OperatorView } from '../../modules/swarm-sight';
import { usePreferences } from '../preferences';

/**
 * One native view, the whole screen. Everything the operator sees at rate —
 * camera, arrow, flash, seat picker, mini-map — is SwiftUI inside it. React
 * only mounts it and decides where the two chrome buttons lead.
 *
 * There is no React chrome left here: the settings gear used to be a
 * `Pressable` whose content was the text glyph `⚙︎`, absolutely positioned at
 * `bottom: 132` by guessing at a SwiftUI layout. It is now an
 * `Image(systemName: "gearshape.fill")` button beside the leave button inside
 * `OperatorView.chrome`, so both pieces of camera chrome share one style and
 * one layout pass.
 *
 * The container keeps `{ flex: 1 }` and nothing else — `OperatorExpoView`
 * already paints the backing black, behind the camera.
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
      <OperatorView
        style={styles.fill}
        showDebug={showDebug}
        showMiniMap={showMiniMap}
        onRequestLeave={leave}
        onRequestSettings={() => router.push('/settings')}
      />
    </View>
  );
}

const styles = StyleSheet.create({ fill: { flex: 1 } });
