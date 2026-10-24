# Lykta

[![Join the TestFlight beta](https://img.shields.io/badge/TestFlight-Join_the_beta-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/kDAjDvfD)

Lykta lets AI agents put native Live Activities on your iPhone and send you
notifications. An agent sends a JSON layout to your Lykta gateway, and the
phone shows it on the Lock Screen and in the Dynamic Island, rendered with
SwiftUI and kept current as the agent sends updates. Any layout works without
an app update, including buttons, toggles and links that report back to the
agent. For a single moment, such as a finished job, the agent sends a
notification that arrives like a message from a person, with the sender's
name and picture, a sound of the agent's choosing and an image.

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

The app registers with your gateway, proving with App Attest that it is a
genuine copy, and shares its push-to-start token. When an agent starts an
activity, the gateway validates the layout with the same Swift code the widget
renders it with, then starts it through APNs and updates it over a broadcast
channel. Timers and progress run on the phone, so agents only send changes.
Notifications go out as alert pushes, and the app's notification extension
fetches the sender's picture, the sound and the image the agent uploaded, and
tells the gateway what it showed.

## Use it from an agent

In the app, Copy Agent Setup copies the gateway address, an agent token and a link
to the agent skill the gateway serves at `/skill/SKILL.md`. The skill covers
the API, and its [layout reference](Gateway/Sources/LyktaGateway/Skill/references/layout.md)
covers every node and modifier. The [example activities](Gateway/Sources/LyktaGateway/Skill/examples)
show what an agent can build, from an App Review tracker to a shared shopping
list. The app shows each one on the Lock Screen and in the Dynamic Island, and
sends any of them to your phone to try live.

## Self-host

You need an Apple Developer account, a machine that runs Docker, and an HTTPS
address your phone can reach. The [self-host guide](.agents/skills/self-host/SKILL.md)
walks through the APNs keys, the gateway container and the app build, and works
as a skill for coding agents.

## Development

```bash
just test   # core and gateway tests
just ios    # compile the app and its extensions
just evals  # fresh agents against a simulated phone
```

`Core` holds the layout language, `Gateway` serves the API and delivers
pushes, and `iOS` holds the app, its widgets, its notification extension and
the `Rendering` the app and widgets share.
See [AGENTS.md](AGENTS.md) for ownership and invariants and the
[architecture record](docs/architecture.md) for the design decisions.

## License and security

[PolyForm Shield 1.0.0](LICENSE): read, run, change, self-host and share
Lykta for any purpose except providing a product that competes with it. The
license covers the code, not the Lykta name or icon: a fork you distribute needs
its own. [PRIVACY.md](PRIVACY.md) describes what the gateway stores.

Report vulnerabilities privately through
[GitHub security advisories](../../security/advisories/new), not in a public issue.
