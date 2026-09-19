# Vendored agent skills

Copies of the skills this client's Expo work relies on, committed so every
teammate's agent (Claude Code, Cursor, Codex) has the same guidance without a
global install. `phone/.claude/skills` is a symlink here.

| Skill | Source |
|---|---|
| `expo-module`, `expo-dev-client`, `expo-ui`, `expo-native-ui`, `expo-router`, `expo-project-structure` | https://github.com/expo/skills (`plugins/expo/skills/`) |
| `vercel-react-native-skills` | https://github.com/vercel-labs/agent-skills (`skills/react-native-skills`) |

Refresh by reinstalling globally and re-copying:

    pnpm dlx skills add expo/skills@<name> -g -a cursor -y --copy
    cp -R ~/.agents/skills/<name> phone/.agents/skills/

Skills run with full agent permissions — review diffs when refreshing.
