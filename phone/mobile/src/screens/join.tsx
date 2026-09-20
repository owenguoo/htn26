import { Host } from '@expo/ui';
import {
  Button,
  Form,
  Image as SymbolImage,
  Label,
  Section,
  TextField,
  type TextFieldRef,
} from '@expo/ui/swift-ui';
import {
  autocorrectionDisabled,
  background,
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
  scrollContentBackground,
  submitLabel,
  textInputAutocapitalization,
  textSelection,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { CameraView } from 'expo-camera';
import { router, Stack, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import Beacon from '../../modules/beacon';
import { parseJoinLink, poseSourceFor } from '../joinLink';
import { colors, consoleInk, mono, space, textStyles } from '../theme/tokens';

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
  // Always the latest text, not just the first: the form is unmounted while
  // the summary is up, and every time it comes back its fields are new and
  // empty, so `flush` has to be able to seed them again.
  const latest = useRef(initial);
  const appeared = useRef(false);

  const set = useCallback((text: string) => {
    latest.current = text;
    if (appeared.current) void ref.current?.setText(text);
  }, []);

  const track = useCallback((text: string) => {
    latest.current = text;
  }, []);

  const flush = useCallback(() => {
    appeared.current = true;
    if (latest.current) void ref.current?.setText(latest.current);
  }, []);

  // Memoised: without this the handle is a fresh object every render, which
  // gives `hubField`/`nameField` new identity on every keystroke. That re-ran
  // the auto-join effect (which lists `hubField` in its deps) and rebuilt the
  // `scan` callback, so every character retyped a template literal and made a
  // synchronous `resolveHubURL` call into native.
  return useMemo(() => ({ ref, set, track, flush }), [set, track, flush]);
}

/** "10.0.0.5:8000" out of whatever was typed or scanned, for the summary row. */
function hubHost(hub: string, resolved: string | null): string {
  return resolved?.match(/^[a-z]+:\/\/([^/]+)/i)?.[1] ?? hub;
}

/**
 * Two faces. **The summary** is what an operator who scanned the dashboard QR
 * sees: the console's `--bg`, who they are joining as in one large line, the
 * hub in a square hairline panel, and one pill to press. It is drawn in the
 * operator console's palette (`consoleInk`) because it is the first screen of
 * the same product. **The form** is still a real SwiftUI `Form` — `Section`,
 * `TextField`, `Button` — for when there is something to type. React owns the
 * deep link, the QR scan and the hub call, which is the part the e2e harness
 * drives.
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
  // A ref, not state: re-entry has to be blocked, but re-rendering the button
  // into a disabled (grey) capsule mid-join reads as a dead control on the one
  // screen where the operator is waiting for something to happen.
  const joining = useRef(false);
  const autoJoined = useRef(false);
  const hubField = useSeededField(stored.lastHubURL || stored.venueHubURL);
  const nameField = useSeededField(stored.name);

  // `resolveHubURL` crosses into native. It was called 2-3× per render — on
  // every keystroke — for a value that only depends on `hub`.
  const resolvedHub = useMemo(() => Beacon.resolveHubURL(hub), [hub]);
  const valid = resolvedHub !== null;
  // Nothing to confirm until there is a hub and a name, so a first launch
  // opens on the form; a returning or deep-linked operator gets the summary.
  const [editing, setEditing] = useState(() => !valid || !stored.name.trim());
  const insets = useSafeAreaInsets();
  const hasName = useRef(false);
  hasName.current = name.trim().length > 0;

  const join = useCallback(async (target: string, as: string) => {
    if (joining.current) return;
    joining.current = true;
    setError(null);
    try {
      await Beacon.join(target, as);
      router.replace('/operator');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      joining.current = false;
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
    if (name.trim()) setEditing(false);
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
      // A scanned hub is an answer, not something to proofread in a field.
      if (hasName.current) setEditing(false);
      void CameraView.dismissScanner();
    });
    try {
      await CameraView.launchScanner({ barcodeTypes: ['qr'] });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      // Synchronous. On a 30 s timer, dismissing the sheet without scanning
      // left the listener live, and tapping scan again stacked another — after
      // which one scan fired every accumulated listener.
      subscription.remove();
    }
  }, [hubField]);

  const submit = useCallback(() => void join(hub, name), [join, hub, name]);
  const onHubText = useCallback(
    (text: string) => {
      hubField.track(text);
      setHub(text);
    },
    [hubField],
  );
  const onNameText = useCallback(
    (text: string) => {
      nameField.track(text);
      setName(text);
    },
    [nameField],
  );

  if (!editing) {
    return (
      <View style={[styles.summary, { paddingTop: insets.top + space.l, paddingBottom: insets.bottom + space.l }]}>
        <Stack.Screen options={{ headerShown: false }} />
        <View style={styles.bar}>
          {/* The console's own mark, a copy of `web/beacon_logo.png`. */}
          <Image source={require('../../assets/beacon_logo.png')} style={styles.logo} accessible={false} />
          <Text style={styles.wordmark}>beacon</Text>
          <View style={styles.fill} />
          <Pressable
            onPress={scan}
            testID="scan"
            accessibilityRole="button"
            accessibilityLabel="Scan the dashboard QR"
            style={({ pressed }) => [styles.round, pressed && styles.pressed]}>
            <Host matchContents>
              <SymbolImage systemName="qrcode.viewfinder" size={20} color={consoleInk.fg} />
            </Host>
          </Pressable>
        </View>

        <View style={styles.hero}>
          <Text style={styles.eyebrow}>JOINING AS</Text>
          <Text style={styles.name} numberOfLines={2} adjustsFontSizeToFit>
            {name.trim()}
          </Text>
          <View style={styles.panel}>
            <View style={styles.row}>
              <Text style={styles.rowLabel}>Hub</Text>
              <Text style={styles.rowValue} numberOfLines={1} selectable>
                {hubHost(hub, resolvedHub)}
              </Text>
            </View>
          </View>
          {error ? (
            <Text style={styles.error} selectable>
              {error}
            </Text>
          ) : null}
        </View>

        <Pressable
          onPress={() => setEditing(true)}
          testID="edit"
          accessibilityRole="button"
          style={({ pressed }) => [styles.pill, styles.quiet, pressed && styles.pressed]}>
          <Text style={styles.quietLabel}>Change hub or name</Text>
        </Pressable>
        <Pressable
          onPress={submit}
          disabled={!valid}
          testID="join"
          accessibilityRole="button"
          style={({ pressed }) => [styles.pill, styles.primary, pressed && styles.pressed, !valid && styles.disabled]}>
          <Text style={styles.primaryLabel}>Join search</Text>
        </Pressable>
      </View>
    );
  }

  return (
    <Host style={styles.fill} useViewportSizeMeasurement>
      <Stack.Screen options={{ headerShown: true }} />
      {/* Apple's form, in the console's colours: `--accent` for every control
          and `--bg` where the grouped grey was. */}
      <Form modifiers={[tint(colors.accent), scrollContentBackground('hidden'), background(consoleInk.bg)]}>
        <Section title="Hub">
          <TextField
            ref={hubField.ref}
            testID="hub"
            placeholder="http://10.0.0.5:8000/"
            onTextChange={onHubText}
            modifiers={[
              keyboardType('url'),
              textInputAutocapitalization('never'),
              autocorrectionDisabled(),
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
            onTextChange={onNameText}
            modifiers={[
              textInputAutocapitalization('words'),
              autocorrectionDisabled(),
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
            // Keep the label and the tint fixed while joining — swapping in a
            // ProgressView grew the capsule on press, and disabling the button
            // greyed it out for the whole hub call. A ref guards re-entry
            // instead, so the capsule only greys out for an unusable hub URL.
            modifiers={[
              buttonStyle('borderedProminent'),
              controlSize('large'),
              listRowBackground('clear'),
              listRowInsets({ top: 0, leading: 0, bottom: 0, trailing: 0 }),
              disabled(!valid),
            ]}
          />
        </Section>
      </Form>
    </Host>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  summary: { flex: 1, backgroundColor: consoleInk.bg, paddingHorizontal: space.xl, gap: space.s },
  bar: { flexDirection: 'row', alignItems: 'center', gap: space.xs },
  logo: { width: 44, height: 44 },
  wordmark: { fontSize: 17, fontWeight: '600', letterSpacing: -0.2, color: consoleInk.fg },
  round: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: consoleInk.bg2,
  },
  hero: { flex: 1, justifyContent: 'center', gap: space.xs },
  eyebrow: { fontFamily: mono, fontSize: 12, letterSpacing: 0.6, color: consoleInk.fg3 },
  name: { fontSize: 56, fontWeight: '700', letterSpacing: -1.6, lineHeight: 60, color: consoleInk.fg },
  // A console panel: square, hairline, `--surface` on `--bg`.
  panel: {
    marginTop: space.xl,
    borderWidth: StyleSheet.hairlineWidth * 2,
    borderColor: consoleInk.line,
    backgroundColor: consoleInk.surface,
  },
  row: { flexDirection: 'row', alignItems: 'center', gap: space.m, paddingHorizontal: space.m, paddingVertical: space.m },
  rowLabel: { fontSize: 15, color: consoleInk.fg2 },
  rowValue: { flex: 1, textAlign: 'right', fontFamily: mono, fontSize: 15, color: consoleInk.fg },
  error: { marginTop: space.m, fontSize: 13, color: consoleInk.red },
  // `--r-pill`: a control whose round outline is the affordance.
  pill: { height: 56, borderRadius: 28, alignItems: 'center', justifyContent: 'center' },
  quiet: { height: 48, borderRadius: 24, backgroundColor: consoleInk.bg2 },
  quietLabel: { fontSize: 15, fontWeight: '600', color: consoleInk.fg },
  primary: { backgroundColor: consoleInk.fg },
  primaryLabel: { fontSize: 17, fontWeight: '600', color: consoleInk.bg },
  pressed: { opacity: 0.72 },
  disabled: { opacity: 0.4 },
});
