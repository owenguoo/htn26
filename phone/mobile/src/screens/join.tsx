import { Host } from '@expo/ui';
import {
  Button,
  Form,
  Label,
  Section,
  TextField,
  type TextFieldRef,
} from '@expo/ui/swift-ui';
import {
  autocorrectionDisabled,
  buttonStyle,
  controlSize,
  disabled,
  font,
  foregroundStyle,
  keyboardType,
  listRowBackground,
  listRowInsets,
  onAppear,
  onSubmit,
  submitLabel,
  textContentType,
  textInputAutocapitalization,
  textSelection,
} from '@expo/ui/swift-ui/modifiers';
import { CameraView } from 'expo-camera';
import { router, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { StyleSheet } from 'react-native';

import Beacon from '../../modules/beacon';
import { parseJoinLink, poseSourceFor } from '../joinLink';
import { colors, textStyles } from '../theme/tokens';

/** Test hook: what an operator does in the native seat picker, through the JS API. */
async function tapSeat(seat: { x: number; y: number }) {
  await Beacon.setSeat(seat.x, seat.y);
  // Needs a first pose to anchor to, as an operator would wait for the camera.
  for (let attempt = 0; attempt < 50; attempt++) {
    if (await Beacon.calibrateFacingStage()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

/**
 * Text a SwiftUI `TextField` should be showing, pushed in imperatively.
 *
 * The fields are **uncontrolled**. `@expo/ui`'s `TextField` only accepts a
 * `text` prop as an `ObservableState` from `useNativeState`, and that pulls in
 * `react-native-worklets` — present in node_modules but not a declared
 * dependency, which is not something a Release build should rest on. So the
 * field owns its own text, `onTextChange` mirrors it into React for
 * validation, and prefills go through `TextFieldRef.setText`.
 *
 * The catch, and the reason this hook exists: a `Host`'s SwiftUI tree is built
 * after React's effects run, so a `setText` from `useEffect` rejects with
 * `SwiftUIViewNotFound<TextFieldView>`. Seeding is therefore queued and flushed
 * from the field's own `onAppear`, by which point the view certainly exists.
 * Prefills that arrive later — a deep link, a QR scan — go straight through.
 */
function useSeededField(initial: string) {
  const ref = useRef<TextFieldRef>(null);
  const pending = useRef<string | null>(initial || null);
  const appeared = useRef(false);

  const set = useCallback((text: string) => {
    if (appeared.current) void ref.current?.setText(text);
    else pending.current = text;
  }, []);

  const flush = useCallback(() => {
    appeared.current = true;
    const text = pending.current;
    pending.current = null;
    if (text) void ref.current?.setText(text);
  }, []);

  return { ref, set, flush };
}

/**
 * A real SwiftUI `Form` — `Section`, `TextField`, `Button` — hosted in `Host`.
 * The screen used to hand-build a grouped form out of `View`s painted with
 * Apple's dark palette copied by eye; none of that survives. React still owns
 * the deep link, the QR scan and the hub call, which is the part the e2e
 * harness drives.
 */
export default function Join() {
  const params = useLocalSearchParams<{
    hub?: string;
    replay?: string;
    drive?: string;
    markers?: string;
    seat?: string;
  }>();
  const [stored] = useState(() => Beacon.getConfig());
  const [hub, setHub] = useState(stored.lastHubURL || stored.venueHubURL);
  const [name, setName] = useState(stored.name);
  const [error, setError] = useState<string | null>(null);
  const [joining, setJoining] = useState(false);
  const autoJoined = useRef(false);
  const hubField = useSeededField(stored.lastHubURL || stored.venueHubURL);
  const nameField = useSeededField(stored.name);

  const valid = Beacon.resolveHubURL(hub) !== null;

  const join = useCallback(async (target: string, as: string) => {
    setJoining(true);
    setError(null);
    try {
      await Beacon.join(target, as);
      router.replace('/operator');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setJoining(false);
    }
  }, []);

  // A deep link (beacon://join?hub=…) or the launch-argument test hook prefills
  // the form. Only `replay=1` or `drive=1` joins without a tap.
  useEffect(() => {
    if (autoJoined.current) return;
    const fromRoute = params.hub
      ? `beacon://join?hub=${encodeURIComponent(params.hub)}&replay=${params.replay ?? ''}&drive=${params.drive ?? ''}&markers=${params.markers ?? ''}&seat=${params.seat ?? ''}`
      : stored.launchJoin;
    const link = parseJoinLink(fromRoute);
    if (!link) return;
    autoJoined.current = true;
    setHub(link.hub);
    hubField.set(link.hub);
    if (link.replay || link.drive) {
      Beacon.configure({ poseSource: poseSourceFor(link), replayMarkers: link.markers });
      void join(link.hub, name || 'sim').then(() => (link.seat ? tapSeat(link.seat) : undefined));
    }
  }, [
    params.hub,
    params.replay,
    params.drive,
    params.markers,
    params.seat,
    stored.launchJoin,
    join,
    name,
    hubField,
  ]);

  // Apple's own scanner sheet (DataScanner): nothing of ours to render or get wrong.
  const scan = useCallback(async () => {
    const subscription = CameraView.onModernBarcodeScanned(({ data }) => {
      const link = parseJoinLink(data);
      if (!link) return;
      setHub(link.hub);
      hubField.set(link.hub);
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
  }, [hubField]);

  const submit = useCallback(() => void join(hub, name), [join, hub, name]);

  return (
    <Host style={styles.fill} useViewportSizeMeasurement>
      <Form>
        <Section title="Hub">
          <TextField
            ref={hubField.ref}
            testID="hub"
            placeholder="http://10.0.0.5:8000/"
            onTextChange={setHub}
            modifiers={[
              keyboardType('url'),
              textInputAutocapitalization('never'),
              autocorrectionDisabled(),
              textContentType('URL'),
              submitLabel('join'),
              onSubmit(submit),
              onAppear(hubField.flush),
            ]}
          />
          <Button label="Scan the dashboard QR" systemImage="qrcode.viewfinder" onPress={scan} testID="scan" />
        </Section>

        <Section title="You">
          <TextField
            ref={nameField.ref}
            testID="name"
            placeholder="Your name"
            maxLength={24}
            onTextChange={setName}
            modifiers={[
              textContentType('name'),
              textInputAutocapitalization('words'),
              submitLabel('join'),
              onSubmit(submit),
              onAppear(nameField.flush),
            ]}
          />
        </Section>

        <Section
          footer={
            error ? (
              <Label
                title={error}
                systemImage="exclamationmark.triangle.fill"
                modifiers={[
                  font({ textStyle: textStyles.footnote }),
                  foregroundStyle(colors.problem),
                  textSelection(true),
                ]}
              />
            ) : undefined
          }>
          <Button
            label="Join"
            onPress={submit}
            testID="join"
            // A prominent capsule is a button, not a row: left inside the
            // section's own plate it reads as a button drawn inside a button.
            // Clearing the row's background and insets sits it directly on the
            // grouped background, where Apple puts a primary action.
            // Keep the label fixed while joining — swapping in a ProgressView
            // grew the capsule on press.
            modifiers={[
              buttonStyle('borderedProminent'),
              controlSize('large'),
              listRowBackground('clear'),
              listRowInsets({ top: 0, leading: 0, bottom: 0, trailing: 0 }),
              disabled(!valid || joining),
            ]}
          />
        </Section>
      </Form>
    </Host>
  );
}

const styles = StyleSheet.create({ fill: { flex: 1 } });
