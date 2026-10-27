#!/bin/bash
set -euo pipefail
for attempt in $(seq 20); do
  if python3 - <<'PYTHON'
import json
import urllib.parse
import urllib.request

base = "http://lykta:8080/v1/"
headers = {"Authorization": "Bearer lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b"}

def read(path):
    with urllib.request.urlopen(urllib.request.Request(base + path, headers=headers), timeout=5) as response:
        return json.load(response)

def leaves(value):
    if isinstance(value, dict):
        return [leaf for item in value.values() for leaf in leaves(item)]
    if isinstance(value, list):
        return [leaf for item in value for leaf in leaves(item)]
    return [value]

actions = read("actions?after=0")["actions"]
for action in actions:
    name = action.get("widget")
    if not name or not action.get("button"):
        continue
    if not any(x.get("widget") == name and x.get("toggle") and x.get("isOn") is True for x in actions):
        continue
    widget = read("widgets/" + urllib.parse.quote(name, safe=""))
    values = leaves(widget["data"])
    if widget["delivery"] == "fetched" and any(type(x) in (int, float) and x == 1 for x in values) and any(x is True for x in values):
        raise SystemExit(0)
raise SystemExit(1)
PYTHON
  then
    echo "The simulated phone added a glass, changed the goal toggle and fetched the widget."
    echo 1 > /logs/verifier/reward.txt
    exit 0
  fi
  sleep 0.5
done
echo "No widget had the button, toggle and fetched result."
echo 0 > /logs/verifier/reward.txt
