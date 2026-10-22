---
name: lykta
description: Show live status on the user's iPhone Lock Screen and Dynamic Island as a Live Activity through their Lykta gateway. Use for countdowns, progress, builds, deliveries or any ongoing task the user wants to glance at; not for one-off notifications.
---

# Lykta

Lykta shows a Live Activity on the user's iPhone. You send a JSON layout to the
user's gateway; the gateway validates it and pushes it to the phone, where it
renders natively. The Lykta app does not need to be open.

You need the gateway URL and agent token from the setup the user copied out of
the Lykta app. Send the token as `Authorization: Bearer <token>`.

## Start or update

`PUT /v1/activities/{name}` with a JSON body starts the activity when no live
activity has that name, and updates it otherwise. A name is 1 to 64 characters
from `a-z`, `0-9`, `-`, `_` and `.`.

| Field | Meaning |
| --- | --- |
| `title` | Required to start; up to 120 characters. Used for alerts and when the phone cannot render the layout. |
| `layout` | Required to start. See [the layout reference](references/layout.md). |
| `data` | Values for `{{path}}` placeholders in the layout. Replaces the previous data. |
| `alert` | `{"title", "body", "sound": true}` lights up the screen and expands the Dynamic Island. Only `body` is required; up to 200 characters. Use it for moments that need attention. |
| `staleAfter` | Seconds until the phone marks the activity as out of date. Each PUT renews it. |
| `endAfter` | Seconds, up to 28800, until the gateway ends the activity and removes it from the Lock Screen. A PUT that includes it moves the deadline; one without it keeps the deadline. Set it whenever you know when the activity is over, because you may not be running then. |
| `relevance` | 0 to 100. The most relevant activity takes the Dynamic Island. |

iOS budgets how many activities an app may start by push. Once the budget is
spent it silently drops new starts for a while, so keep one name per purpose and
update it; never end and restart an activity to refresh it.

Updates normally send only `data`; the title and layout keep their last values.
Timers and timer-driven progress run on the phone, so send them once instead of
updating every second. The phone shows at most one update per second per
activity; faster PUTs collapse into the latest state.

```bash
curl -sS -X PUT "$LYKTA_URL/v1/activities/deploy" \
  -H "Authorization: Bearer $LYKTA_TOKEN" -H "Content-Type: application/json" \
  -d @deploy.json

curl -sS -X PUT "$LYKTA_URL/v1/activities/deploy" \
  -H "Authorization: Bearer $LYKTA_TOKEN" -H "Content-Type: application/json" \
  -d '{"data": {"service": "api", "step": "Done", "done": 5, "total": 5, "progress": 1, "started": 1793000000}}'
```

## End

`DELETE /v1/activities/{name}` ends the activity with its last content. The
system keeps it on the Lock Screen for up to four hours; `?dismissAfter=seconds`
(0 to 14400) removes it sooner. An activity without `endAfter` that nobody
ends stays until iOS ends it after eight hours.

## Status

`GET /v1/activities/{name}` returns the newest activity with that name, and
`GET /v1/activities` lists recent ones:

| Field | Values |
| --- | --- |
| `state` | `starting`, `live`, `ending`, `ended` |
| `delivery` | `pending`, `accepted` (Apple accepted the push), `throttled`, `unknown`, `failed` |
| `device` | What the phone last reported: `pending`, `active`, `stale`, `ended`, `dismissed`, `unknown`, or `null` before its first report |
| `error` | Why delivery failed or the activity ended, or `null` |

Accepted means Apple took the push, not that the phone displayed it.

## Debug

When an activity does not appear or update, read `GET /v1/events` before
retrying. It returns this phone's newest events, oldest first, from both sides:

- The gateway: `activity.put`, `push.start`, `push.update` and `push.end` with
  Apple's outcome, `pushID` and `ms`, `device.sync`, `request.failed`.
- The phone: `activity.observed`, `activity.content`, `activity.state`,
  `app.error`, `app.authorization`, `metrickit.diagnostic`.

A `fingerprint` that matches between `push.*` and `activity.content` proves the
phone received that exact content. An accepted `push.start` followed by
`activity.unseen` means iOS dropped the start, usually because the start budget
is spent; wait instead of retrying. An `app.authorization` with
`activitiesEnabled: false` means the user turned Live Activities off. Pass
`?after=<seq>` to read only newer events and `limit` (1 to 1000, default 200).

## Errors

Errors are JSON, and the message names the JSON path to fix:
`{"error": "invalid_layout", "message": "lockScreen.hstack[1].colour: unknown key; expected alignment, hstack, modifiers, spacing"}`.

- `payload_too_large`: the layout does not fit Apple's 4 KB push limit. Shorten
  text or simplify the layout.
- `device_not_ready`: the user has to open the Lykta app once.
- `too_many_activities`: end an activity first.
