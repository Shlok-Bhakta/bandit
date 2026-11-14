# Security

## What's sensitive

| Secret | Where it lives | Never |
|---|---|---|
| The band's **owner key** (P-256) | iOS Keychain, this device only; the dongle's NVS | in logs, source, UserDefaults or git |
| Meta sign-in session | its own Keychain item, used only while claiming a band | sent anywhere but Meta |
| Dongle **update signing key** | `~/.config/neural-playground/dongle-signing.key` (0600) on the build Mac | in the repo; only its public half is in `src/ota.rs` |

The app has no analytics and no backend. The dongle accepts firmware only if it carries a valid
ECDSA P-256 signature for its built-in public key, checks the image's SHA-256, and rolls back a new
image that doesn't survive its first minute.

## Known limits

- The dongle's NVS (owner key, pairings) isn't encrypted in development builds: anyone holding the
  board can read it. Enable flash and NVS encryption before carrying one around.
- Hosts pair with "Just Works" (no passkey), but only inside a 2-minute pairing window.
- Meta's app client tokens (needed only to claim a band) aren't in the source: the build reads
  them from `.env` or `~/.config/neural-playground/build.env` (see `.env.example`) into Info.plist.

## Reporting

Please report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab)
rather than in a public issue.
