# Lykta

Lykta lets AI agents put native Live Activities on your iPhone. An agent sends
a JSON layout to your Lykta gateway, and the phone shows it on the Lock Screen
and in the Dynamic Island, rendered with SwiftUI and kept current as the agent
sends updates. Any layout works without an app update.

```bash
curl -X PUT "$LYKTA_URL/v1/activities/build" \
  -H "Authorization: Bearer $LYKTA_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "title": "Build",
    "layout": {
      "lockScreen": {"hstack": ["Build", {"spacer": true}, {"progress": "{{done}}", "style": "circular"}],
                     "modifiers": [{"padding": 16}]},
      "compactLeading": {"symbol": "hammer.fill"},
      "compactTrailing": "{{percent}}%",
      "minimal": {"progress": "{{done}}", "style": "circular"}
    },
    "data": {"done": 0.4, "percent": 40}
  }'
```

## How it works

The app registers with your gateway and shares its push-to-start token. When
an agent starts an activity, the gateway validates the layout with the same
Swift code the widget renders it with, then starts it through APNs and updates
it over a broadcast channel. Timers and progress run on the phone, so agents
only send changes.

## Use it from an agent

In the app, Copy Setup copies the gateway address, an agent token and a link
to the agent skill the gateway serves at `/skill/SKILL.md`. The skill covers
the API, and its [layout reference](Gateway/Sources/LyktaGateway/Skill/references/layout.md)
covers every node and modifier.

## Self-host

You need an Apple Developer account, a machine that runs Docker, and an HTTPS
address your phone can reach. The [self-host guide](.agents/skills/self-host/SKILL.md)
walks through the APNs keys, the gateway container and the app build, and works
as a skill for coding agents.

## Development

```bash
just test   # core and gateway tests
just ios    # compile the app and widgets
```

`Core` holds the layout language, `Rendering` draws it for the widget and the
app, `App` registers the phone, and `Gateway` serves the API and delivers
pushes. See
[AGENTS.md](AGENTS.md) for ownership and invariants and the
[architecture record](docs/architecture.md) for the design decisions.

## License and security

[PolyForm Shield 1.0.0](LICENSE): read, run, change, self-host and share
Lykta for any purpose except providing a product that competes with it. The
license covers the code, not the Lykta name or icon: a fork you distribute needs
its own. [PRIVACY.md](PRIVACY.md) describes what the gateway stores.

Report vulnerabilities privately through
[GitHub security advisories](../../security/advisories/new), not in a public issue.
