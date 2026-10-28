# Notifications

A notification tells the user about one moment, such as a print that finished
or a deploy that failed. It arrives like a message from a person: the sender's
name as the title, a round avatar with the sender's picture, drawing or initials, and
the body, optionally with its own sound and an image. Notifications from one
sender gather in one thread.

## Send

`lykta put notifications/{name}`, the [main skill's](../SKILL.md#the-lykta-command)
command, sends a notification right away. The name identifies the event, such
as `printer-job-42-done`: 1 to 64 characters from `a-z`, `0-9`, `-`, `_` and
`.`.

```sh
lykta put notifications/printer-job-42-done <<'EOF'
{"sender": {"id": "printer", "name": "Printer"}, "body": "Benchy finished in 42 min. Come get it!", "sound": true}
EOF
```

| Field | Meaning |
| --- | --- |
| `sender.id` | Who sends it, in the name format. Keep it the same for every notification from this sender: the phone groups them in one thread and colors the avatar by it. |
| `sender.name` | The title, up to 64 characters, such as `Printer` or `Deploy bot`. |
| `sender.avatar` | Optional image id or node object, including `{"use":"name"}` for a saved part. The phone draws nodes once in a 64 pt viewport. |
| `body` | Up to 500 characters. Say what happened and what the user can do about it. |
| `sound` | `true` plays the default sound, the id of a sound plays that sound. Leave it out for a silent notification, for news the user can read later. |
| `image` | Optional id of an image shown as a thumbnail and in full when the user expands the notification, such as a photo of the finished print. |

`lykta put` waits up to 10 seconds for Apple's answer and prints the
notification's [status](#status), so `state` is `sent`, or says what happened.
The gateway keeps a notification and reserves its name for a day, until
`expires`. Within that
day the same request returns the existing notification and sends nothing
again, so after a lost response repeat the exact request; a different
request under the name fails with `conflict`. Never send under a new name to
retry, because the user may already have seen the first.

A PUT sends at once; Lykta cannot send one later by itself. To tell the user
something at a later time, have a scheduler that outlives your session send
the PUT then, as the main skill describes for activities.

## Media

`lykta media FILE` uploads a sound or image and prints its id, the same id
each time for the same file. Upload and send in one command, with the
heredoc's delimiter unquoted so the shell fills in the ids:

```sh
lykta put notifications/front-door-1842 <<EOF
{"sender": {"id": "front-door", "name": "Front door", "avatar": "$(lykta media door-avatar.jpg)"}, "body": "Someone is at the door.", "sound": "$(lykta media chime.wav)", "image": "$(lykta media snapshot.jpg)"}
EOF
```

When an upload fails, `lykta` prints why, and the PUT fails on the empty id.
An id works only for the phone whose token uploaded it, and the gateway
removes a file a day after its last upload or use, so upload again when a
notification names an id it no longer knows.

- **Sounds** are WAV files with linear PCM audio, shorter than 30 seconds.
  Convert other audio first, such as `ffmpeg -i in.m4a -ac 1 -c:a pcm_s16le out.wav`.
  Keep a sound under eight seconds: while the phone is unlocked, a temporary
  banner stops it when the banner slides away. Longer sounds play in full when
  an earlier notification's status shows `"banners": "persistent"`.
- **Images** are PNG or JPEG files of at most 4096 pixels on each side. A
  square image of 256 pixels or more makes a sharp avatar; the phone crops it
  to a circle.
- Each file is at most 4 MiB, and the gateway keeps at most 32 MiB per phone.

Make a sound or picture fit the sender: a short chime for a finished job, a
spoken sentence for something urgent, the printer's own camera snapshot as the
image. The examples in [`examples/notifications`](../examples/notifications)
show each field: [`print-finished.json`](../examples/notifications/print-finished.json)
and [`doorbell.json`](../examples/notifications/doorbell.json) name their
media files next to them where the ids go, so upload each and put its id there;
[`tests-passed.json`](../examples/notifications/tests-passed.json) uses no media.

## Status

`lykta get notifications/{name}` returns:

| Field | Values |
| --- | --- |
| `state` | `queued`, `sent` (Apple accepted it), `received` (the phone prepared it), `failed`, `unknown` |
| `error` | Why it failed or is unknown, or `null` |
| `phone` | What the phone prepared, such as `{"style": "communication", "avatar": "image", "sound": "custom"}`, or `null` before it reports. `"avatar": "image"` covers a photo or drawn avatar. `"avatar": "initials"` means no avatar was supplied or fetching or drawing failed; `"sound": "default"` for a requested sound means it played the default sound instead. `"style": "plain"` means it showed the title and body without the avatar |
| `banners` | The phone's banner style: `temporary`, `persistent` or `off`, or `null` before the phone reports it |
| `createdAt`, `expires` | When the gateway accepted it and when it forgets it |

`received` means the phone had the notification ready to show. Focus,
notification summaries and the ringer switch decide whether it lit up the
screen or made a sound, and the phone cannot tell. `unknown` means the gateway
lost track of whether Apple took it; it never sends it again, and neither
should you.

## Errors

- `notifications_not_set_up`: the user has not allowed notifications yet, or
  the phone has no notification token. The message says which and, when iOS
  refused the token, quotes its reason. Pass it on to the user.
- `notifications_not_allowed`: the user turned notifications off for Lykta.
  Ask them to turn them on in Lykta or in Settings.
- `app_update_required`: the phone cannot draw a requested feature or predates
  notifications. Ask the user to update Lykta and open it once.
- `too_many_notifications`: a phone takes at most 60 notifications an hour.
  The `Retry-After` header says how many seconds to wait.
- `conflict`: another notification used the name in the past day.
- `invalid_request`: the message names the field to fix, including a media id
  this phone does not have or of the wrong type.
- `invalid_layout`: the message names an avatar node, template construct or saved
  part to fix, with its JSON path.
- `unsupported_media`: the file is not a WAV, PNG or JPEG the phone can use;
  the message says how to convert it.
- `payload_too_large`: the file is over 4 MiB, the phone's media would exceed
  32 MiB, or the push would exceed Apple's size limit. For an oversized drawing,
  the message names `sender.avatar` and its compressed bytes; simplify it.

## Debug

`lykta get events`, described in the main skill, also records notifications:
`media.put` for each new file, `notification.put` when the gateway accepted
one, `push.notification` with Apple's outcome, `notification.media` for each
file the phone fetched, `notification.received` when the phone prepared it,
and `notification.unknown` or `notification.expired`. The phone's `device.sync`
event shows its notification `authorization`, `alertStyle` and whether it has
a notification `token`. `notification.put` records `avatarFingerprint` for a
drawing, never its node. On initials fallback, `notification.received` can record
`avatarFailure`: `frame`, `inflate`, `decode`, `deadline` or `render`. Report
bodies and notification status keep the same `image` or `initials` avatar values.

## Drawn avatars

`sender.avatar` takes an uploaded image id string or a node object, such as
`{"symbol":"hammer.fill"}` or `{"use":"clawd"}`. A string always means a
media id; write text as `{"text":"ET"}`. With Lykta 0.17.0 or later, the phone
draws the node once on arrival in a fixed 64 × 64 pt viewport at scale 4;
iOS crops it into a circle. Compose the art, then `padding`, then `background`.
Use initials or a symbol rather than words that become unreadable at this size.

An avatar has no data: placeholders and `each` are refused. Controls, links,
timers, interval progress, relative dates and environment conditions are also
refused because the result is drawn once. Fixed numeric progress, absolute
dates and ordinary SVG remain available. If drawing fails, independent initials
still identify the sender.

Speak as yourself. Check `lykta get parts` for a saved part that represents you
and use it explicitly as your avatar when one exists. The gateway snapshots
that part in the notification. If a retry gets `conflict` after a part changed,
or an unknown-part error after it was deleted, read the existing notification
with `lykta get notifications/NAME`; never resend it under a new name.

`examples/notifications/agent-update.json` shows a neutral build bot drawn in
SVG with padding and a background.
