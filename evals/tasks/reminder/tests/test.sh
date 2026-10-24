#!/bin/bash
set -euo pipefail
activities=$(curl -fsS --max-time 5 http://lykta:8080/v1/activities \
  -H "Authorization: Bearer lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b")
if python3 -c 'import json, sys; sys.exit(bool(json.load(sys.stdin)["activities"]))' <<< "$activities"; then
  echo "The agent started no activity now."
  echo 1 > /logs/verifier/reward.txt
else
  echo "The agent started an activity now for something the user wants later."
  echo 0 > /logs/verifier/reward.txt
fi
