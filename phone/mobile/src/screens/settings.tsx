import { Host } from '@expo/ui';
import { Button, Form, Label, LabeledContent, Section, Text, Toggle } from '@expo/ui/swift-ui';
import {
  background,
  disabled,
  font,
  foregroundStyle,
  monospacedDigit,
  scrollContentBackground,
  textSelection,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { StyleSheet } from 'react-native';

import Beacon, { type Diagnostics, type MicState } from '../../modules/beacon';
import { setPreference, usePreferences } from '../preferences';
import { colors, consoleInk, secondaryStyle, textStyles } from '../theme/tokens';

/**
 * A row value. Hierarchical `secondary` rather than a hardcoded grey, and
 * monospaced digits so the numbers stop dancing while the 2 Hz state ticks.
 */
const Value = ({ children }: { children: string }) => (
  <Text modifiers={[foregroundStyle(secondaryStyle), monospacedDigit(), textSelection(true)]}>{children}</Text>
);

/**
 * What each microphone state means, in the operator's terms. The distinction
 * that matters on a demo floor is "off because I turned it off" versus "off
 * because nothing is listening", and the web client's struck-through pill made
 * exactly that distinction (`web/phone.html`, `.mic.off`).
 */
const MIC_STATUS: Record<MicState, string> = {
  unavailable: 'no microphone',
  muted: 'off',
  idle: 'listening',
  speaking: 'sending',
};

const MIC_FOOTER: Partial<Record<MicState, string>> = {
  muted: 'Off. Nothing is captured while this is off, and the hub was told your last sentence had ended.',
  idle: 'Listening. Nothing leaves the phone until you speak; quiet room audio is never sent.',
  speaking: 'Sending. The operator sees what you say as a live caption. Used live, never stored.',
};

const CONNECTION_SYMBOL = {
  online: 'antenna.radiowaves.left.and.right',
  connecting: 'antenna.radiowaves.left.and.right',
  reconnecting: 'antenna.radiowaves.left.and.right',
  offline: 'antenna.radiowaves.left.and.right.slash',
} as const;

export default function Settings() {
  const { showDebug, showMiniMap } = usePreferences();
  const [state, setState] = useState<Diagnostics>({ joined: false });
  // The native side is the truth and pushes it at 2 Hz, but 500 ms of a switch
  // sitting where you did not leave it reads as a broken switch. `setMicrophoneMuted`
  // returns the new state, so hold that until the next push agrees.
  const [pendingMic, setPendingMic] = useState<MicState | null>(null);
  const micState: MicState = pendingMic ?? (state.joined ? state.micState : 'unavailable');

  // The native side already pushes this at 2 Hz; no polling loop of our own.
  useEffect(() => {
    const apply = (next: Diagnostics) => {
      setState(next);
      setPendingMic((pending) => {
        if (pending === null) return null;
        const live: MicState = next.joined ? next.micState : 'unavailable';
        // Only the muted bit belongs to the toggle. `idle` ↔ `speaking` is the
        // loudness gate moving on its own, and holding a stale optimistic value
        // over it would freeze the status line mid-sentence.
        return (pending === 'muted') === (live === 'muted') ? null : pending;
      });
    };
    void Beacon.getDiagnostics().then(apply);
    const subscription = Beacon.addListener('onState', apply);
    return () => subscription.remove();
  }, []);

  const setMicrophoneOn = async (on: boolean) => {
    setPendingMic(on ? 'idle' : 'muted');
    setPendingMic(await Beacon.setMicrophoneMuted(!on));
  };

  const leave = async () => {
    await Beacon.leave();
    router.dismissAll();
    router.replace('/join');
  };

  return (
    <Host style={styles.fill} useViewportSizeMeasurement>
      <Form modifiers={[tint(colors.accent), scrollContentBackground('hidden'), background(consoleInk.bg)]}>
        {state.joined ? (
          <Section
            title="Position"
            footer={
              <Text/>
            }>
            {/* Recalibrate belongs behind one more tap than a sweep. It spent a
                while on the camera chrome as a bare ↻, where it read as
                "reload" rather than as throwing the marker lock away. */}
            <Button
              label="Recalibrate"
              systemImage="arrow.clockwise"
              onPress={() => {
                void Beacon.resetOrigin();
                router.back();
              }}
            />
          </Section>
        ) : null}

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

        <Section
          title="Voice"
          footer={
            MIC_FOOTER[micState] ? (
              <Text modifiers={[font({ textStyle: textStyles.footnote })]}>{MIC_FOOTER[micState]}</Text>
            ) : undefined
          }>
          <Toggle
            label="Microphone"
            systemImage={micState === 'unavailable' || micState === 'muted' ? 'mic.slash' : 'mic.fill'}
            isOn={micState !== 'muted' && micState !== 'unavailable'}
            onIsOnChange={(on) => void setMicrophoneOn(on)}
            modifiers={micState === 'unavailable' ? [disabled(true)] : []}
          />
          <LabeledContent label="Status">
            <Value>{MIC_STATUS[micState]}</Value>
          </LabeledContent>
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
            label="Leave the hub"
            systemImage="rectangle.portrait.and.arrow.right"
            role="destructive"
            onPress={() => void leave()}
            // `role="destructive"` reddens the title but leaves the SF Symbol on
            // the accent colour, so the row reads half-destructive. `tint` does
            // not reach it either — in a Form row that drives the accent, not the
            // label's foreground. `foregroundStyle` colours glyph and text alike.
            modifiers={[foregroundStyle(colors.problem), tint(colors.problem)]}
          />
        </Section>
      </Form>
    </Host>
  );
}

const styles = StyleSheet.create({ fill: { flex: 1 } });
