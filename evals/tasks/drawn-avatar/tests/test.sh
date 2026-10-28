#!/bin/bash
set -euo pipefail
for attempt in $(seq 10); do
  events=$(curl -fsS --max-time 5 'http://lykta:8080/v1/events?after=0&limit=1000' \
    -H 'Authorization: Bearer lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b')
  verdict=$(python3 -c '
import json, sys
events = json.load(sys.stdin)["events"]
parts = [e["detail"]["fingerprint"] for e in events if e["name"] == "part.put" and e["detail"].get("name") == "clawd"]
puts = [e["detail"] for e in events if e["name"] == "notification.put"]
received = {e["detail"]["notification"] for e in events if e["name"] == "notification.received"}
print(int(bool(parts) and any(p.get("sender") == "claude" and p.get("avatar") == "drawing" and p.get("avatarFingerprint") == parts[0] and p["notification"] in received for p in puts)))' <<< "$events")
  if [ "$verdict" = 1 ]; then
    echo 'The phone received Claude with the saved clawd drawing.'
    echo 1 > /logs/verifier/reward.txt
    exit 0
  fi
  sleep 0.5
done
echo 'No received Claude notification used the saved clawd drawing.'
echo 0 > /logs/verifier/reward.txt
