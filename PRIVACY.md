# Privacy

Lykta has no accounts, analytics, advertising or tracking. The app talks only
to the gateway it was built for. The App Store app uses a gateway operated by
Emil Eberhard; an app you build yourself uses the gateway you or its builder
runs, and that operator is responsible for it.

## What the gateway stores

For each registered phone:

- a random device ID and a random ID for the app install
- the app version and whether the build uses Apple's development or production
  push service
- the push tokens Apple issues for starting and updating Live Activities
- hashes of the phone's token and the agent token; the tokens themselves stay
  in the phone's Keychain and with the agents you give them to

For each Live Activity:

- the name, title, layout, data and alert text your agents send
- its delivery state and what the phone reports about it, such as active,
  ended or dismissed

Activity content comes from agents you set up. Do not send content you would
not want stored on the gateway. Gateway logs record the method and path of
failed requests, never tokens or activity content.

## Retention and deletion

Ended activities are deleted about 7 days after they end. Tapping Reset in the
app ends every activity and deletes the phone's registration and all of its
activities from the gateway. Deleting the app without Reset leaves the
registration in place; once Apple rejects its push tokens, the gateway forgets
them.

## Who else handles data

Apple's Push Notification service delivers activity content to the phone. The
App Store app reaches its gateway over HTTPS through Cloudflare's network.

## Questions

Open an issue at <https://github.com/emileberhard/lykta/issues>.
