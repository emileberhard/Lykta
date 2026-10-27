#!/bin/bash
set -euo pipefail
for attempt in $(seq 10); do
  events=$(curl -fsS --max-time 5 'http://lykta:8080/v1/events?after=0&limit=1000' \
    -H "Authorization: Bearer lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b")
  verdict=$(python3 -c '
import json, sys
events = json.load(sys.stdin)["events"]
sounds = [e["detail"].get("sound") for e in events if e["name"] == "notification.received"]
print("activity" if any(e["name"] == "activity.put" and e["detail"].get("name") != "hello" for e in events) else "custom" if "custom" in sounds else "other" if sounds else "waiting")' <<< "$events")
  case $verdict in
    activity)
      echo "The agent started a Live Activity for a one-off moment."
      echo 0 > /logs/verifier/reward.txt
      exit 0 ;;
    custom)
      echo "The phone played the agent's own sound."
      echo 1 > /logs/verifier/reward.txt
      exit 0 ;;
    other)
      echo "The phone received the notification without the agent's own sound."
      echo 0 > /logs/verifier/reward.txt
      exit 0 ;;
  esac
  sleep 0.5
done
echo "No notification from the agent reached the phone."
echo 0 > /logs/verifier/reward.txt
