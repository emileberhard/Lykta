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
- Every layout feature (node, key, enum case and value form the decoder
  accepts) is recorded while decoding and has a row, by exact name, in
  `Layout.introduced` with the release that first drew it. A new feature gets a
  row with the next minor version; released rows never change, and release
  admission enforces both. Decode enum values through `Choice` or record them
  with `Choice.record`, and mark a new value form explicitly; a feature that is
  never recorded is never gated. Enum type names are part of feature names, so
  renaming one fails release admission. SVG markup counts as the single feature
  `svg`; when the SVG subset grows, record its new elements and attributes. The
  gateway refuses a layout with `app_update_required` when the phone's reported
  layout version predates a feature in it; never let such a layout through.
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
- Migrations are additive, so the previous release runs on the new schema and
  a rollback needs no restore. Bump `Store.schemaVersion` only for a change the
  previous release cannot read; older gateways then refuse to start.
- Never run a second gateway with another gateway's APNs keys, even briefly:
  its channel cleanup deletes every channel its own database does not know.
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

Choose the version by what older installs can still do. A patch only fixes
behavior; layouts and the API accept exactly what they did. A minor adds
something, such as a layout feature or an API field, that older phones and
agents may lack but nothing existing breaks. A major removes or changes
something existing layouts, agents, phones or self-hosted gateways rely on. A
release that adds a layout feature is therefore at least a minor.

Push a version tag, such as `0.2.0`, on a commit that was pushed to `main`;
`.github/workflows/release.yml` does the rest, gateway first:

1. `admit` checks that the tag is the newest version and on `main`, runs
   `scripts/check-feature-table` (rows newer than the previous release must
   equal the tag, which must then be `X.Y.0`) and waits for `main`'s CI run on
   the same commit, without running the tests again.
2. Meanwhile `testflight` builds an unsigned archive with the tag as its
   version.
3. The production gateway's Mini polls for admitted tags and deploys them
   itself (`~/configs/services/lykta-gateway`), with a database backup and an
   automatic rollback.
4. Once `https://$LYKTA_GATEWAY_HOST/v1/version` reports the tag, `testflight`
   uploads the archive through Xcode's cloud signing with the `testflight`
   environment's App Store Connect key. App Store Connect picks the build
   number.
5. The GitHub release is titled with the bare version, and its notes are the
   annotated tag's message verbatim: a Markdown list of user-visible changes
   since the previous version, one short sentence per item, with no heading or
   intro line.

Submitting to App Review stays manual, and App Store versions use manual
release, so the maintainer decides when an approved version goes live.

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

Self-hosters build the gateway image from a tagged commit, passing the tag as
`--build-arg LYKTA_VERSION`, and the app from Xcode with their own
`Config/Local.xcconfig`. Gateway state lives in SQLite, so replacing the
container is safe. On SIGTERM the gateway stops claiming pushes, finishes those
in flight within APNs' 15-second timeout while still accepting requests, then
closes its listener; give the container a stop grace period of 30 seconds.
