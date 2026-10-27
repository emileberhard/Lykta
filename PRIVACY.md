# Privacy

Lykta has no accounts, analytics, advertising or tracking. The app connects
only to the gateway it was built for. The App Store app uses a gateway operated
by Emil Eberhard. An app you build yourself uses the gateway that you or its
builder runs, and that operator is responsible for it.

## What the gateway stores

For each registered phone:

- a random device ID and a random ID for the app install
- the app version, the newest layout format it can draw, and which of Apple's
  push services, development or production, the phone registered with and
  each of its push tokens works with
- the push tokens Apple issues for starting and updating Live Activities, for
  notifications and for reloading widgets, or the error iOS gave when it
  refused a notification token
- whether notifications are allowed and whether their banners are temporary
  or persistent
- hashes of the device secret, the agent token and the widget token; the
  tokens stay in the phone's Keychain and with the agents you give them to
- the identifier of the App Attest key the app created to register, which is a
  hash of the key's public part and proves the registration came from a genuine
  copy of the app

For each Live Activity:

- the name, title, layout, data and alert text your agents send
- its delivery state and what the phone reports about it, such as active,
  ended or dismissed
- when it started, last changed and ends, which the app shows
- each button press and toggle change, with its time, so your agents can act
  on it; these are kept for one day

For each widget, until your agents delete it:

- the name, title, layout and data your agents send
- which widget sizes on the phone show it, and which version each last loaded
- each button press and toggle change, with its time, kept for one day like
  Live Activity taps, or until the widget is deleted

For each notification, for one day:

- the name, the sender's ID and name, the text, whether it plays a sound and
  which uploaded files it uses, as your agents send them
- its delivery state and what the phone reports about how it prepared it,
  such as whether it showed the sender's avatar

For each sound or image your agents upload, until a day after its last upload
or use:

- the file, its type, its length or size, and a hash that finds a repeated
  upload

Your agents supply all activity, widget and notification content, including sounds and
images, apart from the fixed examples you send from the app's gallery and the fixed
hello that `lykta setup` sends. Do not send content that you do not
want stored on the gateway.

## Diagnostics

So that problems can be fixed without access to the phone, the app sends the
gateway a log of what it observes:

- app launches and foreground changes
- whether Live Activities and notifications are allowed, and the banner style
- the phone model and iOS version
- which activities appeared and their state, and which ones you ended in the
  app
- when you finish or skip the introduction, and whether an agent had
  connected by then
- fingerprints of the content and push tokens it received
- errors, and Apple's MetricKit crash, hang and performance reports

The gateway logs what it did with each request and push. These logs contain no
tokens, no activity, widget or notification text and no uploaded files. Your agents can read your phone's log with the
agent token. The gateway's operator can read every phone's log. A refused
request's message names layout paths and byte counts, never layout values.

## Retention and deletion

The gateway deletes ended activities about 7 days after they end,
notifications a day after they arrive, uploaded sounds and images a day after
their last upload or use, and diagnostics after 14 days. Reset in the app ends
every activity and deletes the phone's registration, activities, widgets,
notifications, uploaded files and diagnostics from the gateway. If you delete
the app without Reset, the registration stays; the gateway forgets its push
tokens once Apple rejects them.

Before each update, the App Store app's gateway copies its database so that a
failed update can be recovered. Each copy is deleted after at most 14 days, so
data deleted from the gateway is gone from its copies 14 days later.

## On the phone

The app keeps the sounds and sender pictures it downloads for notifications,
at most 64 files and 64 MiB, and removes the oldest first. The widget keeps
the last content it loaded for at most 64 widgets, so it can still show them
while the gateway is unreachable; Reset deletes it. The app remembers whether
you finished its introduction, which Reset keeps, and whether an agent has
started an activity on the phone, which Reset forgets. iOS keeps a
notification's image with the notification until you clear it. Deleting the
app deletes them.

## Who else handles data

Apple's Push Notification service delivers activity content and notifications
to the phone, and tells its widgets when to reload; widget content travels
only between the gateway and the phone. To show a notification as a message from its sender, the app
shares the sender's name and the text with iOS on the phone, which may suggest
the sender in Siri and the share sheet; this stays on the phone. The
App Store app reaches its gateway over HTTPS through Cloudflare's network.

## Questions

Open an issue at <https://github.com/emileberhard/Lykta/issues>.
