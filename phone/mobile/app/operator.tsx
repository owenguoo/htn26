import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import SwarmSight, { OperatorView } from '../modules/swarm-sight';
import { usePreferences } from '../src/preferences';

/**
 * One native view, the whole screen. Everything the operator sees at rate —
 * camera, arrow, flash, seat picker, mini-map — is SwiftUI inside it. React
 * only mounts it and handles leaving.
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
      <Pressable style={styles.gear} onPress={() => router.push('/settings')} hitSlop={12} testID="settings">
        <Text style={styles.gearText}>⚙︎</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1, backgroundColor: '#000' },
  gear: { position: 'absolute', right: 16, bottom: 132, width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(30,30,30,0.7)', alignItems: 'center', justifyContent: 'center' },
  gearText: { color: '#fff', fontSize: 20 },
});
