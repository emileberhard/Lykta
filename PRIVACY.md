# Privacy

Lykta has no accounts, analytics, advertising or tracking. The app connects
only to the gateway it was built for. The App Store app uses a gateway operated
by Emil Eberhard. An app you build yourself uses the gateway that you or its
builder runs, and that operator is responsible for it.

## What the gateway stores

For each registered phone:

- a random device ID and a random ID for the app install
- the app version, the newest layout format it can draw, and whether the build
  uses Apple's development or production push service
- the push tokens Apple issues for starting and updating Live Activities
- hashes of the device secret and the agent token; the tokens stay in the
  phone's Keychain and with the agents you give them to
- the identifier of the App Attest key the app created to register, which is a
  hash of the key's public part and proves the registration came from a genuine
  copy of the app

For each Live Activity:

- the name, title, layout, data and alert text your agents send
- its delivery state and what the phone reports about it, such as active,
  ended or dismissed
- each button press and toggle change, with its time, so your agents can act
  on it; these are kept for one day

Your agents supply all activity content, apart from the fixed examples you send
from the app's gallery. Do not send content that you do not want stored on the
gateway.

## Diagnostics

So that problems can be fixed without access to the phone, the app sends the
gateway a log of what it observes:

- app launches and foreground changes
- whether Live Activities are allowed
- the phone model and iOS version
- which activities appeared and their state
- fingerprints of the content and push tokens it received
- errors, and Apple's MetricKit crash, hang and performance reports

The gateway logs what it did with each request and push. These logs contain no
tokens and no activity text. Your agents can read your phone's log with the
agent token. The gateway's operator can read every phone's log.

## Retention and deletion

The gateway deletes ended activities about 7 days after they end, and
diagnostics after 14 days. Reset in the app ends every activity and deletes the
phone's registration, activities and diagnostics from the gateway. If you delete
the app without Reset, the registration stays; the gateway forgets its push
tokens once Apple rejects them.

Before each update, the App Store app's gateway copies its database so that a
failed update can be recovered. Each copy is deleted after at most 14 days, so
data deleted from the gateway is gone from its copies 14 days later.

## Who else handles data

Apple's Push Notification service delivers activity content to the phone. The
App Store app reaches its gateway over HTTPS through Cloudflare's network.

## Questions

Open an issue at <https://github.com/emileberhard/lykta/issues>.
