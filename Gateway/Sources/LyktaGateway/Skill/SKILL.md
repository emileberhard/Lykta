---
name: lykta
description: Reach the user's iPhone through their Lykta gateway, with Live Activities on the Lock Screen and Dynamic Island and with notifications. Use for countdowns, progress, builds, deliveries, checklists and questions answered with a tap, and to tell the user the moment something happens, such as a finished job or a failure.
---

# Lykta

Lykta reaches the user's iPhone in two forms: a Live Activity, which stays on
the Lock Screen and in the Dynamic Island and changes while something goes on,
and a notification, which tells the user about one moment. You send JSON to
the user's gateway; the gateway validates it and pushes it to the phone. The
Lykta app does not need to be open.

## The lykta command

Send everything with `lykta`, a small command in this skill's `scripts`
folder: `lykta` for sh with curl, `lykta.ps1` for PowerShell. The setup the
user copied from the Lykta app installs it, saves the gateway and token, and
says how to run it. Otherwise run `scripts/lykta` from this folder, which uses
`LYKTA_URL` and `LYKTA_TOKEN` when they are set, or first
`scripts/lykta setup URL TOKEN` with the user's gateway and token.

| Command | Does |
| --- | --- |
| `lykta put PATH [FILE]` | Sends the JSON in FILE, or on stdin, to `PUT /v1/PATH` and prints the result once Apple has answered |
| `lykta get PATH` | `GET /v1/PATH` |
| `lykta delete PATH` | `DELETE /v1/PATH` |
| `lykta media FILE` | Uploads an image or sound and prints its id |
| `lykta docs FILE...` | Prints files of this skill |

It prints the gateway's JSON. When the gateway refuses a request, `lykta`
exits with 1 and prints the error, whose message names what to fix; 2 means a
usage or setup mistake, and 3 that the gateway was unreachable or failed, with
a message that says whether to retry or, because a PUT may have been applied,
to read the result first. Write a body with a layout to a file, in the same
command as the `lykta put` that sends it, so a refused body takes a small edit
instead of a rewrite; a quoted heredoc keeps the JSON free of escaping, and
short updates can go to `lykta put` in one directly. Quote paths that hold `?`
or `&`. In PowerShell, pass the body as
a UTF-8 file, because Windows PowerShell pipes only ASCII to other programs,
and quote an argument that holds `&` twice, as `'"actions?after=40&wait=25"'`,
because `lykta` passes it on through cmd. Without a shell, send the same
requests over HTTP with the token as `Authorization: Bearer <token>`, `wait=10`
in each PUT's query, and media as the body of `POST /v1/media`.

## Choose the form

Pick the form from what the user asked for:

- **Notification** for "tell me when": one moment, such as a finished job, a
  failure or an answer that arrived. Read the
  [notifications reference](references/notifications.md); a notification needs
  nothing else from this file.
- **Live Activity** for "keep me posted": something ongoing worth a glance,
  such as a countdown, progress, a delivery or a checklist. The rest of this
  file covers activities.
- **An activity's `alert`** when an activity about the subject is already
  showing and a moment in it needs attention, such as a failed step of a
  deploy it tracks. Update the activity rather than sending a notification
  beside it.

## Live Activities

A layout nests native views, such as text, SF Symbols, live timers, progress,
charts, buttons and toggles, the way SwiftUI code would. For icons, diagrams
and artwork, embed ordinary SVG markup in an `svg` node; the phone draws it as
sharp vector graphics, and `{{placeholders}}` inside it update with the data.

## Design

People read a Live Activity in a glance, on a phone others may see. Show the
one value they are waiting for, large and live, and leave detail and private
content to a tap.

Take the look from the subject, as its own app would: its colors (a transit
line's color, a brand's hex), its objects as SF Symbols or SVG drawings, and
its tone in `fontDesign`, such as `rounded` for a pet or `monospaced` for a
server. The Dynamic Island is always black, so a bold color carried through
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
  it is leading and the live value trailing, in consistent color and type,
  both sides about as wide and snug against the camera. Round the value or
  shorten its unit before letting one side grow.
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

Before designing your first layout, read the
[layout reference](references/layout.md) and every [example](#examples) at
once, with these commands, or the same files directly when this skill is on
disk. Each prints about as much as one tool result shows, so run them as
separate calls, in parallel where your harness allows; a script that runs
several in one call gets cut off.

```sh
lykta docs references/layout.md
lykta docs examples/recipe-steps.json examples/puppy-potty.json examples/pr-inbox.json
lykta docs examples/jira-release.json examples/ai-usage.json examples/orion-return.json
lykta docs examples/homelab.json examples/movie-night.json examples/printer.json
lykta docs examples/solar-eclipse.json examples/agent-question.json examples/app-review.json examples/shopping-list.json
```

Together they show the range: drawn scenery, charts,
gauges, rows, chat bubbles and controls, each in its own palette. They are
still a small slice of what the nodes and SVG can do, one answer each to one
subject, so treat them as a vocabulary of techniques rather than templates:
combine them, go beyond them, and let your own subject decide the design.
[Fitting](references/layout.md#fitting) gives margins and sizes. Before
sending, check every presentation: does each show something live, do related
elements share a leading edge, does text clear every drawing, do the expanded
rows add up to less than about 145 points, and would it be recognizable
without its title?

## Start or update

`lykta put activities/{name}` with a JSON body starts the activity when no
live activity has that name, and updates it otherwise. A name is 1 to 64 characters
from `a-z`, `0-9`, `-`, `_` and `.`.

| Field | Meaning |
| --- | --- |
| `title` | Required to start; up to 120 characters. Used for alerts and when the phone cannot render the layout. |
| `layout` | Required to start. See [the layout reference](references/layout.md). |
| `data` | Values for `{{path}}` placeholders in the layout. Replaces the previous data. |
| `now` | `{"path": seconds}` sets each data path to the time the gateway receives the PUT, in Unix seconds, plus the seconds, such as `{"started": 0, "ends": 1500}` for a timer that ends in 25 minutes. Missing paths are created. |
| `alert` | `{"title", "body", "sound": true}` lights up the screen and expands the Dynamic Island. Only `body` is required; up to 200 characters. Use it for moments that need attention. |
| `staleAfter` | Seconds until the phone marks the activity as out of date. Each PUT renews it. |
| `endAfter` | Seconds, up to 28800, until the gateway ends the activity and removes it from the Lock Screen, at the latest 7 hours 59 minutes after the activity started. A PUT that includes it moves the deadline; one without it keeps the deadline. Set it whenever you know when the activity is over, because you may not be running then. |
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

Write bodies as compact single-line JSON, and repeat similar rows with `each`
over a data list instead of copying nodes; both cut the tokens you write.
Reuse identical nodes across presentations with root `parts` and `{"use":"name"}`.

`lykta put` waits up to 10 seconds for Apple's answer and prints the
activity's [status](#status) and `data`, so it needs no read afterwards:
`delivery` is `accepted`, or says what happened. It also prints
`payloadBytes`, the push size Lykta checks against APNs' 4096-byte limit; iOS
also caps the name plus content at 4096 bytes, which a long name can make the
tighter limit.

Updates normally send only `data`; the title and layout keep their last values.
Timers and timer-driven progress run on the phone, so send them once instead of
updating every second. The phone shows at most one update per second per
activity; faster PUTs collapse into the latest state.

```sh
lykta put activities/deploy deploy.json

lykta put activities/deploy <<'EOF'
{"data": {"service": "api", "step": "Done", "done": 5, "total": 5, "progress": 1, "started": 1793000000}}
EOF
```

## Buttons and toggles

Layouts can hold links, buttons and toggles (see the layout reference). A
toggle flips a boolean in the activity's data on the gateway and redraws at
once, so a checklist works while no agent runs. A button can change the data
the same way with `set`, `add` and `now`, so steppers, resets and pause buttons
work on their own. Agents read every press and toggle with `lykta get actions`:

```sh
lykta get actions
lykta get 'actions?after=40&wait=25'
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

`lykta delete activities/{name}` ends the activity with its last content. The
system keeps it on the Lock Screen for up to four hours;
`lykta delete 'activities/{name}?dismissAfter=seconds'` (0 to 14400) removes it
sooner.

iOS ends an activity eight hours after it starts and keeps it on the Lock
Screen for up to four more, beside any new activity with its name. For status
that outlasts that, such as a dashboard, send `endAfter`, `title` and `layout`
with every update: the gateway then removes the activity before the limit, and
your next PUT starts a fresh one.

## Status

`lykta get activities/{name}` returns the newest activity with that name,
including its current `data` and `revision`, and `lykta get activities` lists
recent ones:

| Field | Values |
| --- | --- |
| `state` | `starting`, `live`, `ending`, `ended` |
| `delivery` | For the current revision: `pending`, `accepted` (Apple accepted the push), `throttled`, `unknown`, `failed` |
| `device` | What the phone last reported: `pending`, `active`, `stale`, `ended`, `dismissed`, `unknown`, or `null` before its first report |
| `error` | Why delivery failed or the activity ended, or `null` |
| `layoutReadable` | Whether the phone could draw the current content, or `null` before it reports. `false` means it shows only the title |

Accepted means Apple took the push, not that the phone displayed it.

## Debug

When an activity does not appear or update, read `lykta get events` before
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
`events?after=<seq>` to read only newer events and `limit` (1 to 1000, default 200).
An `after` newer than the gateway's newest event fails with `invalid_request`;
read once without it to start again.

## Errors

Errors are JSON, and the message names the JSON path to fix:
`{"error": "invalid_layout", "message": "lockScreen.hstack[1].colour: unknown key; expected alignment, hstack, modifiers, spacing"}`.

- `payload_too_large`: the push, or the activity's name and content together,
  would exceed Apple's 4 KB limit. The message says which, and estimates how
  many compressed bytes the costliest JSON paths take; simplify those or
  shorten text.
- `device_not_ready`: the user has to open the Lykta app once.
- `too_many_activities`: end an activity first.
- `conflict`: the activity changed since the `ifRevision` you sent, or a tapped
  control no longer exists.
- `app_update_required`: the user's Lykta app is older than a feature in the
  layout, named in the message with its path. Resend without it, or ask the
  user to update Lykta and open it once.

Repeating a PUT is safe, but a repeated `alert` lights up the phone again.

## Examples

Each example is a complete PUT body, such as `examples/homelab.json` next to
this file. Read all of them before designing your first layout, as
[Design](#design) says. Their times are Unix seconds around 1793000000; set
real ones with `now` rather than computing them.

| Example | Shows |
| --- | --- |
| [agent-question](examples/agent-question.json) | An agent's question in a chat bubble; a reply button records the answer and shows it as the user's reply |
| [ai-usage](examples/ai-usage.json) | Weekly Claude and Codex limits and a monthly Copilot budget as rings around each brand's mark, amber once one runs low |
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
