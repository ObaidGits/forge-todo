# Recovery guide

Forge is currently a pre-release shell and does not yet store production user records. The encrypted database, backup, and Recovery Mode arrive in later implementation waves; preview builds must not imply that those paths are available.

When recovery is implemented, Forge will never create a replacement key for an existing encrypted store. A missing or invalid key enters non-destructive Recovery Mode. Restore validates an authenticated archive with bounded resource use, builds and verifies a staged generation, and switches atomically; failure leaves or restores the prior verified generation.

Keep independent encrypted backups and their passphrases separate from the device. Do not edit database, generation-pointer, key-store, or backup files. Do not send a database or backup in a support request. Exact release recovery and upgrade drills must pass before any target becomes stable.
