---
name: lykta
description: Show live status on the user's iPhone Lock Screen and Dynamic Island as a Live Activity through their Lykta gateway. Use for countdowns, progress, builds, deliveries, checklists, questions answered with a tap or any ongoing task the user wants to glance at; not for one-off notifications.
---

# Lykta

Lykta shows a Live Activity on the user's iPhone. You send a JSON layout to the
user's gateway; the gateway validates it and pushes it to the phone, where it
renders natively. The Lykta app does not need to be open.

A layout nests native views, such as text, SF Symbols, live timers, progress,
charts, buttons and toggles, the way SwiftUI code would. For icons, diagrams
and artwork, embed ordinary SVG markup in an `svg` node; the phone draws it as
sharp vector graphics, and `{{placeholders}}` inside it update with the data.

You need the gateway URL and agent token from the setup the user copied out of
the Lykta app. Send the token as `Authorization: Bearer <token>`.

## Design

People read a Live Activity in a glance, on a phone others may see. Show the
one value they are waiting for, large and live, and leave detail and private
content to a tap.

Take the look from the subject, as its own app would: its colors (a transit
line's color, a brand's hex), its objects as SF Symbols or SVG drawings, and
its tone in `fontDesign`, such as `rounded` for a pet or `monospaced` for a
server. The Dynamic Island is always black, so one bold color carried through
its symbols, values and `keyline` is what makes the activity recognizable
there. On the Lock Screen, a `background` in the subject's colors carries the
same identity; without one the card is light or dark with the system
appearance, so use `primary` and `secondary` text and colors that read on
both. Spend boldness in one place, such as one drawing or one large number,
and keep the rest quiet. Let color follow the state, such as green once a
build passes, and let changing numbers count with `contentTransition`.

Each presentation has a job:

- **Lock Screen**: the live value first, then its context, in a layout made
  for this subject rather than a notification's icon, title and body. Add
  controls only for what people do to the activity itself, and keep them few.
  Let the height follow what there is to show, such as one line while a
  driver is found and more once one is on the way.
- **Compact**: one piece of information split around the camera, such as what
  it is leading and the live value trailing, in one color and type, both sides
  about as wide and snug against the camera. Round the value or shorten its
  unit before letting one side grow.
- **Minimal**: the live value or progress, such as a ring, a number or a tiny
  chart. It is often the only sign of the activity, so a logo alone says
  nothing. It is about 36 points wide, so a full timer such as `25:00`
  shrinks past reading; keep text to about three characters.
- **Expanded**: the compact view grown, keeping its placement: content hugs
  the camera from leading and trailing and wraps below it, with no empty band
  at the top. Make it clearly short or clearly tall, not in between.

Unless the request asks for them, avoid these defaults, which make an
activity look generated:

- emoji as icons; they ignore the layout's colors and read as stickers
- centered text above left-aligned rows, or a large centered number beside a
  left-aligned header
- an expanded view that copies the Lock Screen or leaves leading and trailing
  empty
- a minimal that repeats the compact icon
- a progress track too dark to see on black
- supporting text as heavy and bright as the main value instead of `secondary`
- one example's structure with the new content swapped in

Before designing your first layout, read every [example](#examples), all at
once in parallel. Together they show the range: drawn scenery, charts,
gauges, rows, chat bubbles and controls, each in its own palette. They are
still a small slice of what the nodes and SVG can do, one answer each to one
subject, so treat them as a vocabulary of techniques rather than templates:
combine them, go beyond them, and let your own subject decide the design.
[Fitting](references/layout.md#fitting) gives margins and sizes. Before
sending, check every presentation: does each show something live, do related
elements share a leading edge, does text clear every drawing, and would it be
recognizable without its title?

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
| `ifRevision` | Apply the PUT only if the activity is still at this `revision`; otherwise fail with `conflict`. |

iOS budgets how many activities an app may start by push. Once the budget is
spent it silently drops new starts for a while, so keep one name per purpose and
update it; never end and restart an activity to refresh it.

A PUT shows the activity right away, and Lykta cannot start one later by
itself. To show something at a later time, have a scheduler that outlives your
session send the PUT then, such as your harness's scheduled tasks or one the
user already uses, and tell the user what you set up. If you know of none, say
so and ask the user how to schedule it instead of leaving a process running. A
reminder that only needs to alert the user at a time belongs in their reminders
or calendar app.

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

## Buttons and toggles

Layouts can hold links, buttons and toggles (see the layout reference). A
toggle flips a boolean in the activity's data on the gateway and redraws at
once, so a checklist works while no agent runs. A button can change the data
the same way with `set`, `add` and `now`, so steppers, resets and pause buttons
work on their own. Agents read every press and toggle from `GET /v1/actions`:

```bash
cursor=$(curl -sS "$LYKTA_URL/v1/actions" -H "Authorization: Bearer $LYKTA_TOKEN" | jq .cursor)
curl -sS "$LYKTA_URL/v1/actions?after=$cursor&wait=25" -H "Authorization: Bearer $LYKTA_TOKEN"
```

```json
{"actions": [{"seq": 41, "activity": "deploy", "button": "retry", "at": "2026-10-21T18:02:11Z"}], "cursor": 41}
```

Without `after`, only actions that arrive during the request count, and the
`cursor` marks where to continue. `wait` (0 to 25 seconds) holds the request
open until an action arrives, so loop on it with the returned cursor to answer
presses within a second. Toggle changes appear as
`{"toggle": "items.0.done", "isOn": true}`. Actions are kept for a day.

Answer a press of a button without changes with a PUT, such as the next step
or an outcome. A button with `set`, `add` or `now` has already changed the data
when its press reaches you, so read the activity for the result instead of
applying the press again. A press counts for the button with that name that the
activity shows when the press arrives, so name buttons for what they do, such
as `approve-deploy-42` rather than `yes`. Because the user can change the data
at any moment, an agent that rewrites data reads the activity first and sends
the `revision` it read as `ifRevision`; on `conflict`, read again and redo the
change.

## End

`DELETE /v1/activities/{name}` ends the activity with its last content. The
system keeps it on the Lock Screen for up to four hours; `?dismissAfter=seconds`
(0 to 14400) removes it sooner. An activity without `endAfter` that nobody
ends stays until iOS ends it after eight hours.

## Status

`GET /v1/activities/{name}` returns the newest activity with that name,
including its current `data` and `revision`, and `GET /v1/activities` lists
recent ones:

| Field | Values |
| --- | --- |
| `state` | `starting`, `live`, `ending`, `ended` |
| `delivery` | `pending`, `accepted` (Apple accepted the push), `throttled`, `unknown`, `failed` |
| `device` | What the phone last reported: `pending`, `active`, `stale`, `ended`, `dismissed`, `unknown`, or `null` before its first report |
| `error` | Why delivery failed or the activity ended, or `null` |
| `layoutReadable` | Whether the phone could draw the current content, or `null` before it reports. `false` means it shows only the title |

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
An `after` newer than the gateway's newest event fails with `invalid_request`;
read once without it to start again.

## Errors

Errors are JSON, and the message names the JSON path to fix:
`{"error": "invalid_layout", "message": "lockScreen.hstack[1].colour: unknown key; expected alignment, hstack, modifiers, spacing"}`.

- `payload_too_large`: the layout does not fit Apple's 4 KB push limit. Shorten
  text or simplify the layout.
- `device_not_ready`: the user has to open the Lykta app once.
- `too_many_activities`: end an activity first.
- `conflict`: the activity changed since the `ifRevision` you sent, or a tapped
  control no longer exists.
- `app_update_required`: the user's Lykta app is older than a feature in the
  layout, named in the message with its path. Resend without it, or ask the
  user to update Lykta and open it once.

A 502 or a refused connection usually means the gateway is restarting for an
update; retry after a few seconds. Repeating a PUT is safe, but a repeated
`alert` lights up the phone again.

## Examples

Each example is a complete PUT body at the skill's own address, such as
`examples/homelab.json` next to this file. Read all of them, fetched in
parallel or in one command, before designing your first layout;
[Design](#design) says how to use them. Their times are Unix seconds around
1793000000; replace them with real ones from `date +%s`.

| Example | Shows |
| --- | --- |
| [agent-question](examples/agent-question.json) | An agent's question in a chat bubble; a reply button records the answer and shows it as the user's reply |
| [app-review](examples/app-review.json) | App Store review stages for a build, on a card colored by the review state |
| [homelab](examples/homelab.json) | A server dashboard of a CPU chart and gauges, each linking to Grafana, that flags a missed heartbeat |
| [jira-release](examples/jira-release.json) | A release's issues as a donut chart, light theme, a link per blocker |
| [movie-night](examples/movie-night.json) | A film timer between drawn curtains that pauses, takes a break with the lights up and resumes where it stopped |
| [orion-return](examples/orion-return.json) | Artemis II's figure-eight path around the Moon and home, drawn in SVG with Orion placed by progress |
| [pr-inbox](examples/pr-inbox.json) | Pull requests as rows from a list that slide in and out, each opening GitHub |
| [printer](examples/printer.json) | A drawn printer whose print grows in the filament's color, with a camera check and pause and resume buttons that move the finish time |
| [puppy-potty](examples/puppy-potty.json) | Time since the last trip outside around a drawn puppy; a button restarts the clock and counts the trip, with an Apple Watch view |
| [recipe-steps](examples/recipe-steps.json) | Cookbook steps looked up by number that slide in on Next and Back, with a ring timer each timed step starts and stops |
| [shopping-list](examples/shopping-list.json) | A checklist grouped by aisle that works without an agent and follows light and dark mode |
| [solar-eclipse](examples/solar-eclipse.json) | A countdown to totality over the eclipse's phases, drawn in SVG with a glowing corona |
