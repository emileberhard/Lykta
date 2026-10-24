# Notifications

A notification tells the user about one moment, such as a print that finished
or a deploy that failed. It arrives like a message from a person: the sender's
name as the title, a round avatar with the sender's initials, and the body.
Notifications from one sender gather in one thread.

## Send

`PUT /v1/notifications/{name}` sends a notification right away. The name
identifies the event, such as `printer-job-42-done`: 1 to 64 characters from
`a-z`, `0-9`, `-`, `_` and `.`.

```bash
curl -sS -X PUT "$LYKTA_URL/v1/notifications/printer-job-42-done" \
  -H "Authorization: Bearer $LYKTA_TOKEN" -H "Content-Type: application/json" \
  -d '{"sender": {"id": "printer", "name": "Printer"}, "body": "Benchy finished in 42 min. Come get it!", "sound": true}'
```

| Field | Meaning |
| --- | --- |
| `sender.id` | Who sends it, in the name format. Keep it the same for every notification from this sender: the phone groups them in one thread and colors the avatar by it. |
| `sender.name` | The title, up to 64 characters, such as `Printer` or `Deploy bot`. |
| `body` | Up to 500 characters. Say what happened and what the user can do about it. |
| `sound` | `true` plays the default sound. Leave it out for a silent notification, for news the user can read later. |

The gateway answers `201` with the notification's status. It keeps a
notification and reserves its name for a day, until `expires`. Within that
day the same request returns the existing notification with `200` and sends
nothing again, so after a lost response repeat the exact request; a different
request under the name fails with `conflict`. Never send under a new name to
retry, because the user may already have seen the first.

A PUT sends at once; Lykta cannot send one later by itself. To tell the user
something at a later time, have a scheduler that outlives your session send
the PUT then, as the main skill describes for activities.

## Status

`GET /v1/notifications/{name}` returns:

| Field | Values |
| --- | --- |
| `state` | `queued`, `sent` (Apple accepted it), `received` (the phone prepared it), `failed`, `unknown` |
| `error` | Why it failed or is unknown, or `null` |
| `phone` | What the phone prepared, such as `{"style": "communication", "avatar": "initials", "sound": "default"}`, or `null` before it reports. `"style": "plain"` means it showed the title and body without the avatar |
| `banners` | The phone's banner style: `temporary`, `persistent` or `off`, or `null` before the phone reports it |
| `createdAt`, `expires` | When the gateway accepted it and when it forgets it |

`received` means the phone had the notification ready to show. Focus,
notification summaries and the ringer switch decide whether it lit up the
screen or made a sound, and the phone cannot tell. `unknown` means the gateway
lost track of whether Apple took it; it never sends it again, and neither
should you.

## Errors

- `notifications_not_set_up`: the user has not allowed notifications yet. Ask
  them to open Lykta and tap Allow.
- `notifications_not_allowed`: the user turned notifications off for Lykta.
  Ask them to turn them on in Lykta or in Settings.
- `app_update_required`: the user's Lykta app predates notifications. Ask them
  to update Lykta and open it once.
- `too_many_notifications`: a phone takes at most 60 notifications an hour.
  The `Retry-After` header says how many seconds to wait.
- `conflict`: another notification used the name in the past day.
- `invalid_request`: the message names the field to fix.

## Debug

`GET /v1/events`, described in the main skill, also records notifications:
`notification.put` when the gateway accepted one, `push.notification` with
Apple's outcome, `notification.received` when the phone prepared it, and
`notification.unknown` or `notification.expired`. The phone's `device.sync`
event shows its notification `authorization`, `alertStyle` and whether it has
a notification `token`.
