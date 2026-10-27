# Widgets

A widget is a place on the user's Home Screen or Lock Screen that is always
there, such as today's steps, a balance or a server's health. Its layout uses the same nodes,
modifiers and parts as a Live Activity; only the root keys differ, as the
[layout reference](layout.md#presentations) shows. Read that reference and the
example before designing your first widget:

```sh
lykta docs references/layout.md
lykta docs examples/widgets/steps-widget.json
```

## Send

`lykta put widgets/{name}` creates the widget when the phone has none with that
name, and updates it otherwise. Names follow the rules for activities.

| Field | Meaning |
| --- | --- |
| `title` | Required to create; up to 120 characters. The user picks the widget by this title, and the phone shows it when it cannot draw the layout. |
| `layout` | Required to create: at least one family, such as `systemSmall`, and optionally `background` and `link`. |
| `data` | Values for `{{path}}` placeholders. Replaces the previous data. |
| `now` | `{"path": seconds}` sets each path to the gateway's time plus the seconds, as for activities. |
| `staleAfter` | Seconds after a change until the widget draws as out of date, with `{"if": "stale"}` true. |
| `ifRevision` | Apply the PUT only if the widget is still at this `revision`; otherwise fail with `conflict`. |

A widget has no `alert`, `endAfter` or `relevance`; it stays until you delete
it. A phone holds at most 32 widgets. Updates normally send only `data`.

```sh
lykta put widgets/steps steps.json
lykta put widgets/steps <<'EOF'
{"data": {"steps": "8,120", "goal": "10,000", "fraction": 0.81}}
EOF
```

A new widget appears nowhere until the user adds it, so after creating one,
tell the user to add the Lykta widget in a size it has, on the Home Screen
(touch and hold, Edit, Add Widget, Lykta) or the Lock Screen (touch and hold,
Customize, Lock Screen, then the slots below or above the clock), and choose
its title. `placed` in the status lists the sizes that show it.

## How updates arrive

The gateway tells the phone that its widgets changed with a push, at most once
every 20 minutes, and iOS then reloads every Lykta widget when its budget
allows. Updates in between collapse into the latest data. Each widget also
asks iOS to reload it at its stale time, or after three hours at the latest,
and iOS decides when it does. A widget therefore suits values that change over
hours; for something that changes
from minute to minute, use a Live Activity. Timers and relative `date` nodes
keep counting on the phone between reloads, so send a deadline once instead
of a countdown.

`lykta put` waits up to 10 seconds for a place to load the change, returning
early when the outcome is known, and prints the widget's status:

| Field | Values |
| --- | --- |
| `delivery` | `notPlaced` (no place shows it; it loads when the user adds it), `pending` (the push goes out at `nextPush`, or, without one, the phone loads the change when it next reloads), `accepted` (Apple took the push; the phone reloads when iOS allows), `fetched` (a place on the phone loaded this revision and can draw it), `failed` (see `error`, such as a Lykta app too old to draw the widget) |
| `placed` | The sizes that show the widget |
| `fetched` | `{"revision", "at"}` of the newest revision a place loaded |
| `revision`, `id`, `createdAt`, `updatedAt` | As for activities |

`pending` is normal: it means your change waits for the next push window, not
that something failed. Don't send it again. An `accepted` that never becomes
`fetched` usually means the phone was offline and missed the push; the widget
asks iOS to load it again within a few hours, and iOS decides when.

## Design

Design each family you send for its size, and leave out the ones the subject
does not suit. Each family is a separate root in the layout; share nodes
between them with `parts`.

| Family | Size on large iPhones (smaller) | Suits |
| --- | --- | --- |
| `systemSmall` | 170 × 170 (155 × 155) | The one value that matters, large, with a short label |
| `systemMedium` | 364 × 170 (329 × 155) | That value with context beside it, such as a chart of the week or a short list |
| `systemLarge` | 364 × 382 (329 × 345) | A dashboard: the value, a chart and a few rows |
| `accessoryCircular` | 76 × 76 (72 × 72) | A gauge or a symbol with a number of up to four characters |
| `accessoryRectangular` | 172 × 76 (160 × 72) | A headline with two short lines or a small chart |
| `accessoryInline` | One line, about 20 characters | A symbol and a short phrase |

The system adds margins of about 16 points around the Home Screen families, so
their roots need no padding. People read widgets from across the room: keep
text short and large, and leave detail to a tap through `link`.

The Home Screen background, a paint or a node, carries the subject's identity.
The system removes it in StandBy and replaces it with glass or a tint when the
user tints the Home Screen, so the content must stay readable without it:

- Under `{"if": "showsBackground"}`, choose the colors for your background;
  in the `else`, use `primary` and `secondary`.
- When `accented` holds, the system draws the widget in one tint and tells
  parts apart only by opacity, so the layout must not rely on color.

The Lock Screen families are always `vibrant`: the system ignores their colors
and draws them in shades of one color over the wallpaper, without a
background. Use weight, size and opacity to separate parts. A gauge or
`{"accessoryBackground": true}`, first in a `zstack`, gives a circular or
rectangular widget the system's own backdrop. `accessoryInline` shows only the
first symbol and text of its line, so put the value first.

Widgets show on the Lock Screen, in StandBy, on a Mac that shows iPhone
widgets and on Apple HomeView, where anyone nearby can read them. Leave private details out, or mark
the nodes that hold them `{"privacySensitive": true}`, which hides them while
the phone is locked if the user chose to hide widget data then.

`link` opens a URL when the user taps the widget, and a `link` node opens its
own URL for a part of it, in every Home Screen family and
`accessoryRectangular`. Widgets take no buttons or toggles yet.

The [steps example](../examples/widgets/steps-widget.json) shows every family,
with the week's chart in the medium and large ones, and renders them all in the
app's examples.

## Read, list and delete

`lykta get widgets` lists the phone's widgets with their status, and
`lykta get widgets/{name}` adds the stored `layout` and `data`.
`lykta delete widgets/{name}` deletes a widget: every place that showed it
shows it as removed, and a later PUT with the same name creates a new widget
the user has to choose again. Update a widget rather than deleting and
recreating it.

## Errors and debugging

Errors are those of activities, plus `too_many_widgets` when the phone already
holds 32. `app_update_required` names the feature the phone's Lykta app is too
old to draw.

`lykta get events` shows `widget.put`, `widget.delete`, `widget.placed` (a size
added or removed on the phone), `push.widgets` with Apple's outcome and
`widget.fetch` (a place loaded a revision). A `push.widgets` without a later
`widget.fetch` means iOS has not reloaded yet, which it does when its budget
allows.
