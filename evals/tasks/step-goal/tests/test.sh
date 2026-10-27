#!/bin/bash
set -euo pipefail
for attempt in $(seq 10); do
  widgets=$(curl -fsS --max-time 5 http://lykta:8080/v1/widgets \
    -H "Authorization: Bearer lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b")
  if python3 -c 'import json, sys; sys.exit(not any(w["delivery"] == "fetched" for w in json.load(sys.stdin)["widgets"]))' <<< "$widgets"; then
    echo "The phone loaded a widget the agent sent."
    echo 1 > /logs/verifier/reward.txt
    exit 0
  fi
  sleep 0.5
done
echo "No widget the agent sent reached the phone."
echo 0 > /logs/verifier/reward.txt
