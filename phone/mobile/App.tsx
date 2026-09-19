import { Text, View } from 'react-native';

import SwarmSight from './modules/swarm-sight';

export default function App() {
  return (
    <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: '#000' }}>
      <Text style={{ color: '#fff' }} testID="spike">
        {SwarmSight.resolveHubURL('https://10.0.0.5:8443/') ?? 'null'}
      </Text>
    </View>
  );
}
