# Notifications

Status: text notifications and media have landed, and their decisions are in
[the architecture record](architecture.md). This file holds what remains for
0.6.0.

## Remaining for 0.6.0

Product: the README's notification section, App Store screenshots that show a
notification, and the App Store privacy label for uploaded sounds and images.

## Still open

Whether Siri announces these notifications on AirPods by default, as WWDC21
says, or needs the older intent handling the `INSendMessageIntent` reference
still lists. App Review's view of communication notifications for agent
messages cannot be tested before submission; plain notifications, which keep
the sound, image and thread, are the fallback.

Not in 0.6.0: a link to open on tap, reply buttons, Time Sensitive, breaking
through Focus, SVG avatars, scheduled delivery and a spoken hello.
