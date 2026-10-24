# Notifications

Status: proposed for 0.6.0. Slice 0, a throwaway device test, settles the
assumptions below before slice 1 starts. When a slice lands, its decisions move
into [the architecture record](architecture.md) and this file shrinks to what
remains open.

## Goal

Agents reach the user with a notification for a moment, the way they use a
Live Activity for ongoing status. Each notification comes from a sender with a
name and avatar and can carry its own sound and image, all chosen by the agent
when it sends. Nothing is bundled into the app, so any agent can give its
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
  with the app icon as a badge. Apple describes these for direct communication
  between people, so the communication style is presentation the extension adds
  and can drop; the API and everything else work with plain notifications.
- A custom sound plays only from the app bundle or `Library/Sounds` in the
  app's or an app group's container and lasts under 30 seconds. Only a
  Notification Service Extension can fetch one when a push arrives, within
  about 30 seconds and 24 MB of memory, and only for an alert push with
  `mutable-content`. Live Activity pushes run no extension.

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
→ 201 {"name": …, "state": "queued", "expires": …}
  the same request again → 200 with the current state
  a different request under the name → 409 conflict

GET /v1/notifications/{name}
→ 200 {"state": "received", "expires": …,
       "phone": {"style": "communication", "avatar": true, "sound": "custom"}}
```

- A notification lives one day. Its name identifies one event, follows the
  activity name rules and stays reserved until `expires`; within that time the
  same request returns the existing notification before any quota, permission
  or token check, and a different request under the name is a conflict. After
  a lost response, an agent repeats the same request or reads the name before
  `expires`, never later and never under a new name.
- `sender.id` is the sender's stable identity on this phone, in the activity
  name format; the person handle, conversation and `thread-id` derive from it,
  so a sender keeps one thread when its name or avatar changes and two senders
  that share a name stay apart. `sender.name` is required, at most 64
  characters, and becomes the title; `sender.avatar` is an image. `body` is
  required, at most 500 characters, and the encoded push must fit 4 KB.
  `sound` is left out for silence, `true` for the default sound, or a sound;
  `false` and `null` are refused. `image` is an image shown as the thumbnail.
- Media IDs are opaque handles scoped to the phone whose token uploaded them.
  Sounds are WAV with linear PCM, shorter than 30 seconds; agents convert other
  audio before uploading, and the skill shows how. Images are PNG or JPEG of at
  most 4096 pixels per side. The gateway checks every reference, including its
  type, before queueing.
- States: `queued` (the gateway owns it), `sent` (APNs accepted it),
  `received` (the extension processed it), `failed` with a reason, and
  `unknown` (the APNs outcome is uncertain). A report from the extension wins
  over any APNs outcome that completes after it. `phone` says what the
  extension handed to iOS: the style, whether it supplied an avatar, and which
  sound it chose. Whether iOS then showed or played it, given Focus, summaries
  and the ringer, is beyond what the phone can observe.
- Errors keep Lykta's `{"error", "message"}` shape and name the value and the
  fix, such as `audio is 31.2 s long; use a clip shorter than 30 s`. New codes:
  `notifications_not_allowed` (the user turned notifications off for Lykta),
  `notifications_not_set_up` (the phone has not asked for permission or has no
  notification token yet; the user opens Lykta), `unsupported_media` (415),
  `payload_too_large` (413) and `too_many_notifications` (429 with
  `Retry-After`, at most 60 an hour per phone). A phone whose app predates
  0.6.0 answers `app_update_required`.

## Boundaries and ownership

- `Store` owns notifications, media and fetch tokens. Queueing a notification
  is one transaction with its event. A notification and its token are removed
  when it expires. A medium is removed a day after its last upload or
  reference, never while a kept notification references it, within 32 MiB per
  phone; an upload over the limit fails with `payload_too_large` and names it.
  Media lives in SQLite as blobs, so backups, restores and rollbacks stay as
  they are.
- `Delivery` runs notifications through its existing loop and `APNs`, as a job
  kind of their own that never touches `Activity`. Claiming a notification is
  one transaction that creates its fetch token, stores the hash and hands the
  plaintext only to that job. A claim interrupted by a restart becomes
  `unknown`, as does any uncertain APNs outcome; APNs refusals that guarantee
  no delivery, 429 and 5xx, are claimed again with backoff until `expires`.
  `BadDeviceToken` and `Unregistered` clear the token. Notifications never
  coalesce, unlike activity updates.
- The push is an alert, priority 10, with `apns-expiration` at the
  notification's `expires`. It carries `aps.alert` with the sender's name and
  the body, `sound: "default"` when any sound was asked for,
  `mutable-content: 1`, `thread-id` from `sender.id`, and a `lykta` object with
  the notification's UUID, the sender ID, the media IDs and the fetch token.
  Without the extension it still reads correctly.
- The fetch token authorizes only `GET /v1/device/notifications/{uuid}/media/{id}`
  for that notification's own media and `POST /v1/device/notifications/{uuid}/report`,
  until `expires`. It never authorizes anything else of the phone's, and the
  extension never follows a redirect off its gateway. Reports are idempotent:
  the first wins and later ones change nothing.
- A media validator in `Gateway` takes bytes and returns the medium's type and
  duration or the reason it is refused. It reads WAV headers and PNG and JPEG
  dimensions, with no new package.
- The listener keeps its 1 MiB limit for JSON and allows 4 MiB on
  `POST /v1/media`. `HTTPResponse` gains `Location` and `Retry-After`, and an
  oversized body answers in the JSON error shape.
- `Core` adds the notification and media request types, the `lykta` payload
  object the extension decodes, and two optional device report fields: the
  notification token and the notification authorization status.
- The app asks for notification permission when the user taps Copy Agent
  Setup, registers for remote notifications and reports the token and status
  in its existing report. It never schedules local notifications; the gateway
  stays the only content writer.
- A new `LyktaNotifications` extension is the only code on the phone besides
  the app that uses the network, and it uses only its own gateway and the
  fetch token, never the device secret. It downloads into a temporary file and
  moves it into place, keeps sounds in the app group's `Library/Sounds` and
  avatars in its cache, and keeps all of them within 64 files and 64 MiB by
  removing the oldest files that no notification is using. It decodes avatars
  to a small size with ImageIO, sets the sound and image attachment, applies
  the sender with an app-specific handle and no contact suggestion, donates
  the incoming interaction and passes the result of `updating(from:)` on
  unchanged. It sends its report before handing over the content, with a
  timeout inside its budget, so a lost report never delays the notification.
  It degrades in steps: initials without an avatar, a plain notification with
  the custom sound when the intent fails, and the original alert when time
  runs out.
- The gateway derives a notification's state from its row and events, as it
  does for activities; the extension's report becomes an event.
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
- **WAV, AIFF and CAF in every codec iOS plays.** Three parsers to keep
  correct on Linux for no gain in what agents can say; one format is a single
  conversion step for them.
- **Sharing the device secret with the extension through a Keychain access
  group.** Gives the extension the phone's full credential and needs a
  Keychain migration; a fetch token is narrower.
- **Media on the filesystem or an object store.** Changes self-hosting, backups
  and rollbacks; capped SQLite blobs keep them as they are.
- **Critical Alerts, AlarmKit, Push to Talk, VoIP.** Need an entitlement
  Apple grants rarely, cannot be triggered by a push, or are limited by App
  Review to other purposes.
- **Plain notifications only.** Keep the sound, image and thread but lose the
  avatar and the communication style's system treatment, such as breaking
  through summaries; they remain the fallback if App Review objects.

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

- The `/v1/notifications` and `/v1/media` contracts, states, lifetimes and
  error codes.
- The `lykta` payload object and the extension's routes, which installed
  extensions use.
- The notification fields in the device report.
- `sender.id` and what derives from it: Notification Center threads, Focus's
  allowed people and Siri's suggestions key on the handle and conversation.

## Slices

0. Throwaway device test of the assumptions above.
1. Text notifications end to end: the device report fields, `PUT` and `GET`
   `/v1/notifications`, delivery with claim-time fetch tokens, the extension's
   communication notification with initials and the default sound, its report
   route, `SimulatedPhone`, the setup paste, the skill's notification
   reference, `PRIVACY.md` and one eval.
2. Media: `/v1/media` and the listener's larger limit, validation, storage and
   cleanup, the media route, the extension's avatar, sound, image and cache,
   the examples, the gallery section, `PRIVACY.md` and the voice eval.
3. Product: README, screenshots and the App Store privacy label. Then 0.6.0.

Not in 0.6.0: a link to open on tap, reply buttons, Time Sensitive, breaking
through Focus, SVG avatars, scheduled delivery and a spoken hello.
