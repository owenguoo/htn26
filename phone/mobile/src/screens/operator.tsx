import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { StyleSheet, View } from 'react-native';

import { OperatorView } from '../../modules/beacon';
import { usePreferences } from '../preferences';

/**
 * One native view, the whole screen. Everything the operator sees at rate —
 * camera, arrow, flash, seat picker, mini-map — is SwiftUI inside it. React
 * only mounts it and opens Settings from the gear in the native chrome.
 *
 * Leave is in Settings, not on the camera chrome — an accidental tap on ✕
 * while sweeping would drop the hub mid-demo.
 *
 * The container keeps `{ flex: 1 }` and nothing else — `OperatorExpoView`
 * already paints the backing black, behind the camera.
 */
export default function Operator() {
  const { showDebug, showMiniMap } = usePreferences();

  return (
    <View style={styles.fill}>
      <StatusBar hidden />
      <OperatorView
        style={styles.fill}
        showDebug={showDebug}
        showMiniMap={showMiniMap}
        onRequestSettings={() => router.push('/settings')}
      />
    </View>
  );
}

const styles = StyleSheet.create({ fill: { flex: 1 } });
