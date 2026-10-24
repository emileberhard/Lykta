# Notifications

Status: proposed for 0.6.0. Slice 0, a throwaway device test, settles the
assumptions below before slice 1 starts. When a slice lands, its decisions move
into [the architecture record](architecture.md) and this file shrinks to what
remains open.

## Goal

Agents reach the user with a notification for a moment, the way they use a
Live Activity for ongoing status. Each notification comes from a named sender
with its own avatar and, optionally, its own sound and image, all chosen by the
agent when it sends. Nothing is bundled into the app, so any agent can give its
notifications any face and voice. The agent picks the form from what the user
asked for: a Live Activity for "keep me posted", a notification for "tell me
when", an activity alert for attention on an activity that already exists.

## Constraints

- The architecture's constraints hold: one person can self-host, APNs is the
  only external service, packages come only from Apple, and SQLite holds all
  durable state.
- Unknown stays unknown. A notification whose delivery outcome is uncertain is
  never sent again.
- A notification always shows the app's icon. A communication notification, an
  `INSendMessageIntent` applied with `UNNotificationContent.updating(from:)` in
  a Notification Service Extension, shows the sender's avatar and name instead,
  with the app icon as a badge; Apple formats its title as the sender's name.
- A custom sound plays only from the app bundle or `Library/Sounds` in the
  app's or an app group's container, lasts under 30 seconds, and is linear PCM,
  IMA4, µ-law or a-law in WAV, AIFF or CAF. Only a Notification Service
  Extension can fetch one when a push arrives, within about 30 seconds and
  24 MB of memory, and only for an alert push with `mutable-content`. Live
  Activity pushes run no extension.

## Contract

```text
POST /v1/media                       raw body, Content-Type audio/wav,
                                     audio/aiff, audio/x-caf, image/png or
                                     image/jpeg, at most 4 MiB
→ 201 Location: /v1/media/{id}       200 when the same file already exists
  {"id": "m_…", "type": "sound", "durationSeconds": 4.2}

PUT /v1/notifications/{name}
  {"sender": {"name": "Printer", "avatar": "m_…"},
   "body": "Benchy finished in 42 min. Come get it!",
   "sound": "m_…",
   "image": "m_…"}
→ 201 {"name": …, "state": "queued"}
  replay of the same request → 200 with the current state
  a different request under the name → 409 conflict

GET /v1/notifications/{name}
→ 200 {"state": "received", "reason": …, "phone": {"style": "communication",
       "avatar": true, "sound": "custom"}}
```

- A notification is immutable. Its name follows the activity name rules and
  identifies one event, such as `printer-job-42-done`, so a repeated request is
  safe: the gateway compares the whole validated request, ignoring key order,
  and a unique constraint on phone and name makes concurrent repeats create one
  notification. Names stay reserved for the seven days the gateway keeps the
  notification. After a lost response, an agent repeats the same request or
  reads the name; it never picks a new name to retry.
- `sender.name` is required, at most 64 characters, and becomes the title.
  `sender.avatar` is an image. `body` is required, at most 500 characters, and
  the encoded push must fit 4 KB. `sound` is left out for silence, `true` for
  the default sound, or a sound; `false` and `null` are refused. `image` is an
  image shown as the thumbnail.
- Media IDs are opaque handles scoped to the phone whose token uploaded them; a
  phone never sees another phone's media. Sounds must last under 30 seconds in
  a supported codec; images are PNG or JPEG of at most 4096 pixels per side. A
  medium lives seven days after its last use and is never removed while a
  queued or sent notification references it. The gateway checks every
  reference, including its type, before queueing.
- States: `queued` (the gateway owns it), `sent` (APNs accepted it),
  `received` (the extension ran and reported what it showed and played),
  `failed` with a reason, and `unknown` (the APNs outcome is uncertain). A late
  report from the phone can still turn `unknown` into `received`. Nothing on
  the phone can prove the user saw a notification, given Focus and summaries,
  so no state claims it.
- Errors keep Lykta's `{"error", "message"}` shape and name the value and the
  fix, such as `audio is 31.2 s long; use a clip shorter than 30 s`. New codes:
  `notifications_not_allowed` (the user must allow notifications for Lykta),
  `unsupported_media` (415), `payload_too_large` (413) and
  `too_many_notifications` (429 with `Retry-After`, at most 60 an hour per
  phone). A phone that never reported a notification token answers
  `app_update_required` when its app predates 0.6.0.

## Boundaries and ownership

- `Store` owns notifications, media and fetch tokens. One transaction queues a
  notification, stores a random fetch token as a hash and records the event.
  Housekeeping removes notifications after seven days and media as above,
  within 32 MiB per phone; an upload that would exceed it fails with
  `payload_too_large` and names the limit. Media lives in SQLite as blobs, so
  backups, restores and rollbacks stay as they are.
- `Delivery` sends each notification once as an alert push to the phone's
  notification token, priority 10. APNs refusals that guarantee no delivery,
  429 and 5xx, retry with backoff; an uncertain outcome becomes `unknown`;
  `BadDeviceToken` and `Unregistered` clear the token. Notifications never
  coalesce, unlike activity updates.
- The push carries `aps.alert` with the sender's name and the body,
  `sound: "default"` when any sound was asked for, `mutable-content: 1`,
  `thread-id` from the sender, and a `lykta` object with the media IDs and the
  fetch token. Without the extension it still reads correctly.
- A media validator in `Gateway` takes bytes and returns the medium's type and
  duration or the reason it is refused. It reads WAV, AIFF and CAF headers and
  PNG and JPEG dimensions, with no new package.
- `Core` adds the notification and media request types, the `lykta` payload
  object the extension decodes, and two optional device report fields: the
  notification token and the notification authorization status.
- The app asks for notification permission when the user taps Copy Agent
  Setup, registers for remote notifications and reports the token and status
  in its existing report. It never schedules local notifications; the gateway
  stays the only content writer.
- A new `LyktaNotifications` extension is the only code on the phone besides
  the app that uses the network. It fetches media only from its own gateway
  with the notification's fetch token, which covers that notification's media
  for one hour, so it never holds the device secret. It writes sounds to
  `Library/Sounds/<id>` in the app group and keeps avatars in a cache of at most
  32 files and 32 MiB, decodes avatars to a small size with ImageIO, sets the
  sound and the image attachment, applies the sender with an app-specific
  handle and no contact suggestion, donates the incoming interaction and passes
  the result of `updating(from:)` on unchanged. It then reports its outcome
  with the same token. It degrades in steps: initials without an avatar, a
  plain notification with the custom sound when the intent fails, and the
  original alert when time runs out.
- The skill starts by choosing the form and keeps notifications in their own
  reference, so a plain notification needs neither `layout.md` nor the activity
  examples. Notification examples live in `examples/notifications` with their
  media files; the app bundles them and the gateway tests send each one.

## Alternatives considered

- **Custom sounds on Live Activity alerts.** A Live Activity push runs no
  extension, so a new clip cannot reach the phone in time: background pushes
  are throttled and never launch an app the user swiped away.
- **Sounds bundled in the app.** Contradicts the goal that agents define
  everything.
- **Base64 or multipart in the notification request.** Puts binary data in the
  agent's context or in every request, and loses avatar reuse. A separate media
  resource costs one request per new file.
- **Sharing the device secret with the extension through a Keychain access
  group.** Gives the extension the phone's full credential and needs a
  Keychain migration; a fetch token is narrower.
- **Media on the filesystem or an object store.** Changes self-hosting, backups
  and rollbacks; capped SQLite blobs keep them as they are.
- **Critical Alerts, AlarmKit, Push to Talk, VoIP.** Need an entitlement
  Apple grants rarely, cannot be triggered by a push, or are limited by App
  Review to other purposes.
- **Plain notifications only.** Lose the avatar, the sender's thread and the
  summary breakthrough; they remain the fallback if App Review objects.

## Assumptions to check in slice 0

- A custom sound set before `updating(from:)` still plays.
- A communication notification without an avatar shows the sender's initials.
- A 25-second clip plays in full while the phone is unlocked. In April a
  10.4-second clip was cut off unlocked and played in full when locked.
- Which targets need the Communication Notifications capability, and whether
  SiriKit is needed, as Apple's sample enables it.
- Whether Siri announces these notifications on AirPods by default, as WWDC21
  says, or needs the older intent handling the `INSendMessageIntent` reference
  still lists.

App Review's view of communication notifications for agent messages cannot be
tested before submission; plain notifications are the fallback.

## Expensive to change once shipped

- The `/v1/notifications` and `/v1/media` contracts, states and error codes.
- The `lykta` payload object that installed extensions decode.
- The notification fields in the device report.
- The sender handle and conversation identifier: Notification Center threads,
  Focus's allowed people and Siri's suggestions key on them.

## Slices

0. Throwaway device test of the assumptions above.
1. Text notifications end to end: the device report fields, `PUT` and `GET`
   `/v1/notifications`, delivery, the extension's communication notification
   with initials and the default sound, its report, `SimulatedPhone`, the
   skill's notification section and one eval.
2. Media: `/v1/media`, validation, storage and cleanup, fetch tokens, the
   extension's avatar, sound and image, the examples, the gallery section and
   the voice eval.
3. Product: a spoken hello once permission is granted, the setup paste, README,
   screenshots, `PRIVACY.md` and the App Store privacy label. Then 0.6.0.

Not in 0.6.0: a link to open on tap, reply buttons, Time Sensitive, breaking
through Focus, SVG avatars and scheduled delivery.
