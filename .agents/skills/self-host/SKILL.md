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

Build the image from a release tag at the repository root and run it with the
keys mounted read-only. The container runs as the unprivileged user `lykta`;
let that user read the key files through their group or an ACL, or through a
runtime that maps file access to it, such as OrbStack, and keep them closed to
everyone else.

```bash
version=$(git tag --list '[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -1)
git checkout "$version"
docker build --build-arg LYKTA_VERSION="$version" --tag lykta-gateway .
docker run --detach --name lykta --restart unless-stopped --stop-timeout 30 \
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

A phone registers only with an App Attest attestation from the app built for
this gateway's Team ID and bundle ID, so scripts cannot use up the device
limit. Simulators cannot attest: create a one-time invite, valid for an hour,
with `docker exec lykta lykta-gateway invite`, and launch the app with
`SIMCTL_CHILD_LYKTA_INVITE=<invite> xcrun simctl launch <simulator> <bundle ID>`.

## HTTPS

The app connects over HTTPS only. Terminate TLS in front of port 8080, for
example with `tailscale serve --bg 8080` for phones on the same tailnet, or a
Caddy site containing `reverse_proxy 127.0.0.1:8080`.

## App

Create the ignored `iOS/Config/Local.xcconfig`, open `iOS/Lykta.xcodeproj` and
run the `Lykta` scheme on the user's iPhone:

```
DEVELOPMENT_TEAM = <Team ID>
LYKTA_BUNDLE_ID = com.example.lykta
LYKTA_GATEWAY_HOST = lykta.example.com
```

Debug builds register as development and Release builds as production, so the
gateway needs the matching key.

## Verify

1. `curl -fsS https://<host>/skill/SKILL.md` returns the agent skill.
2. In the app, open an example and tap Show on Lock Screen; it appears on the
   Lock Screen and in the Dynamic Island.
3. With the agent token from Copy Agent Setup, `GET /v1/activities/example`
   reports `"delivery": "accepted"`. Gateway logs go to stderr
   (`docker logs lykta`).

## Upgrade

Update the gateway before the app: a newer gateway refuses layouts an older
app cannot draw, while a newer app on an older gateway cannot use its new
features. Build the new tag and replace the container; all state is in the
volume, and `GET /v1/version` reports the running release. On stop, the
gateway finishes pushes in flight before it exits. Releases only add columns,
so the previous image runs on the newer database if you roll back.
