# Lykta

Lykta shows server-defined native Live Activities, widgets and notifications
on iPhone. Agents send JSON to a self-hosted gateway, which validates it and
delivers it over APNs. Read the [architecture record](docs/architecture.md) before changing a
boundary below. `CLAUDE.md` is a symlink to this file.

## Ownership

| Path | Owns |
| --- | --- |
| `Core` | Layout language, templates, `ContentState` wire format and device API types; no dependencies |
| `iOS` | The Xcode project, its `Config` and everything only the iPhone app ships |
| `iOS/Rendering` | SwiftUI for every node and modifier, the Lock Screen view, the widget view and the tap intents; the app, widget extension, notification extension and `LyktaRender` compile it, the last for Mac Catalyst, where ActivityKit's environment values do not exist, and `LYKTA_APP` marks app-only live timers; `LYKTA_WIDGET` selects widget-native circular progress, while the app and notification extension draw a determinate ring |
| `iOS/Widgets` | The Live Activity configuration and Dynamic Island presentations, and the Lykta widget: its timeline provider, the states it draws and its push handler |
| `iOS/Gateway` | The phone's link to its gateway, compiled into the app and the widget extension: `GatewayClient`, the Keychain items, among them the widget credential, the widget's `WidgetSelection` intent with its entity query, and `WidgetCache` |
| `iOS/Previews` | The gallery's Lock Screen card, Dynamic Island, widget and notification banner previews, which the app and `LyktaRender` share |
| `iOS/App` | Registration, ActivityKit observation, the widget credential and places report, notification permission and token, device reports and telemetry, the first-launch introduction that waits for the agent's hello, the in-app Lock Screen cards' headers and details sheet, and the example gallery with its hint to lock the phone after each start |
| `iOS/Notifications` | The notification service extension: media downloads and the phone's media cache in the app group, the communication notification and the report to the gateway |
| `iOS/Avatars` | The extension-only bounded drawn avatar and the independent Core Graphics initials shared by the extension and app gallery |
| `iOS/App/AppIcon.icon` | The final app icon, three overlapping lights; change it only when the maintainer asks |
| `Gateway` | HTTP API, `Store` (all durable state) and its `Schema`, delivery and APNs, and `RenderQueue`, which hands agents' previews to a render worker in memory |
| `Gateway/Sources/LyktaGateway/Skill` | The agent skill the gateway serves; `.agents/skills/lykta` links to it |
| `Gateway/Sources/LyktaGateway/Skill/scripts`, `scripts/check-cli` | The `lykta` command agents send with, as `lykta` for sh with curl and its PowerShell twin `lykta.ps1`, the `hello.json` activity its setup starts, and the check that runs both against `lykta-gateway simulate` |
| `.agents/skills/self-host` | Setting up a gateway and app build |
| `scripts/screenshots`, `iOS/AppStore/compose.swift`, `iOS/AppStore/cards`, `iOS/App/Capture.swift` | The App Store slides: the script that captures the Debug app on a simulator, caches the captures by the files that draw them and composes the slides, the composer, the cards the slides show, and the capture mode, which renders those cards' Lock Screen views, widgets and notification avatars |
| `scripts/app-store-connect` | Taking a release's build through App Store Connect: What to Test and TestFlight review for the external groups, then the App Store version's version string, What's New, screenshots, build and App Review submission |
| `.xcode-version`, `scripts/select-xcode` | The Xcode version CI and releases require |
| `iOS/Config/entitlements.json`, `scripts/sign-bundles` | The entitlements every shipping bundle claims before export and must retain afterwards |
| `scripts/render`, `iOS/Render`, `iOS/Widgets/RenderPreviews.swift` | The render tool; its engine, `LyktaRender`, a Mac Catalyst app that draws requests through `iOS/Previews` and answers on its standard output; its `--worker` mode, which draws the gateway's previews; and the activity and widget previews it drives with `--xcode`, which show the layouts staged in `.local/render` |
| `deploy/mac-render` | The LaunchAgent that keeps a render worker running on a Mac from the release its gateway runs |
| `evals`, `scripts/eval-metrics` | The [agent runner](docs/evals.md): Harbor tasks that give a fresh agent the app's setup paste and one request, against `lykta-gateway simulate`, the binary checks that read its gateway afterwards and the script that sums up each job's tokens and timings |

## Invariants

- A layout change touches `Core`, `Rendering` and the skill's `layout.md`
  together. Gateway tests compile every JSON example in `layout.md`, start
  every activity in the skill's `examples`, send every notification in
  `examples/notifications` and put every widget in `examples/widgets`, and
  do the same for the App Store cards in `iOS/AppStore/cards`. Look at a layout change with
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
- Rendering is bounded: layouts stay within the `Layout` budgets, and views
  never fetch or parse JSON. Only the Lykta widget's timeline provider, its
  entity query and its push handler call the gateway, each with a bounded
  wait; the Live Activity makes no network requests.
- A widget push is a coalesced invalidation: a change raises the phone's
  generation only when a place shows the widget or the phone's places are
  unknown, and the gateway sends at most one push per phone per
  `Store.widgetPushInterval`, counting pushes with an unknown outcome. It
  carries no content, so retrying it is safe.
- The widget credential reads only its own phone's widgets and sends their
  report; the widget extension never holds the device secret. `WidgetCache`,
  under its file lock, is the only owner of cached widget answers. It belongs
  to one widget credential and records an answer only while that credential is
  current, and only 410 `widget_deleted`, a 401, a new credential, Reset and
  its 64-entry limit remove cached content. Widget reports apply in the order
  of a `sequence` the app and extension share under that lock, and only
  fetched content the phone can draw counts as `fetched`.
- The app bundles the skill's `examples` folder, and its gallery draws and
  sends exactly those files, so every example must render in the app built
  from the same commit. A notification example names its media files, kept
  beside it, where the ids go. File names are unique across the skill, because
  the gateway embeds them under flattened names. Example times stay within two days of 1793000000;
  Core's `movingExampleTimes` moves them to the present for the gallery and
  `just render`. The App Store cards in `iOS/AppStore/cards` keep the same
  folder layout and time window; a card joins the skill's `examples` only
  when it teaches a technique the examples lack.
- The gateway is the only content writer. The app never calls
  `Activity.request`, updates content or schedules local notifications; it
  ends an activity only when the gateway reports it ended, or on Reset. The
  gateway's answer to End Activity, which names the activity by its id, is
  such a report.
- An activity or widget tap changes data only through the gateway, in the
  transaction that logs it: a toggle sets its boolean and a button applies its
  `set`, `add` and `now`, all read from the data before the tap. A tap counts
  only for a control the current data shows, and a result that fails to fill,
  fit or pass the phone's decoder version changes nothing. Widget and activity
  taps share one log and cursor per phone, and each names exactly one target.
- Unknown stays unknown. A start or notification with an unknown outcome is
  never sent again. A missing report never ends an activity, except when the
  activity is absent from the first report of a new app install or update.
- A push token goes to the APNs environment that accepted it, starting with
  the one its phone registered with, and only `BadDeviceToken` moves it, once,
  to the other environment. An activity's updates go to its channel's
  environment.
- Stored layout templates are expanded: `parts` and node `use` never reach
  database layouts or the phone. Expand before filling, with copy-paste scope and errors at authored use sites,
  and bound expansion while copying by `Layout.maximumNodes`. `Parts` expands
  only the node positions `Layout` decodes, so a new node-valued key joins it
  in the same change.
- Saved parts belong to one phone, with at most 64 names. Saving expands
  saved references into snapshots, and activity and widget PUTs expand once
  inside the store transaction before filling, validating and storing the
  snapshot. Body parts shadow saved parts; only body parts must be used.
  Data-only updates and taps use stored snapshots without library reads.
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
- Agents pay most for what they write and for each tool call, not for what
  they read. Keep each step of the skill's sending path to one `lykta`
  command, fold steps agents would chain into the gateway or `lykta`, as the
  waiting PUT, `now` and `media` do, and spend input, such as longer docs or
  fuller answers, to save output or a call.
- `lykta` and `lykta.ps1` are one contract: the same commands, output, exit
  codes and setup in `~/.config/lykta`, so change both in one commit and
  extend `scripts/check-cli` with them. They need only sh with curl, or
  PowerShell 5.1 or later, never print the token, and retry only a refused
  connection, because only that proves a request was never sent. `lykta`
  writes only its own installed file, the SKILL.md of folders
  `lykta install` created and the `.render.png` that `lykta render` names
  after its body file, each through a temporary file it creates exclusively
  and one rename, and replaces a skill file only when it ends with its
  `lykta-skill` line. It refuses a symlinked skill folder, updates only from the gateway
  setup saved, and never lets a failed update change a command's result.
- A render stores and pushes nothing. `POST /v1/render/...` admits its body
  through the same `Store` preparation as the PUT it previews, saved parts,
  `now` and version checks included, and `RenderQueue` keeps its job and
  image only in memory, the image for ten minutes and only for its own phone.
  Only the worker token, whose hash `LYKTA_RENDER_TOKEN_SHA256` holds, claims
  and answers jobs, and the worker reaches the gateway, never the reverse.
- A phone registers only with a verified App Attest attestation of a new key
  over a challenge this gateway signed, or with a one-time invite an operator
  created. Never add a registration path without such proof.
- Tokens are stored only as hashes. Never log tokens, push tokens or payloads.
- Drawn notification avatars store expanded nodes under `sender.drawing`,
  never the media-id key `sender.avatar`. Their push uses `drawing`, a
  `PackedNode` with the frozen `~1` frame shared with compact activity content.
  Report bodies and stored phone reports retain `image` and `initials`;
  `avatarFailure` travels only in the report query and the received event;
  unknown diagnostic values never discard a report. Core admits still nodes
  once at PUT, with authored saved-part origins and a dedicated avatar
  presentation. An exhaustive walk classifies typed content and modifiers.
  Delivery packs stored nodes without decoding or admission, so content from
  a newer gateway survives rollback.
- The notification extension draws a node once in a 64 × 64 pt viewport at
  scale 4, with a two-second main-actor deadline and no measuring render.
  `AvatarView` owns the viewport and pins light color scheme, body font and
  default text size for both extension rendering and the gallery.
  One lock owns the completion handler and best content; expiry delivers
  that content once and late results cannot deliver it again. Every media,
  rendering, donation and reporting wait is bounded. Initials stay independent.
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
  `Sendable` class; the non-Sendable notification extension owns its pending
  content handler under the lock shared with system expiry. Never silence
  isolation with `@unchecked Sendable` or
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
  and cannot move into a task. The extension instance owns its pending content
  and handler under a lock shared with `serviceExtensionTimeWillExpire`, takes
  the handler out before calling it exactly once, and never renders under that
  lock. Every wait there, the media downloads, the
  donation and the report, is bounded so the notification arrives within
  iOS's budget.
- A tap intent may run right after the system launches the app in the
  background for it, so intents only forward the action through `ActionSender`,
  which `LyktaApp.init` registers; register new intent dependencies there too.
  Intent titles and descriptions never name an Apple product such as iPhone,
  because App Store Connect rejects such a build after upload (ITMS-90626).
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
| `just test` | Core and gateway tests, then `scripts/check-cli` with sh and PowerShell; CI runs them on Linux |
| `just ios` | Compile the app and its extensions, and `LyktaRender` for Mac Catalyst, without signing |
| `just gateway` | Run the gateway locally with `LYKTA_*` settings |
| `just image` | Build the gateway container |
| `just evals <options>` | Run the fresh agents in `evals/job.yaml`, twice each, on every task in `evals/tasks` against a simulated phone and check each trial; options go to `harbor run` and override the job, such as `--include-task-name train` or `--agent codex --model gpt-6.1-sol`, and `~/.config/lykta/evals.env` sets endpoints and keys. Transcripts, rewards and the gateway's events land in `.local/evals`, and the run ends with each agent's tokens and timings from `scripts/eval-metrics`; read the trials with `harbor view .local/evals` |
| `just render <inputs>` | Render activity, widget or notification request bodies or bare layouts (files, directories, inline JSON or `-`; a notification's media ids name files beside it): every presentation of every input as PNGs in `.local/renders`, plus `sheet.png` side by side to compare variants. The engine renders a request of many inputs in about a second through `LyktaRender`, a hidden Mac app it keeps running. Each checkout runs its own engine in `.local/engine`; it builds the app after a Swift change in seconds, the first time in about a minute, and stops after ten idle minutes or with `--stop`. It draws the gallery's views at an iPhone's width and scale, so sizes match Xcode's previews within a few points, but Mac Catalyst sets text about 2% wider, so text that fits there fits on a phone; Lock Screen tints are exact rather than lightened, accessory widgets are grayscale rather than vibrant and circular progress is the app's ring. It needs the logged-in Mac session, not SSH alone. `--xcode` renders through Xcode's previews at seconds per image, and is the only way to draw `standby` and `smartstack`; it needs Xcode 27 with its MCP server enabled and leaves the project open in Xcode, so close it there before removing a worktree that rendered. `--only lock,expanded,small,circular` and `--dark` narrow either. Neither draws the tinted Home Screen, so check `accented` on a phone. |
| `just screenshots` | Compose the App Store slides into `.local/screenshots`. Captures of the app are cached in `~/Library/Caches/lykta/captures`, shared by every checkout and keyed by the sources that draw them, Xcode and the simulator, so only a change to what they show builds and launches the app again |

Device behavior, such as how a layout looks or whether a push arrives, needs a
run on an iPhone; compiling proves neither.

## Release

Choose the version by what older installs can still do. A patch only fixes
behavior; layouts and the API accept exactly what they did. A minor adds
something, such as a layout feature or an API field, that older phones and
agents may lack but nothing existing breaks. A major removes or changes
something existing layouts, agents, phones or self-hosted gateways rely on. A
release that adds a layout feature is therefore at least a minor.

Push an annotated version tag, such as `0.2.0`, with nonempty release notes on
a commit that was pushed to `main`; `.github/workflows/release.yml` runs on
every tag and rejects invalid ones before credentials become available. It
does the rest, gateway first:

1. `admit` checks that the tag is annotated plain SemVer, has release notes,
   is the newest version and is on `main`, runs
   `scripts/check-feature-table` (rows newer than the previous release must
   equal the tag, which must then be `X.Y.0`) and waits for `main`'s CI run on
   the same commit, without running the tests again. Missing CI fails after
   two minutes; running CI has a 35-minute bound.
2. After admission, `numbers` reserves a build number higher than every build
   and pending upload. After the gateway job succeeds, the serialized
   `testflight` job uploads a new build
   at or above it, beside any older build of the same version. If an earlier
   attempt started the separate `Upload to TestFlight` step, it waits up to
   15 minutes for that attempt's build at or above the reservation, then fails
   rather than upload again; that build skips archiving, signing and uploading. A new one builds
   an archive with the tag as its version and that exact build number on a
   hosted runner without certificates. `scripts/sign-bundles` signs embedded
   frameworks deepest first, then every bundle ad hoc with the entitlements
   in `iOS/Config/entitlements.json`,
   because the export keeps only the capabilities the archive's signatures
   request. The map must cover exactly the app and both extensions.
3. The GitHub-hosted `gateway` job builds the admitted tag, attests its binary,
   attaches both to a draft GitHub prerelease and then publishes it, because
   the repository's releases are immutable: a published release takes no new
   assets and its tag can never be reused. The VPS pulls the highest release
   with both assets, verifies the exact tagged workflow identity and digest,
   and deploys with a database backup and schema-safe rollback. The job reports
   `lykta-gateway/<version>` on the admitted commit and waits for public health.
4. `scripts/wait-for-gateway` checks both that result and the public endpoint.
   A reported failure stops immediately; a missing receipt or a completed
   deploy without a compatible public version fails after about a minute.
   A pending deploy has a 30-minute bound. Only once
   `https://$LYKTA_GATEWAY_HOST/v1/version` reports the tag or newer, `testflight`
   exports the archive through Xcode's cloud signing with the `testflight`
   environment's App Store Connect key without renumbering, fails unless every
   mapped bundle claims its entitlements file with the production push
   environment and every framework has an Apple Distribution signature, then
   uploads it. Both following App Store Connect jobs
   receive that build number and select only that upload, including on retries.
5. After TestFlight succeeds the GitHub prerelease becomes a full release,
   titled with the bare version, and its notes are the
   annotated tag's message verbatim: a Markdown list of user-visible changes
   since the previous version, one short sentence per item, with no heading or
   intro line. It is marked Latest only while its tag is the newest version.
6. After the upload, `testflight-review` runs `scripts/app-store-connect
   testflight`. Once App Store Connect has processed the build, it sets the
   build's What to Test to the tag message, copies the newest App Store
   version's review notes to TestFlight's, adds the build to every external
   group, such as the public link's, and submits it for TestFlight review.
   Without an external group it stops after setting What to Test.
   When App Store Connect rejects the upload, it fails with Apple's errors.
7. Alongside it, `app-store` composes the screenshots and runs
   `scripts/app-store-connect app-store`. Once the build is processed, it
   removes an older version waiting for or in App Review from review, renames
   the App Store version that is still editable to the tag or creates one,
   with manual release, sets What's New to the tag message,
   replaces the iPhone screenshots, deletes only the unplaced images this
   release displaced or reserved, except those App Review has seen, which
   Apple keeps, attaches the build and submits the version for App Review,
   resolving its rejected item. A rerun resumes a draft that already carries
   the tag and build. When the tag's own version is already in review, or a
   version waits for release, this job succeeds with a notice and leaves that
   version alone.

CI and releases select the Xcode pinned in `.xcode-version`; builds use only
committed package resolutions. CI also checks the release tools on Linux.
Rerun a transiently failed job from the tag's own run only while it is still
the newest version. A code fix ships as the next patch, never by moving a tag.

## VPS gateway and host watchdog

The VPS deployment places the production gateway and its dedicated tunnel on
`llm-router-hostup` as separate systemd services, accounts and credentials
from llm-router. The repository's `deploy/vps` owns installation and attested
release pull.
Its backup destination must preserve the 14-day deletion promise in `PRIVACY.md`;
the indefinitely locked service-state repository cannot do so. Never run another
gateway with these APNs keys, including a candidate or rollback copy. Fence and
drain the writer before moving its state, and copy newer state back before a
rollback to another host.

`~/configs/services/host-watchdog` owns the VPS watchdog and the independent
Mini and Linux heartbeats. It uses the local gateway to alert when a host goes
silent. A Lykta or VPS outage silences alerts; this is an accepted risk. APNs
keys, the tunnel credential, backup credentials and the watchdog's Lykta token
are untracked and have recovery sources outside the VPS.

The App Store screenshots are five 1206 × 2622 slides, the required 6.3-inch
iPhone size, drawn by `just screenshots`. The script copies
`iOS/AppStore/cards` into the capture. In capture mode, which
`LYKTA_CAPTURE` turns on in Debug builds, the app renders each card's Lock
Screen view, each widget family and each notification avatar as PNGs, in US
English with the clock at 9:41 like the composed Lock Screen, and exits.
`iOS/AppStore/compose.swift` holds each slide's request and reply, draws its
own wallpaper, because the release's fresh simulator never draws one and
Apple's must not be committed to this public repository, and arranges the
captures into opaque slides, as App Store Connect requires. Its rings are
measured on these captures, so measure them again when a ringed card or
`Rendering` moves what they frame. An empty `ImageRenderer` result
comes out transparent or as the previous slide's pixels, so the composer stops
on a slide with a transparent pixel or an earlier slide's exact pixels instead
of writing it. Look at the slides after a change to `Rendering`, the cards or
the composer, because the release uploads them.

Self-hosters build the gateway image from a tagged commit, passing the tag as
`--build-arg LYKTA_VERSION`, and the app from Xcode with their own
`iOS/Config/Local.xcconfig`. Gateway state lives in SQLite, so replacing the
container is safe. On SIGTERM the gateway stops claiming pushes and starts no
further request for a claimed one, finishes the requests in flight within
APNs' 15-second timeout while still accepting API requests, then closes its
listener after at most five more seconds; give the container a stop grace
period of 30 seconds.
