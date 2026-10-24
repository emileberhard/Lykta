# Notifications

Status: slice 1, text notifications, has landed and its decisions are in
[the architecture record](architecture.md). This file holds what remains for
0.6.0: media in slice 2 and the product work in slice 3. When a slice lands,
its decisions move into the architecture record and this file shrinks to what
remains open.

## Goal

Each notification can carry its sender's avatar, its own sound and an image,
all chosen by the agent when it sends. Nothing is bundled into the app, so any
agent can give its notifications any face and voice.

## Constraints

- A custom sound plays only from the app bundle or `Library/Sounds` in the
  app's or an app group's container and lasts under 30 seconds. Only a
  Notification Service Extension can fetch one when a push arrives, within
  about 30 seconds and 24 MB of memory, and only for an alert push with
  `mutable-content`. Live Activity pushes run no extension.
- While the phone is unlocked, a sound stops when a Temporary banner slides
  away, after about nine seconds; with Persistent banners and on a locked
  phone it plays in full. Only the user can change the style.

## Contract

```text
POST /v1/media                       raw body, audio/wav, image/png or
                                     image/jpeg, at most 4 MiB
→ 201 Location: /v1/media/{id}       200 when the same file already exists
  {"id": "m_…", "type": "sound", "durationSeconds": 4.2}

PUT /v1/notifications/{name}
  {"sender": {"id": "printer", "name": "Printer", "avatar": "m_…"},
   "body": "Benchy finished in 42 min. Come get it!",
   "sound": "m_…",
   "image": "m_…"}
```

- `sender.avatar` is an image; `sound` may also be a sound, besides `true` for
  the default; `image` is an image shown as the thumbnail and in full when
  expanded.
- Media IDs are opaque handles scoped to the phone whose token uploaded them.
  Sounds are WAV with linear PCM, shorter than 30 seconds; agents convert other
  audio before uploading, and the skill shows how. Images are PNG or JPEG of at
  most 4096 pixels per side. The gateway checks every reference, including its
  type, before queueing.
- `phone` reports `"avatar": "image"` when the extension used the sender's
  avatar and `"sound": "custom"` when it set the agent's sound.
- New errors: `unsupported_media` (415) and `payload_too_large` (413), each
  naming the value and the fix, such as
  `audio is 31.2 s long; use a clip shorter than 30 s`.

## Boundaries and ownership

- `Store` owns media. A medium is removed a day after its last upload or
  reference, never while a kept notification references it, within 32 MiB per
  phone; an upload over the limit fails with `payload_too_large` and names it.
  Media lives in SQLite as blobs, so backups, restores and rollbacks stay as
  they are.
- The push's `lykta` object gains the media IDs. The fetch token also
  authorizes `GET /v1/device/notifications/{uuid}/media/{id}` for that
  notification's own media.
- A media validator in `Gateway` takes bytes and returns the medium's type and
  duration or the reason it is refused. It reads WAV headers and PNG and JPEG
  dimensions, with no new package.
- The listener keeps its 1 MiB limit for JSON and allows 4 MiB on
  `POST /v1/media`. `HTTPResponse` gains `Location`, and an oversized body
  answers in the JSON error shape.
- The extension downloads into a temporary file and moves it into place,
  keeps sounds in the app group's `Library/Sounds` and avatars in its cache,
  and keeps all of them within 64 files and 64 MiB by removing the oldest
  files that no notification is using. It decodes avatars to a small size with
  ImageIO and sets the sound and image attachment before `updating(from:)`.
  Without the intent it still delivers the custom sound and image.
- The skill keeps clips under eight seconds unless the phone reports
  persistent banners. Notification examples live in `examples/notifications`
  with their media files; the app bundles them, its gallery sends them, and
  the gateway tests send each one.

## Alternatives considered

- **Custom sounds on Live Activity alerts.** A Live Activity push runs no
  extension, so a new clip cannot reach the phone in time: background pushes
  are throttled and never launch an app the user swiped away.
- **Sounds bundled in the app.** Contradicts the goal that agents define
  everything.
- **Base64 or multipart in the notification request.** Puts binary data in the
  agent's context or in every request, and loses avatar reuse. A separate media
  resource costs one request per new file.
- **WAV, AIFF and CAF in every codec iOS plays.** Three parsers to keep
  correct on Linux for no gain in what agents can say; one format is a single
  conversion step for them.
- **Media on the filesystem or an object store.** Changes self-hosting, backups
  and rollbacks; capped SQLite blobs keep them as they are.
- **Critical Alerts, AlarmKit, Push to Talk, VoIP.** Need an entitlement
  Apple grants rarely, cannot be triggered by a push, or are limited by App
  Review to other purposes.

## Still open

Whether Siri announces these notifications on AirPods by default, as WWDC21
says, or needs the older intent handling the `INSendMessageIntent` reference
still lists. App Review's view of communication notifications for agent
messages cannot be tested before submission; plain notifications, which keep
the sound, image and thread, are the fallback.

## Expensive to change once shipped

- The `/v1/media` contract and the media fields of `/v1/notifications`.
- The media IDs in the `lykta` payload object and the media route, which
  installed extensions use.

## Slices

2. Media: `/v1/media` and the listener's larger limit, validation, storage and
   cleanup, the media route, the extension's avatar, sound, image and cache,
   the app group, the examples, the gallery section, `PRIVACY.md` and the
   voice eval.
3. Product: README, screenshots and the App Store privacy label. Then 0.6.0.

Not in 0.6.0: a link to open on tap, reply buttons, Time Sensitive, breaking
through Focus, SVG avatars, scheduled delivery and a spoken hello.
