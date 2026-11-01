# VPS gateway

This deployment runs the gateway on the existing HostUp VPS independently of
llm-router. The VPS has limited memory, so
GitHub-hosted runners build releases; it pulls only the highest plain version
with both the binary and Sigstore bundle. It
verifies the asset SHA-256 and the GitHub-hosted release workflow identity at
that exact tag before touching the installed binary. A public prerelease makes
the artifact available before TestFlight, without a GitHub credential on the
VPS. TestFlight success promotes it to a full release. The simpler alternative,
building on the VPS, risks starving llm-router; a public-repository self-hosted
runner would violate the private-repository runner boundary.

The bootstrap is release `0.17.0`, commit
`aaadd86870d155015fe0ed4c39355944e0b758a5`, built on emils-linux and copied
to the VPS with SHA-256
`d925698241992de75f88ff1c8e54960242e7fc07494dd4f527f3076934d09407` checked
on both hosts. It predates the attested release pipeline and is not attested.
Future releases must pass verification; do not treat this bootstrap exception
as a fallback for them.

`install` installs the units, pinned GitHub CLI and scripts without starting
them. Provision APNs keys at `/etc/lykta/apns-development.p8` and
`/etc/lykta/apns-production.p8` and the dedicated tunnel credential at
`/etc/lykta/tunnel.json`; all are root-owned and untracked. Their off-box
sources are the Mini's APNs and tunnel stores. The Lykta account reads only its
own APNs credentials through systemd credentials. Never share the llm-router
process or credentials.

Only one real gateway may hold the APNs keys. To migrate, fence the Mini's
automatic deployer, drain and stop its gateway and tunnel, take a `VACUUM INTO`
copy after the writer stops, verify its integrity and copy digest, then start
the VPS gateway and dedicated tunnel. Keep the stopped Mini copy until the VPS
has delivered real notifications and has an R2 snapshot. To roll back after
the VPS has accepted writes, fence it and move its current consistent database
back first. A second test gateway uses `simulate` without APNs keys.

Backups use the separate EU `lykta-backups` R2 bucket, not the indefinitely
locked service-state repository. Every six hours the gateway creates a
consistent SQLite snapshot, verifies its integrity and row counts against the
unchanged source, compresses and encrypts it as one object to the recipient at
`/etc/lykta-backup/recipient`. The age identity is root-only on emils-linux;
the Mini login keychain holds a verified recovery copy. The bucket-only writer
credentials are in `/etc/lykta-backup/r2.env`; Emil's Cloudflare account can
replace them.

The bucket locks each object for 11 days. Each backup run deletes objects at
least 12 days old and raises an error if one had reached 13 days. R2 lifecycle
also expires objects at 12 days. Cloudflare says lifecycle deletion typically
takes up to 24 hours, without a hard deadline. These independent deletion paths
have two days of margin against the 14-day privacy promise, but simultaneous
prolonged VPS and Cloudflare lifecycle failures could breach it. This residual
risk is accepted by the operator. An indefinitely locked restic repository
cannot meet the deletion policy because snapshots share old pack objects.

An update preflights in simulation without APNs keys, retains the previous
binary and a consistent local database copy, drains before replacement and
checks both local and public versions. On failure it rolls back only when the
database schema version still permits the previous binary; it never restores
old state over new writes. `pending.json` records an interrupted swap, and a
failed-version marker stops repeated replacement. Investigate before removing
the marker. Local pre-deploy copies retain at most the three newest backups for
at most 14 days, while
R2's separate retention policy controls its snapshots.
