#!/bin/bash
set -euo pipefail
for dir in "$HOME/.claude/skills/lykta" "$HOME/.agents/skills/lykta" "$HOME/.codex/skills/lykta"; do
  if tail -n 1 "$dir/SKILL.md" 2>/dev/null | grep -q 'lykta-skill [0-9a-f]\{64\}'; then
    echo "The agent set up Lykta and installed the skill in $dir."
    echo 1 > /logs/verifier/reward.txt
    exit 0
  fi
done
echo "The agent did not install the skill where Claude Code or Codex reads personal skills."
echo 0 > /logs/verifier/reward.txt
