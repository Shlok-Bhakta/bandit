# Security

## What's sensitive

| Secret | Where it lives | Never |
|---|---|---|
| The band's **owner key** (P-256) | the dongle's NVS (provisioned over USB serial) | in logs, source, the app or git |
| Dongle **update signing key** | `~/.config/bandit/dongle-signing.key` (0600) on the build Mac | in the repo; only its public half is in `src/ota.rs` |

The app has no analytics and no backend. The dongle accepts firmware only if it carries a valid
ECDSA P-256 signature for its built-in public key, checks the image's SHA-256, and rolls back a new
image that doesn't survive its first minute.

## Known limits

- The dongle's NVS (owner key, pairings) isn't encrypted in development builds: anyone holding the
  board can read it. Enable flash and NVS encryption before carrying one around.
- Hosts pair with "Just Works" (no passkey), but only inside a 2-minute pairing window.
- The dongle's `IDENTITY` command (taking another dongle's Bluetooth address) is serial only: it
  needs the board in hand.

## Reporting

Please report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab)
rather than in a public issue.
