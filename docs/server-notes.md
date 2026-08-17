# Server-side notes

This repo is the **client** half. The scripts here assume a server that looks
roughly like the following. Nothing in this document is required for the client
tooling to work — it's here so the shape is reproducible.

## The forge

Forgejo on a small always-on machine (a mini PC, a NAS, a Pi). Two things
matter to the client:

- **`ROOT_URL` must match the hostname you actually browse to.** If it doesn't,
  Forgejo shows a banner warning that parts of the app will break, and the
  clone URLs it hands out will point at the wrong host.
- **Know which SSH port is which.** Forgejo ships its own SSH server for git
  traffic. In container deployments it's typically published on **2222**, and
  the host's real `sshd` may be firewalled off entirely. `forge-doctor` reports
  this explicitly because assuming 22 is the single most common way this setup
  fails.

## Reaching it from anywhere

A mesh VPN (Tailscale, Netbird, Nebula) is the least painful answer: the box
gets one stable name that resolves both on the LAN and remotely, and nothing is
exposed to the public internet. With Tailscale, `tailscale cert` /
`tailscale serve` also gets you a real, publicly-trusted TLS certificate on a
private host — so browsers and `curl` are happy without certificate warnings or
a manual CA.

Keep the LAN address configured too (`FORGE_LAN_HOST`). If the mesh control
plane is unreachable, you can still push at home.

## Backups

The forge is a single point of failure until it's backed up. The arrangement
these notes assume:

- **restic**, running on the forge host, on a nightly timer.
- It backs up the git repositories **and** a database dump — a repo backup
  without the database loses issues, PRs, users, and SSH keys.
- Encryption happens **on the forge, before anything leaves it**. The remote
  only ever holds ciphertext, so the storage provider is untrusted by design.
- The target is cheap object storage. S3-compatible services with no egress
  fees (e.g. Cloudflare R2, Backblaze B2) suit this well; source code compresses
  hard, so the bill is usually negligible.

Sketch:

```bash
restic backup /path/to/forgejo/repositories /path/to/dump.sql
restic forget --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
```

## Test the restore, not the backup

A backup you have never restored is a hypothesis. The check that actually
counts:

1. Restore a snapshot to a scratch directory **from the remote**, not a local
   cache.
2. `git fsck` the restored repositories — they must come back clean.
3. Load the database dump into a throwaway database and confirm the table count
   and a few row counts look sane.
4. Confirm the application secret (Forgejo's `SECRET_KEY`) is present. Without
   it, restored data exists but the instance won't come up correctly.

Do this on a schedule, not once. Silent backup failure is the normal failure
mode — a job that "succeeds" nightly while writing nothing usable.
