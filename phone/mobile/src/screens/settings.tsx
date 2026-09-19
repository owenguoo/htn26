import { Host } from '@expo/ui';
import { Button, Form, Label, LabeledContent, Picker, Section, Text, Toggle } from '@expo/ui/swift-ui';
import { font, foregroundStyle, monospacedDigit, pickerStyle, tag, textSelection } from '@expo/ui/swift-ui/modifiers';
import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { StyleSheet } from 'react-native';

import SwarmSight, { type Diagnostics, type ThemePreference } from '../../modules/swarm-sight';
import { setPreference, usePreferences } from '../preferences';
import { colors, secondaryStyle, textStyles } from '../theme/tokens';

/**
 * A row value. Hierarchical `secondary` rather than a hardcoded grey, and
 * monospaced digits so the numbers stop dancing while the 2 Hz state ticks.
 */
const Value = ({ children }: { children: string }) => (
  <Text modifiers={[foregroundStyle(secondaryStyle), monospacedDigit(), textSelection(true)]}>{children}</Text>
);

const CONNECTION_SYMBOL = {
  online: 'antenna.radiowaves.left.and.right',
  connecting: 'antenna.radiowaves.left.and.right',
  reconnecting: 'antenna.radiowaves.left.and.right',
  offline: 'antenna.radiowaves.left.and.right.slash',
} as const;

export default function Settings() {
  const { showDebug, showMiniMap, theme } = usePreferences();
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
    <Host style={styles.fill} useViewportSizeMeasurement>
      <Form>
        <Section title="Appearance" footer={<Text modifiers={[font({ textStyle: textStyles.footnote })]}>
          Dark by default. The choice is remembered on this phone.
        </Text>}>
          <Picker<ThemePreference>
            label="Theme"
            selection={theme}
            onSelectionChange={(next) => setPreference('theme', next)}
            modifiers={[pickerStyle('segmented')]}>
            <Text modifiers={[tag('system')]}>System</Text>
            <Text modifiers={[tag('light')]}>Light</Text>
            <Text modifiers={[tag('dark')]}>Dark</Text>
          </Picker>
        </Section>

        <Section title="Over the camera">
          <Toggle
            label="Marker outlines"
            systemImage="viewfinder"
            isOn={showDebug}
            onIsOnChange={(on) => setPreference('showDebug', on)}
          />
          <Toggle
            label="Mini-map"
            systemImage="map.fill"
            isOn={showMiniMap}
            onIsOnChange={(on) => setPreference('showMiniMap', on)}
          />
        </Section>

        {state.joined ? (
          <Section title="Diagnostics">
            <LabeledContent label={<Label title="Hub" systemImage={CONNECTION_SYMBOL[state.connection]} />}>
              <Value>{`#${state.index ?? '–'} · ${state.connection}`}</Value>
            </LabeledContent>
            <LabeledContent label="Tracking">
              <Value>{`${state.sessionState} · ${state.trackingState}`}</Value>
            </LabeledContent>
            <LabeledContent label="Located by">
              <Value>{state.alignment}</Value>
            </LabeledContent>
            <LabeledContent label="Room position">
              <Value>
                {state.roomPose ? `${state.roomPose.x.toFixed(1)}, ${state.roomPose.y.toFixed(1)} m` : '–'}
              </Value>
            </LabeledContent>
            <LabeledContent label="Frames">
              <Value>{`${state.frameFPS.toFixed(1)} fps · ${state.dropped} dropped`}</Value>
            </LabeledContent>
            <LabeledContent label="Capture → send">
              <Value>{state.latencyP50Ms === undefined ? '–' : `${state.latencyP50Ms.toFixed(0)} ms`}</Value>
            </LabeledContent>
            <LabeledContent label="Thermal">
              <Value>{state.thermal}</Value>
            </LabeledContent>
            {state.lastError ? (
              <LabeledContent label="Last error">
                <Text
                  modifiers={[foregroundStyle(colors.problem), font({ textStyle: textStyles.footnote }), textSelection(true)]}>
                  {state.lastError}
                </Text>
              </LabeledContent>
            ) : null}
          </Section>
        ) : (
          <Section title="Diagnostics">
            <LabeledContent label="Hub">
              <Value>not joined</Value>
            </LabeledContent>
          </Section>
        )}

        <Section>
          <Button
            label="Forget the marker lock"
            systemImage="arrow.clockwise"
            role="destructive"
            onPress={() => void SwarmSight.resetOrigin()}
          />
          <Button
            label="Leave the hub"
            systemImage="rectangle.portrait.and.arrow.right"
            role="destructive"
            onPress={() => void leave()}
          />
        </Section>
      </Form>
    </Host>
  );
}

const styles = StyleSheet.create({ fill: { flex: 1 } });
