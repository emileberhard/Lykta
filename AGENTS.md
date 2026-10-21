# Lykta

Lykta shows server-defined native Live Activities on iPhone. Agents send JSON
layouts to a self-hosted gateway, which validates them and delivers them over
APNs. Read the [architecture record](docs/architecture.md) before changing a
boundary below. `CLAUDE.md` is a symlink to this file.

## Ownership

| Path | Owns |
| --- | --- |
| `Core` | Layout language, templates, `ContentState` wire format and device API types; no dependencies |
| `Widgets` | Rendering every node and modifier as SwiftUI, and the Live Activity presentations |
| `App` | Registration, Keychain credentials, ActivityKit observation and device reports |
| `Gateway` | HTTP API, `Store` (all durable state), delivery and APNs |
| `Gateway/Sources/LyktaGateway/Skill` | The agent skill the gateway serves; `.agents/skills/lykta` links to it |
| `.agents/skills/self-host` | Setting up a gateway and app build |

## Invariants

- A layout change touches `Core`, `Widgets` and the skill's `layout.md`
  together. Gateway tests compile every JSON example in `layout.md`.
- Rendering is bounded and offline: layouts stay within the `Layout` budgets,
  the widget makes no network requests, and view bodies never parse JSON.
- The gateway is the only content writer. The app never calls
  `Activity.request` or updates content; it ends an activity only when the
  gateway reports it ended, or on Reset.
- Unknown stays unknown. A start with an unknown outcome is never retried, and
  missing reports never become ended activities, except for activities absent
  from the first report of a new app install or update.
- `Store` commits every state change in one transaction. Ending fences later
  updates, updates coalesce to the latest revision, and starts and ends are
  never dropped.
- Tokens are stored only as hashes. Never log tokens, push tokens or payloads.
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

## Commands

| Command | Use |
| --- | --- |
| `just test` | Core and gateway tests; CI runs them on Linux |
| `just ios` | Compile the app and widgets without signing |
| `just gateway` | Run the gateway locally with `LYKTA_*` settings |
| `just image` | Build the gateway container |

Device behavior, such as how a layout looks or whether a push arrives, needs a
run on an iPhone; compiling proves neither.

## Release

Self-hosters build the gateway image from a tagged commit and the app from
Xcode with their own `Config/Local.xcconfig`. Gateway state lives in SQLite,
so replacing the container is safe; in-flight HTTP requests are dropped and
in-flight starts become `unknown`.
