# Layout reference

A layout is JSON that the phone renders as native SwiftUI. Nodes nest like
SwiftUI views, and modifiers apply in order like SwiftUI modifiers. Every
example below is valid.

## Presentations

| Key | Required | Shown |
| --- | --- | --- |
| `lockScreen` | yes | On the Lock Screen, in banners and in StandBy. Full width; the system may cut off anything taller than 160 points. |
| `compactLeading`, `compactTrailing` | yes | Beside the camera when this is the only activity. One line each, shrunk to half size before truncating. |
| `minimal` | yes | A small circle when several activities share the Dynamic Island. |
| `expanded` | no | `{"leading", "trailing", "center", "bottom"}`, each optional, when the user presses the Dynamic Island. Leading and trailing move below the camera when they are too wide. |
| `small` | no | Apple Watch Smart Stack and CarPlay. Defaults to the compact pair side by side. |
| `background` | no | Lock Screen background color. |
| `keyline` | no | Dynamic Island outline color. |
| `link` | no | A URL that opens when the user taps the activity: `https`, or an app URL such as `shortcuts://run-shortcut?name=Lights`. |

## Parts

Define a repeated node once in the layout's root `parts` object, then place
`{"use": "name"}` anywhere a node goes. A use accepts only `use` and optional
`modifiers`, which append after the part's own modifiers:

```json
{"layout":{"parts":{"icon":{"symbol":"bolt.fill","modifiers":[{"foreground":"yellow"}]}},"lockScreen":{"hstack":[{"use":"icon"},"Charging"]},"compactLeading":{"use":"icon"},"compactTrailing":"80%","minimal":{"use":"icon","modifiers":[{"font":"caption"}]}}}
```

Parts may use other parts, but cycles, unknown names and unused definitions are
errors. Expansion is bounded by the layout's 256-node budget. It happens before
placeholders and `each` are filled: a part reads data and `each` variables at
its use site exactly as copied JSON would, with no parameters or separate scope.
The gateway stores the expanded template, so parts cost no phone compatibility.

## Data

`{{path}}` placeholders take values from the request's `data`. A placeholder
that is the whole string keeps the value's JSON type, so
`"progress": "{{fraction}}"` gives a number, `"offset": "{{shift}}"` an array
and `"if": "{{done}}"` a boolean. Inside other text the value is inserted as
text: `"{{done}} of {{total}}"`. Paths use dots for nesting and indices:
`{{build.steps.0.name}}`. A missing value is an error.

An item `{"each": "list.path", "as": "name", "do": node}` inside any list
repeats `node` once per entry of a data list, reading the entry as
`{{name.field}}`. Lists nest, and a layout repeats at most 256 items in total:

```json
{"vstack": [{"each": "steps", "as": "step", "do": {"text": "{{step.name}}"}}], "alignment": "leading"}
```

A path segment in brackets reads its index or key from the data:
`{{steps[step].text}}` with `"step": 2` reads `steps.2.text`, from a list or an
object with the key `"2"`. Together with buttons that change `step`, this pages
through steps the data holds.

Dates are ISO 8601 strings (`"2026-10-21T18:00:00Z"`) or Unix seconds.

## Nodes

A string is text. Any other node is an object with exactly one of the keys
below, its optional fields and an optional `modifiers` array.

| Node | Optional fields |
| --- | --- |
| `{"text": "Hi"}` | Same as `"Hi"`. A number shows as text. |
| `{"symbol": "bolt.fill"}` | Any SF Symbol name. `value` (0 to 1) fills symbols with variable parts, such as `wifi` or `speaker.wave.3.fill`. |
| `{"timer": [start, end]}` | `countsDown` (true), `pausedAt` (a date), `showsHours` (true). Counts on the phone without updates. |
| `{"date": date}` | `style`: `time` (default), `date`, `relative`, `offset`, `timer`. A `timer` date in the past counts up. |
| `{"concat": [parts]}` | One run of text from text, symbol, date and timer parts. Parts take only text modifiers. |
| `{"svg": "<svg …>"}` | SVG markup drawn natively: icons, diagrams, artwork. See [drawings](#drawings). |
| `{"shape": kind}` | `fill`, `stroke`, `lineWidth` (1), `lineCap` (`butt`, `round`, `square`), `dash` (lengths), `trim` (`[from, to]` within 0 to 1), `cornerRadius` (8, `roundedRectangle` only). Kinds: `rectangle`, `roundedRectangle`, `circle`, `ellipse`, `capsule`, `containerRelativeShape`. |
| `{"hstack": [nodes]}` | `alignment`: `top`, `center`, `bottom`, `firstTextBaseline`, `lastTextBaseline`. `spacing`. |
| `{"vstack": [nodes]}` | `alignment`: `leading`, `center`, `trailing`. `spacing`. |
| `{"zstack": [nodes]}` | `alignment`: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`. Later nodes draw on top. |
| `{"spacer": true}` | Or a minimum length instead of `true`. |
| `{"divider": true}` | |
| `{"progress": 0.4}` | `style`: `linear` (default), `circular`. A value from 0 to 1. |
| `{"progress": [start, end]}` | `style`, `countsDown` (false), `pausedAt`. Fills on the phone between the two dates. |
| `{"gauge": value}` | `min` (0), `max` (1), `style`: `circular` (default), `circularCapacity`, `linear`, `linearCapacity`. Label nodes: `label`, `currentValueLabel`, `minimumValueLabel`, `maximumValueLabel`. |
| `{"viewThatFits": [nodes]}` | `in`: `horizontal`, `vertical`. Shows the first node that fits, so put the largest first. |
| `{"if": condition, "then": node}` | `else`. Conditions: `stale`, `dark`, `luminanceReduced` (Always-On display), `fullscreen` (the activity fills the screen), `limitedWidth`, or `true`/`false` from data: `{"if": "{{failed}}", ...}`. |
| `{"grid": [[nodes], [nodes]]}` | Rows of cells whose columns line up. `alignment`, `horizontalSpacing`, `verticalSpacing`. |
| `{"chart": [marks]}` | `min` and `max` for the value axis, `axes` (false). See [charts](#charts). |
| `{"link": url, "label": node}` | Opens the URL. See [links, buttons and toggles](#links-buttons-and-toggles). |
| `{"button": name, "label": node}` | `style`: `automatic`, `plain`, `bordered`, `borderedProminent`. `set`, `add`, `now` change the data when pressed. |
| `{"toggle": "data.path", "label": node}` | `style`: `switch` (default), `button`, `checkbox`. Shows and flips the boolean at that data path. |

## Modifiers

Each modifier is an object with one key: `{"padding": 8}`.

| Modifier | Value |
| --- | --- |
| `padding` | A number, or `{"top", "leading", "bottom", "trailing", "horizontal", "vertical"}` |
| `frame` | `{"width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight", "alignment"}`; lengths may be `"infinity"` |
| `fixedSize` | `true`, `"horizontal"` or `"vertical"` |
| `layoutPriority` | A number; higher keeps its size first |
| `offset` | `[x, y]` |
| `rotation` | Degrees |
| `scale` | 0 to 10 |
| `opacity` | 0 to 1 |
| `foreground` | A paint, or 2 to 3 paints for `palette` symbols |
| `background`, `tint` | A paint |
| `clip` | A shape kind, or a corner radius |
| `shadow` | `{"color", "radius", "x", "y"}`, all optional |
| `font` | `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2`, or a size from 1 to 160 |
| `fontWeight` | `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `default`, `serif`, `rounded`, `monospaced` |
| `fontWidth` | `compressed`, `condensed`, `standard`, `expanded` |
| `bold`, `italic`, `underline`, `strikethrough`, `monospacedDigit` | `true` or `false` |
| `tracking` | -20 to 20 |
| `lineLimit` | 1 to 20 |
| `minimumScaleFactor` | 0.1 to 1 |
| `multilineTextAlignment` | `leading`, `center`, `trailing` |
| `truncationMode` | `head`, `middle`, `tail` |
| `textCase` | `uppercase`, `lowercase` |
| `contentTransition` | `numericText`, `opacity`, `interpolate`, `identity`, `symbolReplace`, or `{"numericText": value}` to count in the direction the value moved |
| `transition` | How the node enters and leaves: `opacity`, `slide`, `scale`, `identity`, `{"move": edge}`, `{"push": edge}` with an edge of `top`, `bottom`, `leading`, `trailing`, or a list of 2 to 3 of these to combine |
| `animation` | `{"value": v, "curve", "duration", "delay"}` animates changes inside the node when `v` changes. Curves: `default`, `linear`, `easeIn`, `easeOut`, `easeInOut`, `spring`, `bouncy`, `snappy`, `smooth`. `duration` 0.05 to 2 seconds, `delay` up to 1 |
| `id` | A string, number or boolean. A new value replaces the node, running its `transition` |
| `overlay` | A node drawn on top, sized to this node |
| `blur` | 0 to 20 |
| `grayscale` | 0 to 1 |
| `saturation` | 0 to 5 |
| `brightness` | -1 to 1 |
| `symbolRenderingMode` | `monochrome`, `hierarchical`, `palette`, `multicolor` |
| `imageScale` | `small`, `medium`, `large` |
| `accessibilityLabel` | Text for VoiceOver |

A paint is a color, a level (`primary`, `secondary`, `tertiary`,
`quaternary`), `{"gradient": [2 to 8 colors], "direction": d}` with `d` one
of `vertical` (default), `horizontal`, `diagonal`, `radial`, `angular`, or a
mesh. A color
is `#RGB`, `#RRGGBB`, `#RRGGBBAA`, `rgb(r, g, b)`, `rgba(r, g, b, a)` or one of `red`, `orange`, `yellow`, `green`, `mint`,
`teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown`, `white`, `gray`,
`black`, `clear`, `accent`.

A mesh is a smooth two-dimensional color field: `{"mesh": rows}` with 2 to 4
equal rows of 2 to 4 points, each `[x, y, color]` with `x` and `y` within 0 to
1, left to right and top to bottom. Keep the outer points on the edges, since
the area outside the mesh is transparent, and move inner points to bend the
field. The Dynamic Island stays black, so put a mesh inside its content.

```json
{"shape": "roundedRectangle", "cornerRadius": 14, "fill": {"mesh": [[[0, 0, "indigo"], [1, 0, "pink"]], [[0, 1, "cyan"], [1, 1, "orange"]]]}}
```

## Charts

A chart draws up to 8 marks over shared positions 0, 1, 2… Each mark is an
object with one kind key holding 1 to 100 numbers:

| Mark | Optional fields |
| --- | --- |
| `{"line": [numbers]}` | `color` (a paint), `lineWidth` (2), `interpolation`: `linear`, `monotone`, `catmullRom`, `cardinal`, `stepStart`, `stepCenter`, `stepEnd` |
| `{"area": [numbers]}` | `color`, `interpolation` |
| `{"bar": [numbers]}` | `color`, `colors` (one color per value), `cornerRadius` |
| `{"point": [numbers]}` | `color`, `colors` |
| `{"rule": number}` | `color`, `lineWidth`. A dashed line across the chart, such as a target. |
| `{"sector": [numbers]}` | `colors`, `innerRadius` (0 up to 1). Slices of a pie or, with an inner radius, a donut. |

Charts hide their axes unless `axes` is true, so give them a `frame`. Bind a
data list with `"line": "{{series}}"`.

## Drawings

`{"svg": markup}` draws ordinary SVG as native vector graphics, sharp at any
size. Use it for icons, diagrams, maps, trajectories and artwork; use layout
nodes for text the user reads and for anything that counts or can be tapped.
The gateway rejects what the phone cannot draw and names the element.

- **Size.** With `width` and `height` on the root, in points, the drawing has
  that size, like an icon. Without them it fills the width it is offered and
  keeps the `viewBox` proportions.
- **Color.** `fill` defaults to black, as in SVG. `currentColor` takes the
  node's `foreground`, so one icon follows the layout's colors.
- **Data.** `{{placeholders}}` work inside the markup, and their values are
  escaped, so a name such as `R&D` is safe. A placeholder that is the whole
  markup, `"svg": "{{icon}}"`, inserts SVG from the data as is.
- **Progress along a path.** With `pathLength="1"`, dash lengths are fractions
  of the path. `stroke-dasharray="{{progress}} 2"` draws the part travelled,
  and `stroke-dasharray="0 2" stroke-dashoffset="-{{progress}}"` with
  `stroke-linecap="round"` puts a dot, as wide as the stroke, at that point.

| Element | Attributes |
| --- | --- |
| `svg` | `viewBox`, `width`, `height` |
| `g` | Groups children; its presentation attributes and `transform` apply to them |
| `path` | `d` with every command, absolute and relative: `M L H V C S Q T A Z` |
| `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon` | Their geometry: `x`, `y`, `width`, `height`, `rx`, `ry`, `cx`, `cy`, `r`, `x1`, `y1`, `x2`, `y2`, `points` |
| `text` | One filled line at `x`, `y`, styled with `font-size`, `font-weight`, `font-family` (`serif`, `monospace` or `ui-rounded`; others fall back to the system font), `text-anchor`, `dominant-baseline` |
| `linearGradient`, `radialGradient` with `stop`s | `x1`, `y1`, `x2`, `y2`, `cx`, `cy`, `r`, `gradientUnits`; stops take `offset`, `stop-color`, `stop-opacity`. Use as `fill="url(#id)"` or `stroke="url(#id)"` |
| `filter` with one `feGaussianBlur` | `stdDeviation`; `filter="url(#id)"` blurs a shape, for glows |
| `defs`, `title`, `desc` | Hold definitions; not drawn. The root's `title` is read to VoiceOver |

Every drawn element and `g` takes `fill`, `fill-opacity`, `fill-rule`,
`stroke`, `stroke-width`, `stroke-opacity`, `stroke-linecap`,
`stroke-linejoin`, `stroke-miterlimit`, `stroke-dasharray`,
`stroke-dashoffset`, `opacity`, `filter`, `transform` (`matrix`, `translate`,
`scale`, `rotate`, `skewX`, `skewY`), `id`, the text styles, and the same
properties in `style="…"`. Shapes also take `pathLength`. Lengths are numbers
in `viewBox` units, optionally `px`, or percentages of the `viewBox`. Colors
are layout colors plus `none` and `currentColor`; names such as `green` are
Apple's system colors, and CSS-only names such as `navy` are rejected, so use
hex for exact brand colors. `class`, `aria-*`, `data-*`, `role` and
`focusable` are ignored, so icon sets paste in as they are. There is no `use`,
`clipPath`, `mask`, `pattern`, `image`, `tspan` or `<style>` sheet. A drawing holds
up to 512 shapes and groups and 4096 path segments and dashes (an arc
counts as up to four curves), and its markup counts toward the push
limit; repeating a path costs little because pushes are compressed.

```json
{
  "svg": "<svg viewBox='0 0 200 60'><path d='M10 50C60 0 140 0 190 50' fill='none' stroke='currentColor' stroke-opacity='.3' stroke-width='2' stroke-dasharray='3 4'/><path d='M10 50C60 0 140 0 190 50' fill='none' stroke='currentColor' stroke-width='3' stroke-linecap='round' pathLength='1' stroke-dasharray='{{progress}} 2'/><path d='M10 50C60 0 140 0 190 50' fill='none' stroke='currentColor' stroke-width='9' stroke-linecap='round' pathLength='1' stroke-dasharray='0 2' stroke-dashoffset='-{{progress}}'/></svg>",
  "modifiers": [{"foreground": "orange"}]
}
```

## Links, buttons and toggles

The system accepts taps only in `lockScreen` and `expanded`, so controls are
rejected elsewhere, and a label cannot contain another control. Buttons and
toggles work once the phone is unlocked.

- A `link` opens its URL, like the presentation-wide `link`.
- A `button` press is delivered to agents through `GET /v1/actions` with the
  button's name, which is 1 to 64 characters from `a-z`, `0-9`, `-`, `_` and
  `.`. Unless the button changes the data itself, nothing on the phone changes
  until an agent responds with an update.
- A `toggle` names a boolean in the data instead of holding a state. A tap
  flips that value on the gateway, which redraws the activity at once and also
  reports the change through `GET /v1/actions`. A checklist therefore works
  without any agent listening. Inside `each`, `"toggle": "item.done"` names the
  current entry.

A button changes the data on the gateway, which redraws the activity at once,
so it works while no agent runs:

| Key | Change |
| --- | --- |
| `set` | `{"path": value}` sets each path to the value. Values fill from the data like the rest of the layout, so `"set": {"answer": "{{choice.label}}"}` copies a label. |
| `add` | `{"path": number}` adds the number to the number at the path. `{"path": {"since": "date.path"}}` adds the seconds since the date at that path, which moves a paused timer's start and end past the pause. |
| `now` | `{"path": seconds}` sets the path to the time the gateway receives the press, in Unix seconds, plus the seconds. |

Paths name values the data already holds, take `each` names and brackets like
placeholders, and each value changes once per button. Every change reads the
data as it was before the press. A press whose result the layout cannot show,
such as Next past the last step, changes nothing. Buttons that share a name
must change the data alike. A press counts only for a control the data shows,
so a button in the branch of an `if` on data that is not taken does nothing,
and a second tap on Pause after the activity paused is ignored.

```json
{
  "hstack": [
    {"button": "back", "label": {"symbol": "chevron.left"}, "add": {"index": -1}},
    {"text": "{{steps[index].name}}"},
    {"button": "next", "label": {"symbol": "chevron.right"}, "add": {"index": 1}}
  ]
}
```

A timer that pauses and resumes keeps `pausedAt` null while it runs:

```json
{
  "hstack": [
    {"timer": ["{{start}}", "{{end}}"], "pausedAt": "{{pausedAt}}", "modifiers": [{"frame": {"width": 56}}]},
    {
      "if": "{{paused}}",
      "then": {"button": "resume", "label": {"symbol": "play.fill"}, "set": {"paused": false, "pausedAt": null},
               "add": {"start": {"since": "pausedAt"}, "end": {"since": "pausedAt"}}},
      "else": {"button": "pause", "label": {"symbol": "pause.fill"}, "set": {"paused": true}, "now": {"pausedAt": 0}}
    }
  ]
}
```

```json
{
  "vstack": [
    {"each": "items", "as": "item", "do": {
      "toggle": "item.done", "style": "checkbox",
      "label": {"if": "{{item.done}}", "then": {"text": "{{item.name}}", "modifiers": [{"strikethrough": true}]}, "else": "{{item.name}}"}
    }},
    {"button": "restock", "label": "Add more", "style": "bordered"}
  ],
  "alignment": "leading"
}
```

## Motion

The phone animates the change from one update to the next for up to two
seconds, and not at all on the Always-On display. Numbers roll with
`contentTransition`. To make a node slide or fade in, give it a `transition`
and an `id` from the data, and an `animation` on a container whose `value`
changes with it:

```json
{
  "hstack": [{"text": "{{step}}", "modifiers": [{"transition": {"push": "trailing"}}, {"id": "{{index}}"}]}],
  "modifiers": [{"animation": {"curve": "smooth", "value": "{{index}}"}}]
}
```

## Fitting

A layout may be at most 32 KB with 256 nodes, 16 levels and 512 modifiers, and
its compressed push must fit Apple's 4 KB limit. Compression makes repeats
nearly free and spends the bytes on distinct detail, so long SVG paths cost
most: drop decimals a mark's display size cannot show, but keep the points
its shape needs, and build a symmetric mark from one part repeated with
`rotation`. Within a presentation:

- Pad Lock Screen content 14 points from its edges, the margin notifications
  use, so the two line up in the list. Drawings and buttons may come closer.
- Keep an even margin to the rounded outline so nothing pokes into a corner.
  A `containerRelativeShape` takes the activity's corner radius, so an inset
  card or tile nests concentrically.
- Separate a block with an inset shape or a thick line, not a fill that runs
  to the edge; in StandBy the `background` extends to the screen's edges and
  such a fill looks cut off.
- Start related elements, such as a header, the text under it and its
  progress bar, at one leading inset; a few points off reads as a mistake.
- Keep about 10 points between text and drawn decoration, such as a border or
  a curtain; closer, the text looks pinned to it.
- Keep about 8 points between a ring or gauge and its tile's edge, and value
  text inside a ring within two thirds of the inner diameter. `scale` shrinks
  the drawing but not the space it takes, so pair it with a `frame` of the
  scaled size, as homelab's gauges do; shapes and SVG resize to a smaller
  `frame` on their own.
- Expanded content clips at about 145 points tall. Add up the rows before
  adding one, and add `fixedSize: "vertical"` to text that must keep its
  second line.
- Expanded `leading` and `trailing` beside the camera hold about 44 points;
  wider content moves below it.
- When `{"if": "limitedWidth"}` holds, as in landscape, each compact side and
  the minimal get a 28-point circle: show a symbol, a short number or a ring.
- Size a circular `progress` with a `frame`, such as 24 points in `minimal`.
- Thin lines and light text fade on black: stroke rings at least a tenth of
  their width with round caps, use medium weight or heavier, and draw tiny
  charts with a `line` mark of 1.5 to 2 points, since an `area` alone vanishes.
- When you draw a ring or bar from shapes, draw its track in the tint at
  about 35% opacity; `quaternary` or near-black tracks disappear on black, so
  a nearly empty ring shows nothing.
- Glows and shadows are clipped at the edge of a Dynamic Island region; keep
  their radius small in compact and minimal.
- `tint` on `progress` takes one color; a gradient shows only its first.
- Give timers a fixed `frame` width; timer text otherwise reserves room for its
  longest value. In the expanded `center`, an unframed timer pushes `leading`
  and `trailing` below the camera.
- Offer shorter alternatives with `viewThatFits`.
- Bound text with `lineLimit` and `minimumScaleFactor`.
- Prefer `spacer` and alignment over fixed offsets so content adapts to each
  iPhone.

## Examples

A ring:

```json
{
  "zstack": [
    {"shape": "circle", "stroke": "green", "lineWidth": 4, "modifiers": [{"opacity": 0.35}]},
    {"shape": "circle", "stroke": "green", "lineWidth": 4, "lineCap": "round", "trim": [0, 0.7],
     "modifiers": [{"rotation": -90}]},
    {"text": "70", "modifiers": [{"font": 11}, {"fontWeight": "semibold"}, {"monospacedDigit": true}]}
  ],
  "modifiers": [{"frame": {"width": 28, "height": 28}}]
}
```

Inline symbols and styled runs:

```json
{"concat": [{"symbol": "airplane"}, " Gate ", {"text": "B12", "modifiers": [{"bold": true}]}],
 "modifiers": [{"font": "headline"}]}
```

Alternatives for narrow space, and a stale state:

```json
{"viewThatFits": ["Deploying api to production", "Deploying api", "api"]}
```

```json
{"if": "stale", "then": {"text": "Waiting for news", "modifiers": [{"foreground": "secondary"}]}, "else": "On track"}
```

A complete request body that later updates send as `data` only:

```json
{
  "title": "Deploying api",
  "layout": {
    "lockScreen": {
      "vstack": [
        {
          "hstack": [
            {"symbol": "shippingbox.fill", "modifiers": [{"font": "title2"}, {"foreground": "blue"}]},
            {
              "vstack": [
                {"text": "Deploying {{service}}", "modifiers": [{"font": "headline"}]},
                {"text": "{{step}}", "modifiers": [{"foreground": "secondary"}, {"lineLimit": 1}]}
              ],
              "alignment": "leading",
              "spacing": 2
            },
            {"spacer": true},
            {"date": "{{started}}", "style": "timer",
             "modifiers": [{"monospacedDigit": true}, {"multilineTextAlignment": "trailing"}, {"frame": {"width": 56}}]}
          ],
          "spacing": 10
        },
        {"progress": "{{progress}}", "modifiers": [{"tint": "blue"}]}
      ],
      "spacing": 12,
      "modifiers": [{"padding": 14}]
    },
    "compactLeading": {"symbol": "shippingbox.fill", "modifiers": [{"foreground": "blue"}]},
    "compactTrailing": {"text": "{{done}}/{{total}}", "modifiers": [{"monospacedDigit": true}, {"contentTransition": "numericText"}]},
    "minimal": {"progress": "{{progress}}", "style": "circular", "modifiers": [{"tint": "blue"}]},
    "expanded": {
      "leading": {"symbol": "shippingbox.fill", "modifiers": [{"font": "title2"}, {"foreground": "blue"}]},
      "trailing": {"text": "{{done}} of {{total}}", "modifiers": [{"monospacedDigit": true}]},
      "center": {"text": "{{step}}", "modifiers": [{"font": "headline"}, {"lineLimit": 1}]},
      "bottom": {"progress": "{{progress}}", "modifiers": [{"tint": "blue"}]}
    },
    "keyline": "blue"
  },
  "data": {"service": "api", "step": "Running migrations", "done": 3, "total": 5, "progress": 0.6, "started": 1793000000}
}
```
