import { CameraView } from 'expo-camera';
import { router, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { KeyboardAvoidingView, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';

import SwarmSight from '../modules/swarm-sight';
import { parseJoinLink } from '../src/joinLink';

/** Test hook: what an operator does in the native seat picker, through the JS API. */
async function tapSeat(seat: { x: number; y: number }) {
  await SwarmSight.setSeat(seat.x, seat.y);
  // Needs a first pose to anchor to, as an operator would wait for the camera.
  for (let attempt = 0; attempt < 50; attempt++) {
    if (await SwarmSight.calibrateFacingStage()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

export default function Join() {
  const params = useLocalSearchParams<{ hub?: string; replay?: string; markers?: string; seat?: string }>();
  const [stored] = useState(() => SwarmSight.getConfig());
  const [hub, setHub] = useState(stored.lastHubURL || stored.venueHubURL);
  const [name, setName] = useState(stored.name);
  const [error, setError] = useState<string | null>(null);
  const [joining, setJoining] = useState(false);
  const autoJoined = useRef(false);

  const valid = SwarmSight.resolveHubURL(hub) !== null;

  const join = useCallback(async (target: string, as: string) => {
    setJoining(true);
    setError(null);
    try {
      await SwarmSight.join(target, as);
      router.replace('/operator');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setJoining(false);
    }
  }, []);

  // A deep link (swarmsight://join?hub=…) or the launch-argument test hook prefills
  // the form. Only `replay=1` joins without a tap.
  useEffect(() => {
    if (autoJoined.current) return;
    const fromRoute = params.hub
      ? `swarmsight://join?hub=${encodeURIComponent(params.hub)}&replay=${params.replay ?? ''}&markers=${params.markers ?? ''}&seat=${params.seat ?? ''}`
      : stored.launchJoin;
    const link = parseJoinLink(fromRoute);
    if (!link) return;
    autoJoined.current = true;
    setHub(link.hub);
    if (link.replay) {
      SwarmSight.configure({ poseSource: 'replay', replayMarkers: link.markers });
      void join(link.hub, name || 'sim').then(() => (link.seat ? tapSeat(link.seat) : undefined));
    }
  }, [params.hub, params.replay, params.markers, params.seat, stored.launchJoin, join, name]);

  // Apple's own scanner sheet (DataScanner): nothing of ours to render or get wrong.
  const scan = useCallback(async () => {
    const subscription = CameraView.onModernBarcodeScanned(({ data }) => {
      const link = parseJoinLink(data);
      if (!link) return;
      setHub(link.hub);
      setError(null);
      void CameraView.dismissScanner();
    });
    try {
      await CameraView.launchScanner({ barcodeTypes: ['qr'] });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setTimeout(() => subscription.remove(), 30_000);
    }
  }, []);

  return (
    <KeyboardAvoidingView style={styles.fill} behavior="padding">
      <ScrollView contentInsetAdjustmentBehavior="automatic" keyboardShouldPersistTaps="handled" contentContainerStyle={styles.content}>
        <Text style={styles.label}>HUB</Text>
        <View style={styles.group}>
          <TextInput
            style={styles.input}
            value={hub}
            onChangeText={setHub}
            placeholder="http://10.0.0.5:8000/"
            placeholderTextColor="#666"
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            testID="hub"
          />
          <View style={styles.separator} />
          <Pressable onPress={scan} style={styles.row} testID="scan">
            <Text style={styles.link}>Scan the dashboard QR</Text>
          </Pressable>
        </View>

        <Text style={styles.label}>YOU</Text>
        <View style={styles.group}>
          <TextInput
            style={styles.input}
            value={name}
            onChangeText={setName}
            placeholder="Your name"
            placeholderTextColor="#666"
            maxLength={24}
            testID="name"
          />
        </View>

        {error ? <Text style={styles.error}>{error}</Text> : null}

        <Pressable
          onPress={() => join(hub, name)}
          disabled={!valid || joining}
          style={[styles.button, (!valid || joining) && styles.disabled]}
          testID="join">
          <Text style={styles.buttonText}>{joining ? 'Joining…' : 'Join'}</Text>
        </Pressable>

        <Text style={styles.footnote}>
          The address on the dashboard’s QR code. Phone {stored.phoneId.slice(0, 8)}
          {stored.poseSource === 'replay' ? ' · no ARKit here, so this will replay a recorded walk' : ''}.
        </Text>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1, backgroundColor: '#000' },
  content: { padding: 20, gap: 8 },
  label: { color: '#8e8e93', fontSize: 13, marginTop: 16, marginLeft: 16 },
  group: { backgroundColor: '#1c1c1e', borderRadius: 14, overflow: 'hidden' },
  input: { color: '#fff', fontSize: 17, paddingHorizontal: 16, paddingVertical: 14 },
  separator: { height: StyleSheet.hairlineWidth, backgroundColor: '#38383a', marginLeft: 16 },
  row: { paddingHorizontal: 16, paddingVertical: 14 },
  link: { color: '#0a84ff', fontSize: 17 },
  error: { color: '#ffd60a', fontSize: 15, marginTop: 12, marginHorizontal: 16 },
  button: { backgroundColor: '#0a84ff', borderRadius: 14, paddingVertical: 15, alignItems: 'center', marginTop: 24 },
  disabled: { opacity: 0.4 },
  buttonText: { color: '#fff', fontSize: 17, fontWeight: '600' },
  footnote: { color: '#8e8e93', fontSize: 13, marginTop: 12, marginHorizontal: 16 },
});
