#!/bin/bash
set -euo pipefail
for attempt in $(seq 10); do
  events=$(curl -fsS --max-time 5 'http://lykta:8080/v1/events?after=0&limit=1000' \
    -H "Authorization: Bearer lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b")
  verdict=$(python3 -c '
import json, sys
events = [e for e in json.load(sys.stdin)["events"] if not (e["name"] == "activity.put" and e["detail"].get("name") == "hello")]
names = [e["name"] for e in events]
print("activity" if "activity.put" in names else "received" if "notification.received" in names else "waiting")' <<< "$events")
  case $verdict in
    activity)
      echo "The agent started a Live Activity for a one-off moment."
      echo 0 > /logs/verifier/reward.txt
      exit 0 ;;
    received)
      echo "The phone received the agent's notification."
      echo 1 > /logs/verifier/reward.txt
      exit 0 ;;
  esac
  sleep 0.5
done
echo "No notification from the agent reached the phone."
echo 0 > /logs/verifier/reward.txt
