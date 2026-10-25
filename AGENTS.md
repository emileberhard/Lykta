# Lykta

Lykta shows server-defined native Live Activities and notifications on
iPhone. Agents send JSON to a self-hosted gateway, which validates it and
delivers it over APNs. Read the [architecture record](docs/architecture.md) before changing a
boundary below. `CLAUDE.md` is a symlink to this file.

## Ownership

| Path | Owns |
| --- | --- |
| `Core` | Layout language, templates, `ContentState` wire format and device API types; no dependencies |
| `iOS` | The Xcode project, its `Config` and everything only the iPhone app ships |
| `iOS/Rendering` | SwiftUI for every node and modifier, the Lock Screen view and the tap intents; both the app and the widget extension compile it, and `LYKTA_APP` marks the app's variants |
| `iOS/Widgets` | The Live Activity configuration and Dynamic Island presentations |
| `iOS/App` | Registration, Keychain credentials, ActivityKit observation, notification permission and token, device reports and telemetry, the in-app Lock Screen cards and the example gallery |
| `iOS/Notifications` | The notification service extension: media downloads and the phone's media cache in the app group, the communication notification and the report to the gateway |
| `iOS/Avatars` | The initials avatar for a sender without a picture, drawn by both the extension and the app's gallery |
| `iOS/App/AppIcon.icon` | The final app icon, three overlapping lights; change it only when the maintainer asks |
| `Gateway` | HTTP API, `Store` (all durable state) and its `Schema`, delivery and APNs |
| `Gateway/Sources/LyktaGateway/Skill` | The agent skill the gateway serves; `.agents/skills/lykta` links to it |
| `.agents/skills/self-host` | Setting up a gateway and app build |
| `scripts/screenshots`, `iOS/AppStore/compose.swift`, `iOS/App/Capture.swift` | The App Store slides: the script that captures the Debug app on a simulator, caches the captures by the files that draw them and composes the slides, the composer, and the capture mode, which renders the bundled examples and the home screen |
| `scripts/render`, `iOS/Widgets/RenderPreviews.swift` | The render tool and the preview it drives, which shows the layouts staged in `.local/render` |
| `evals`, `scripts/eval-metrics` | The [agent runner](docs/evals.md): Harbor tasks that give a fresh agent the app's setup paste and one request, against `lykta-gateway simulate`, the binary checks that read its gateway afterwards and the script that sums up each job's tokens and timings |

## Invariants

- A layout change touches `Core`, `Rendering` and the skill's `layout.md`
  together. Gateway tests compile every JSON example in `layout.md`, start
  every activity in the skill's `examples` and send every notification in
  `examples/notifications`. Look at a layout change with
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
- Admission measures both of Apple's 4 KB limits, the APNs payload and the
  activity's attributes plus content, for the push of the current phase and
  the end push, in the form the phone receives: pushes as the previous release
  encodes them, attributes and content with Foundation's slash escaping. Every
  accepted activity can therefore still end after a gateway rollback. `payloadBytes` reports that
  measurement only in PUT responses; reads never compress.
- Phones reporting layout version 0.8.0 or later get compact content, framed
  with the legacy fingerprint and deflated with `WireDictionary.v1`; the
  gateway stores the legacy form. Released forms and dictionaries never change:
  a new one takes a new prefix, and phones keep reading every released form.
- Rendering is bounded and offline: layouts stay within the `Layout` budgets,
  the widget makes no network requests, and view bodies never parse JSON.
- The app bundles the skill's `examples` folder, and its gallery draws and
  sends exactly those files, so every example must render in the app built
  from the same commit. A notification example names its media files, kept
  beside it, where the ids go. File names are unique across the skill, because
  the gateway embeds them under flattened names. Example times stay within two days of 1793000000;
  Core's `movingExampleTimes` moves them to the present for the gallery and
  `just render`.
- The gateway is the only content writer. The app never calls
  `Activity.request`, updates content or schedules local notifications; it
  ends an activity only when the gateway reports it ended, or on Reset.
- A tap changes data only through the gateway, in the transaction that logs
  it: a toggle sets its boolean and a button applies its `set`, `add` and
  `now`, all read from the data before the tap. A tap counts only for a
  control the current data shows, and a result that fails to fill, fit or
  pass the phone's decoder version changes nothing.
- Unknown stays unknown. A start or notification with an unknown outcome is
  never sent again. A missing report never ends an activity, except when the
  activity is absent from the first report of a new app install or update.
- A push token goes to the APNs environment that accepted it, starting with
  the one its phone registered with, and only `BadDeviceToken` moves it, once,
  to the other environment. An activity's updates go to its channel's
  environment.
- Stored layout templates are expanded: `parts` and node `use` never reach
  database layouts or the phone. Expand before filling, with copy-paste scope,
  and bound expansion while copying by `Layout.maximumNodes`. `Parts` expands
  only the node positions `Layout` decodes, so a new node-valued key joins it
  in the same change.
- `Store` commits every state change in one transaction. Ending fences later
  updates, updates coalesce to the latest revision, and starts and ends are
  never dropped.
- Migrations are additive, so the previous release runs on the new schema and
  a rollback needs no restore. Bump `Schema.version` only for a change the
  previous release cannot read; older gateways then refuse to start.
- Never run a second gateway with another gateway's APNs keys, even briefly:
  its channel cleanup deletes every channel its own database does not know.
- `lykta-gateway simulate` keeps its store in memory and pushes to
  `SimulatedPhone`, never to APNs. `evals/prompt.md` is the app's Copy Agent
  Setup paste for that phone, so change it with `copySetup()` in `Model.swift`.
- A phone registers only with a verified App Attest attestation of a new key
  over a challenge this gateway signed, or with a one-time invite an operator
  created. Never add a registration path without such proof.
- Tokens are stored only as hashes. Never log tokens, push tokens or payloads.
- The notification extension talks only to its own gateway, with the fetch
  token its push carries, and follows no redirect. A fetch token is created
  when a notification is claimed for sending and authorizes only that
  notification's device routes, its report and the media it names, until the
  notification expires; the extension never holds the device secret.
- Media belongs to the phone that uploaded it: a notification may name only
  its own phone's media, of the kind its field expects, and `Store` removes a
  file a day after its last upload or reference, never sooner, within the
  per-phone cap.
- Every state change, push attempt and phone observation becomes an event in
  `Store`, so a phone's problems can be debugged from the gateway alone. Events
  carry IDs, states, fingerprints and errors, never tokens, activity or
  notification content, or media.
- Boundaries decode into validated types: enums for states, UUIDs for ids,
  `PushToken`, `Name` and `APIError.Code`. Invalid input fails at the
  decoder with a JSON path; stored rows that fail to parse throw rather than
  default.
- Mutable state has one owner: an actor, the main actor or a `Mutex` inside a
  `Sendable` class. Never silence isolation with `@unchecked Sendable` or
  `nonisolated(unsafe)`; pass identifiers, not ActivityKit handles, across
  tasks.

## Code design

- Delete before adding. Each layout key, API field and `LYKTA_*` setting is a
  contract with agents, installed phones and self-hosters, so reuse or extend
  what exists and remove what a change makes redundant in the same commit.
  Declarations stay `private` unless another file needs them, and every
  parameter, option, setting and endpoint has a current caller.
- Values in, values out. `Core` reads no clock, file or network, and logic that
  depends on time takes it as `now` or `at:` so tests choose it. I/O stays in
  the types that own it, such as `Store`, `APNs`, `GatewayClient` and
  `EventQueue`.
- Alternatives are enums with associated values, as `Outcome` and
  `Model.Phase` are, not flags and optionals that allow contradictions.
- Failures are explicit. An error an agent, phone or operator sees says what to
  change, with a code or JSON path. `preconditionFailure` is for a broken
  internal guarantee, never for input from a phone, an agent or the network.
  Use `try?` only where `nil` is the meaning, such as trying another value form
  while decoding, or where nobody could act on the error, such as a client
  that drops its connection, and never return a default that hides a failure.
- One path. Compatibility lives where the wire needs it: `Layout.introduced`,
  additive migrations and the device API. Inside, replace rather than wrap:
  delete superseded code in the same change and add no flag, alias, fallback or
  extension point for a future need. A protocol needs a second conformer
  today, as `PushService` has `FakePush`.
- Test behavior at a boundary that can catch a plausible defect: gateway tests
  drive `API.handle` against an in-memory `Store` and `FakePush`, and Core
  tests decode real JSON and assert the exact message and path. Name each test
  for what it proves, use `@Test(arguments:)` for cases of one rule, and don't
  test private helpers or restate the implementation.

## Swift and SwiftUI

- The app and extension targets default to main-actor isolation with approachable
  concurrency, so their code, async functions included, runs on the main actor
  unless marked. Move work off it with a `nonisolated` type and a `@concurrent`
  function, as `Example.bundled` does, never with `Task.detached`.
- Prefer task groups, and `.task(id:)` in views, which SwiftUI cancels with
  the view. Start an unstructured `Task` only at a synchronous UI or lifecycle
  boundary, and store one that outlives its action, like `Model.runTask`, so
  its owner can cancel it. Code runs uninterrupted only between `await`s, so
  recheck what the next step relies on, as `Model.sync` rechecks the
  credentials on a 401.
- The notification extension is `nonisolated` and prepares each notification
  on the thread iOS calls it on, because its content handler is not `Sendable`
  and cannot move into a task. Every wait there, the media downloads, the
  donation and the report, is bounded so the notification arrives within
  iOS's budget.
- A tap intent may run right after the system launches the app in the
  background for it, so intents only forward the action through `ActionSender`,
  which `LyktaApp.init` registers; register new intent dependencies there too.
- `Rendering` runs in the widget extension for every presentation of every
  update, so `Core` parses and derives while decoding and node views only map
  values onto concrete SwiftUI views. Type erasure stays in `NodeView`'s
  modifier fold, whose types are known only at runtime, because `AnyView`
  rebuilds its subtree whenever the wrapped type changes. Child nodes are
  identified by position, since a layout names them only through the `id`
  modifier; app lists use their elements' IDs.
- The widget extension is not running while an activity shows, so anything
  that changes with time uses views the system keeps current, such as
  `Text(timerInterval:)` and `ProgressView(timerInterval:)`; only the app
  (`LYKTA_APP`) runs a `TimelineView`.
- `Model` is the app's one `@Observable` owner. Views take it as a plain `let`,
  change it only through its methods and hand leaf views the values they draw,
  since SwiftUI redraws a view when a model property its `body` reads changes.
- App screens explain themselves through system controls, layout and visible
  state; add copy only where the user would miss a consequence, as the Reset
  confirmation does. Text follows Dynamic Type, capped only to match the Lock
  Screen (`LockScreenCard.textSizes`) or to keep a control small with
  `accessibilityShowsLargeContentViewer()`. Custom drawings carry an
  accessibility label or are hidden.

## Dependencies and style

`Core` has no dependencies. `Gateway` may depend only on packages from
`github.com/apple`, pinned to exact versions; CI enforces this. Prefer Apple
frameworks and adapt the design to them rather than adding packages. `Core` and
`Gateway` also build on Linux, where CI tests them, so import
platform-specific modules behind `#if canImport`, as `APNs.swift` does for
`CryptoKit` and `FoundationNetworking`. Use Swift 6 language mode, Swift
Testing, and no code comments.

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
| `just ios` | Compile the app and its extensions without signing |
| `just gateway` | Run the gateway locally with `LYKTA_*` settings |
| `just image` | Build the gateway container |
| `just evals <options>` | Run the fresh agents in `evals/job.yaml`, twice each, on every task in `evals/tasks` against a simulated phone and check each trial; options go to `harbor run` and override the job, such as `--include-task-name train` or `--agent codex --model gpt-6.1-sol`, and `~/.config/lykta/evals.env` sets endpoints and keys. Transcripts, rewards and the gateway's events land in `.local/evals`, and the run ends with each agent's tokens and timings from `scripts/eval-metrics`; read the trials with `harbor view .local/evals` |
| `just render <inputs>` | Render request bodies or bare layouts (files, directories, inline JSON or `-`) through Xcode's previews: every presentation of every input as PNGs in `.local/renders`, plus `sheet.png` side by side to compare variants. Needs Xcode 27 with its MCP server enabled; leaves the project open in Xcode so later renders take about a second each. `--only lock,expanded` and `--dark` narrow it. Close the project in Xcode before removing a worktree that rendered. |
| `just screenshots` | Compose the App Store slides into `.local/screenshots`. Captures of the app are cached in `~/Library/Caches/lykta/captures`, shared by every checkout and keyed by the files that draw them, Xcode and the simulator, so only a UI change builds and launches the app again |

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
2. Meanwhile `testflight` builds an archive with the tag as its version on a
   hosted runner without certificates and signs its bundles ad hoc with their
   entitlements files, because the export keeps only the capabilities the
   archive's signatures request. A target that gains an entitlements file
   joins `ENTITLED` in the workflow.
3. The production gateway's host polls for admitted tags and deploys them
   itself, with a database backup and an automatic rollback.
4. Once `https://$LYKTA_GATEWAY_HOST/v1/version` reports the tag, `testflight`
   exports the archive through Xcode's cloud signing with the `testflight`
   environment's App Store Connect key, fails unless every bundle in `ENTITLED`
   claims its entitlements file with the production push environment, and then
   uploads it. App Store Connect picks the build number.
5. The GitHub release is titled with the bare version, and its notes are the
   annotated tag's message verbatim: a Markdown list of user-visible changes
   since the previous version, one short sentence per item, with no heading or
   intro line.

Submitting to App Review stays manual, and App Store versions use manual
release, so the maintainer decides when an approved version goes live.

The App Store screenshots are five 1206 × 2622 slides, the required 6.3-inch
iPhone size, drawn by `just screenshots`. In capture mode, which
`LYKTA_CAPTURE` turns on in Debug builds, the app renders every bundled
example's Lock Screen card and islands and its home screen as PNGs and exits;
`iOS/AppStore/compose.swift` holds the captions and arranges the captures into
opaque slides, as App Store Connect requires. Look at the slides after a change
to the app's UI or the examples, because the release uploads them.

Self-hosters build the gateway image from a tagged commit, passing the tag as
`--build-arg LYKTA_VERSION`, and the app from Xcode with their own
`iOS/Config/Local.xcconfig`. Gateway state lives in SQLite, so replacing the
container is safe. On SIGTERM the gateway stops claiming pushes and starts no
further request for a claimed one, finishes the requests in flight within
APNs' 15-second timeout while still accepting API requests, then closes its
listener after at most five more seconds; give the container a stop grace
period of 30 seconds.
