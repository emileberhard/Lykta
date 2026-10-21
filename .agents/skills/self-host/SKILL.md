---
name: self-host
description: Set up a Lykta gateway and app build for someone, covering Apple Developer configuration, APNs keys, running the gateway behind HTTPS and building the app against it. Use when asked to self-host, deploy, configure or upgrade Lykta.
---

# Self-host Lykta

One gateway serves one app bundle ID. It needs an Apple Developer account, an
HTTPS address the phone can reach, and persistent storage for its SQLite
database. Ask the user before creating Apple keys, App IDs or public hosts.

## Apple Developer

1. Pick a bundle ID the user owns, such as `com.example.lykta`; the widget
   extension uses `<bundle ID>.widgets`. Xcode's automatic signing registers
   both App IDs and enables Push Notifications.
2. In Certificates, IDs & Profiles > Identifiers, open the app's App ID and
   enable Broadcast Capability under Push Notifications.
3. Under Keys, create an Apple Push Notifications service key per environment
   the user needs: Sandbox for builds run from Xcode, Production for TestFlight
   and App Store builds. Record each Key ID; the `.p8` file downloads once.
4. Note the Team ID from the account's membership details.

## Gateway

Build the image from the repository root and run it with the keys mounted
read-only. The container runs as an unprivileged user, so the key files must
be readable by others.

```bash
docker build --tag lykta-gateway .
docker run --detach --name lykta --restart unless-stopped \
  --publish 127.0.0.1:8080:8080 --volume lykta-data:/data --volume "$KEY_DIR:/keys:ro" \
  --env LYKTA_BUNDLE_ID=com.example.lykta --env LYKTA_TEAM_ID="$TEAM_ID" \
  --env LYKTA_DEVELOPMENT_KEY_ID="$KEY_ID" --env LYKTA_DEVELOPMENT_KEY_FILE="/keys/AuthKey_$KEY_ID.p8" \
  lykta-gateway
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `LYKTA_DEVELOPMENT_KEY_ID`, `_FILE` | | Sandbox key; required for Debug builds |
| `LYKTA_PRODUCTION_KEY_ID`, `_FILE` | | Production key; required for TestFlight and App Store builds |
| `LYKTA_MAX_DEVICES` | 100 | Registration closes at this many phones |
| `LYKTA_MAX_LIVE_ACTIVITIES` | 5 | Live activities per phone |
| `LYKTA_HOST`, `LYKTA_PORT` | 127.0.0.1, 8080 | Listener; the image listens on all interfaces |
| `LYKTA_DATABASE` | `lykta.sqlite` | SQLite path; `/data/lykta.sqlite` in the image |

At least one key pair is required. A legacy key valid in both environments
can be set as both pairs.

Registration needs no credential, so anyone who reaches the gateway can use up
the device limit. Keep the gateway on a private network such as a tailnet, or
set `LYKTA_MAX_DEVICES` to the number of phones the user has.

## HTTPS

The app connects over HTTPS only. Terminate TLS in front of port 8080, for
example with `tailscale serve --bg 8080` for phones on the same tailnet, or a
Caddy site containing `reverse_proxy 127.0.0.1:8080`.

## App

Create the ignored `Config/Local.xcconfig`, open `Lykta.xcodeproj` and run the
`Lykta` scheme on the user's iPhone:

```
DEVELOPMENT_TEAM = <Team ID>
LYKTA_BUNDLE_ID = com.example.lykta
LYKTA_GATEWAY_HOST = lykta.example.com
```

Debug builds register as development and Release builds as production, so the
gateway needs the matching key.

## Verify

1. `curl -fsS https://<host>/skill/SKILL.md` returns the agent skill.
2. In the app, Send Demo shows the demo on the Lock Screen and in the Dynamic
   Island.
3. With the agent token from Copy Setup, `GET /v1/activities/demo` reports
   `"delivery": "accepted"`. Gateway logs go to stderr (`docker logs lykta`).

## Upgrade

Rebuild the image and replace the container; all state is in the volume. A
restart while an activity is starting marks it `unknown` instead of sending it
twice.
