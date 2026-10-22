# Lykta

Lykta shows server-defined native Live Activities on iPhone. Agents send JSON
layouts to a self-hosted gateway, which validates them and delivers them over
APNs. Read the [architecture record](docs/architecture.md) before changing a
boundary below. `CLAUDE.md` is a symlink to this file.

## Ownership

| Path | Owns |
| --- | --- |
| `Core` | Layout language, templates, `ContentState` wire format and device API types; no dependencies |
| `Rendering` | SwiftUI for every node and modifier, and the Lock Screen view; both the app and the widget extension compile it |
| `Widgets` | The Live Activity configuration and Dynamic Island presentations |
| `App` | Registration, Keychain credentials, ActivityKit observation, device reports and the in-app Lock Screen cards |
| `App/AppIcon.icon` | The final app icon, three overlapping lights; change it only when the maintainer asks |
| `Gateway` | HTTP API, `Store` (all durable state), delivery and APNs |
| `Gateway/Sources/LyktaGateway/Skill` | The agent skill the gateway serves; `.agents/skills/lykta` links to it |
| `.agents/skills/self-host` | Setting up a gateway and app build |
| `AppStore` | The App Store screenshot fixture activities and slide composer |
| `scripts/render`, `Widgets/RenderPreviews.swift` | The render tool and the preview it drives, which shows the layouts staged in `.local/render` |

## Invariants

- A layout change touches `Core`, `Rendering` and the skill's `layout.md`
  together. Gateway tests compile every JSON example in `layout.md` and start
  every activity in the skill's `examples`. Look at a layout change with
  `just render` before shipping it.
- Rendering is bounded and offline: layouts stay within the `Layout` budgets,
  the widget makes no network requests, and view bodies never parse JSON.
- The gateway is the only content writer. The app never calls
  `Activity.request` or updates content; it ends an activity only when the
  gateway reports it ended, or on Reset.
- Unknown stays unknown. A start with an unknown outcome is never retried. A
  missing report never ends an activity, except when the activity is absent
  from the first report of a new app install or update.
- `Store` commits every state change in one transaction. Ending fences later
  updates, updates coalesce to the latest revision, and starts and ends are
  never dropped.
- Tokens are stored only as hashes. Never log tokens, push tokens or payloads.
- Every state change, push attempt and phone observation becomes an event in
  `Store`, so a phone's problems can be debugged from the gateway alone. Events
  carry IDs, states, fingerprints and errors, never tokens or activity content.
- Boundaries decode into validated types: enums for states, UUIDs for ids,
  `PushToken`, `ActivityName` and `APIError.Code`. Invalid input fails at the
  decoder with a JSON path; stored rows that fail to parse throw rather than
  default.
- Mutable state has one owner: an actor, the main actor or a `Mutex` inside a
  `Sendable` class. Never silence isolation with `@unchecked Sendable` or
  `nonisolated(unsafe)`; pass identifiers, not ActivityKit handles, across
  tasks.

## Dependencies and style

`Core` has no dependencies. `Gateway` may depend only on packages from
`github.com/apple`, pinned to exact versions; CI enforces this. Prefer Apple
frameworks and adapt the design to them rather than adding packages. Use Swift
6 language mode, Swift Testing, and no code comments.

## Documentation

The Markdown files are as much a part of Lykta as the code. Update the README,
this file, `PRIVACY.md`, `docs/` and both skills in the same commit as the
change they describe, and fix stale text wherever you find it. When the app or
gateway changes what it stores or sends, update `PRIVACY.md` and tell the
maintainer, because the App Store privacy label must match.

## Commands

| Command | Use |
| --- | --- |
| `just test` | Core and gateway tests; CI runs them on Linux |
| `just ios` | Compile the app and widgets without signing |
| `just gateway` | Run the gateway locally with `LYKTA_*` settings |
| `just image` | Build the gateway container |
| `just render <inputs>` | Render request bodies or bare layouts (files, directories, inline JSON or `-`) through Xcode's previews: every presentation of every input as PNGs in `.local/renders`, plus `sheet.png` side by side to compare variants. Needs Xcode 27 with its MCP server enabled; leaves the project open in Xcode so later renders take about a second each. `--only lock,expanded` and `--dark` narrow it. Close the project in Xcode before removing a worktree that rendered. |

Device behavior, such as how a layout looks or whether a push arrives, needs a
run on an iPhone; compiling proves neither.

## Release

Push a version tag, such as `0.2.0`, on a commit that was pushed to `main`
and newer than every other version tag. `.github/workflows/release.yml` then
builds an unsigned archive with the tag as its version. It does not run the
tests again: it waits for `main`'s CI run on the same commit and stops unless
that run passed. It then uploads the archive to TestFlight through Xcode's
cloud signing with the `testflight` environment's App Store Connect key. App
Store Connect picks the build number. The GitHub release is
titled with the bare version, and its notes are the annotated tag's message
verbatim: a Markdown list of user-visible changes since the previous version,
one short sentence per item, with no heading or intro line. Submitting to App
Review stays manual, and App Store versions use manual release, so the
maintainer decides when an approved version goes live.

The App Store screenshots are four 1206 × 2622 slides, the required 6.3-inch
iPhone size. Capture them from a Debug build on an iPhone 18 Pro simulator:
tap Copy Agent Setup, start the fixture activities with
`LYKTA_URL=… LYKTA_TOKEN=… python3 AppStore/activities.py --quiet`, and capture
with `xcrun simctl io <device> screenshot --mask=black`, because the Dynamic
Island is missing without a mask. Name the captures `1-lock`, `2-compact`,
`3-expanded` and `4-app`, compose them with
`swift AppStore/compose.swift <captures> <slides>`, which also holds the
captions, and flatten each slide with
`magick <slide> -background black -alpha remove -alpha off PNG24:<slide>`.
Tap Reset in the app afterwards to delete the simulator from the gateway.

Self-hosters build the gateway image from a tagged commit and the app from
Xcode with their own `Config/Local.xcconfig`. Gateway state lives in SQLite,
so replacing the container is safe. It drops in-flight HTTP requests, and
in-flight starts become `unknown`.
