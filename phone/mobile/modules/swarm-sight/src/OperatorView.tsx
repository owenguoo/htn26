import { requireNativeView } from 'expo';
import * as React from 'react';

import type { OperatorViewProps } from './SwarmSight.types';

const NativeView: React.ComponentType<OperatorViewProps> = requireNativeView('SwarmSight');

/** The whole operator interface, native. React only decides whether it is on screen. */
export default function OperatorView(props: OperatorViewProps) {
  return <NativeView {...props} />;
}
