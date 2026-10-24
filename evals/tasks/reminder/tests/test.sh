#!/bin/bash
set -euo pipefail
events=$(curl -fsS --max-time 5 'http://lykta:8080/v1/events?after=0&limit=1000' \
  -H "Authorization: Bearer lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b")
if python3 -c 'import json, sys; sys.exit(any(e["name"] in ("activity.put", "notification.put") for e in json.load(sys.stdin)["events"]))' <<< "$events"; then
  echo "The agent showed nothing now."
  echo 1 > /logs/verifier/reward.txt
else
  echo "The agent showed something now for something the user wants later."
  echo 0 > /logs/verifier/reward.txt
fi
