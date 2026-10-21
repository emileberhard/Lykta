# Architecture

## Goals and constraints

- An agent shows a native Live Activity with one HTTP request, in nearly any
  layout ActivityKit can display, without an app update per layout.
- One person can self-host the gateway. Apple Push Notification service is the
  only external service.
- The codebase stays small: two Swift packages, Apple frameworks first, and
  third-party dependencies only from Apple's GitHub organization.

Non-goals for now: hosted multi-tenant service, interactive buttons, platforms
other than iPhone.

## Flow

```mermaid
sequenceDiagram
    participant Agent
    participant Gateway
    participant APNs
    participant Phone
    Phone->>Gateway: register, report push-to-start token
    Agent->>Gateway: PUT layout + data
    Gateway->>Gateway: validate, compress, persist
    Gateway->>APNs: create channel, push-to-start
    APNs->>Phone: start
    Agent->>Gateway: PUT data
    Gateway->>APNs: broadcast update
    Phone->>Gateway: report activity states
```

## Decisions

**Layouts are data rendered by native views.** The language is a tree of
SwiftUI primitives and modifiers decoded by `LyktaCore`; the widget maps each
node to its SwiftUI view. Fixed templates would cap what agents can show, an
extension cannot run downloaded code, and images lose live timers and text
quality. A new primitive needs an app update; until then the phone shows the
activity's title.

**One decoder validates and renders.** The gateway and the widget compile the
same `Layout` type, so a layout the gateway accepts renders on the phone, and
agents get errors with JSON paths when they send it. Budgets on bytes, nodes,
depth and modifiers keep rendering bounded.

**Push-to-start and broadcast channels.** The gateway starts an activity with
the phone's push-to-start token and updates it through a broadcast channel it
creates per activity. The app therefore never has to run to forward
per-activity update tokens. The cost is the Broadcast capability and channel
cleanup: channels are deleted five minutes after an activity ends and orphans
are swept at startup.

**The layout travels in the push.** `ContentState` carries the title and the
raw-deflated layout JSON; the phone decodes it once. The gateway checks the
real payload against the 4 KB APNs limit before accepting a request.

**One actor owns durable state.** `Store` owns the SQLite database; every
mutation is one transaction. Delivery claims jobs from rows, so a restart
resumes pending work. A start whose outcome is unknown becomes a live activity
with delivery `unknown` rather than being sent twice. An in-memory queue would
lose work on restart; an external queue would add infrastructure.

**Apple networking.** SwiftNIO serves HTTP/1.1 behind the operator's TLS proxy
on macOS and Linux. APNs requests use `URLSession`, which on Linux runs on
libcurl through FoundationNetworking, which negotiates the HTTP/2 that APNs
requires; the container image ships that libcurl.

**Two packages and a plain Xcode project.** `Core` has no dependencies and is
the only package the app links; `Gateway` adds SwiftNIO and, on Linux,
swift-crypto. The app uses Xcode's JSON project format directly instead of a
generator.

**Credentials.** Each phone gets a device secret and an agent token, both 256
random bits stored as SHA-256 hashes. Registration is open up to a configured
device limit; operators keep the gateway on a private network.

## Expensive to change

- The `ContentState` encoding and the `LyktaActivity` type name, which
  installed apps and pushes depend on.
- The meaning of existing layout keys, which agents' saved layouts rely on.
  Adding keys is cheap.
- The device API in `DeviceAPI.swift`, shared by installed apps and gateways.
