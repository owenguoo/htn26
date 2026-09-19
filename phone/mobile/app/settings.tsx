import { Host, List, ListItem, Switch } from '@expo/ui';
import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { Text } from 'react-native';

import SwarmSight, { type Diagnostics } from '../modules/swarm-sight';
import { setPreference, usePreferences } from '../src/preferences';

const value = (text: string) => <Text style={{ color: '#8e8e93' }}>{text}</Text>;

export default function Settings() {
  const { showDebug, showMiniMap } = usePreferences();
  const [state, setState] = useState<Diagnostics>({ joined: false });

  // The native side already pushes this at 2 Hz; no polling loop of our own.
  useEffect(() => {
    void SwarmSight.getDiagnostics().then(setState);
    const subscription = SwarmSight.addListener('onState', setState);
    return () => subscription.remove();
  }, []);

  const leave = async () => {
    await SwarmSight.leave();
    router.dismissAll();
    router.replace('/join');
  };

  return (
    <Host style={{ flex: 1 }}>
      <List>
        <ListItem trailing={<Switch value={showDebug} onValueChange={(on) => setPreference('showDebug', on)} />}>
          Marker outlines (calibration check)
        </ListItem>
        <ListItem trailing={<Switch value={showMiniMap} onValueChange={(on) => setPreference('showMiniMap', on)} />}>
          Mini-map
        </ListItem>
        {state.joined ? (
          <>
            <ListItem trailing={value(`#${state.index ?? '–'} · ${state.connection}`)}>Hub</ListItem>
            <ListItem trailing={value(`${state.sessionState} · ${state.trackingState}`)}>Tracking</ListItem>
            <ListItem trailing={value(state.alignment)}>Located by</ListItem>
            <ListItem trailing={value(state.roomPose ? `${state.roomPose.x.toFixed(1)}, ${state.roomPose.y.toFixed(1)} m` : '–')}>
              Room position
            </ListItem>
            <ListItem trailing={value(`${state.frameFPS.toFixed(1)} fps · ${state.dropped} dropped`)}>Frames</ListItem>
            <ListItem trailing={value(state.latencyP50Ms === undefined ? '–' : `${state.latencyP50Ms.toFixed(0)} ms`)}>
              Capture → send
            </ListItem>
            <ListItem trailing={value(state.thermal)}>Thermal</ListItem>
            {state.lastError ? <ListItem trailing={value(state.lastError)}>Last error</ListItem> : null}
            <ListItem onPress={() => SwarmSight.resetOrigin()}>Forget the marker lock</ListItem>
            <ListItem onPress={leave}>Leave the hub</ListItem>
          </>
        ) : (
          <ListItem trailing={value('not joined')}>Hub</ListItem>
        )}
      </List>
    </Host>
  );
}
