# sovereign-version-control-client

Client-side tooling for using a **self-hosted Forgejo instance as your git
upstream**, the way you'd use GitHub — but on hardware you own, reachable over
a private network, with no third party in the path.

Four small bash scripts. No dependencies beyond `git`, `curl`, `ssh`, and
`python3` (used only to read and write JSON).

```
forge-setup     make this machine a client: key, SSH alias, register on server
forge-new       create a repo on the forge and wire a local one to it
forge-clone     clone by bare name instead of a full SSH URL
forge-doctor    check every link in the chain and tell you which one is broken
```

## Why this exists

Self-hosting git is easy. Making it feel like GitHub is the annoying part —
you end up hand-editing `~/.ssh/config`, remembering a nonstandard SSH port,
pasting public keys into a web UI, and creating repos by clicking. This
collapses that into `forge-new myproject`.

## The architecture it assumes

```
  laptop  ──git push──▶  Forgejo on a small always-on box
                              │        (private network, e.g. Tailscale)
                              │
                     nightly, restic encrypts HERE
                              ▼
                     off-site object storage (ciphertext only)
```

The scripts only care about the top half — your machine talking to the forge.
The backup half is server-side and independent; see
[docs/server-notes.md](docs/server-notes.md) for the shape it expects.

Two details this tooling exists to get right:

- **Forgejo's SSH server is usually not the host's `sshd`.** Container installs
  commonly expose it on **2222** while port 22 is closed entirely. If you assume
  22, everything fails with a confusing `Connection refused`.
- **A dedicated key plus `IdentitiesOnly yes`.** Without it, `ssh` offers your
  GitHub keys first and a forge with several keys registered can reject you with
  `Too many authentication failures` before it ever tries the right one.

## Install

```bash
git clone https://github.com/patrickbdevaney/sovereign-version-control-client.git
cd sovereign-version-control-client

install -d -m 700 ~/.config/forge
cp forge.conf.example ~/.config/forge/forge.conf
chmod 600 ~/.config/forge/forge.conf
$EDITOR ~/.config/forge/forge.conf        # host, user, port, alias

# put the scripts on your PATH
ln -s "$PWD"/bin/forge-* ~/.local/bin/
```

Config is looked up in this order: `$FORGE_CONF`, `./forge.conf`,
`~/.config/forge/forge.conf`. Nothing secret goes in it — only host names.

## Use

**One-time, per machine:**

```bash
forge-setup
```

Generates `~/.ssh/id_ed25519_forge`, writes a marked block into `~/.ssh/config`
(it never touches the rest of the file), uploads the public key, then proves the
result by opening an actual SSH session. Re-running is safe.

**Then, for every repo — this is the GitHub-equivalent bit:**

```bash
forge-new myproject                    # create + init + commit + push
forge-new myproject --public --desc "..."
forge-new                              # run inside an existing repo with no
                                       #   origin, and it adopts that repo
```

After that it is ordinary git, forever:

```bash
git add -A && git commit -m "..." && git push
git pull
```

**When something breaks:**

```bash
forge-doctor
```

Walks the whole chain — key permissions, SSH alias resolution, TCP reach, HTTPS,
SSH authentication, API token, and the current repo's `origin` — and reports
each link separately, so you learn *which* one failed instead of just seeing
`Permission denied`.

```
==> ssh auth
  ok  Hi there, you! You've successfully authenticated with the key named laptop
==> api
  ok  authenticated as you
```

## Authentication

Creating repos and uploading keys uses the Forgejo API, which needs a
credential. Two options:

1. **Token (recommended).** Create one at
   `https://<your-forge>/user/settings/applications` with scopes
   `write:user` and `write:repository`, then:

   ```bash
   printf '%s' 'TOKEN' > ~/.config/forge/token
   chmod 600 ~/.config/forge/token
   ```

   Scoped and revocable, and it survives a password change.

2. **Password.** If no token file exists, the scripts prompt for one on the
   terminal.

Either way the credential is handed to `curl` through a mode-600 config file
rather than a command-line argument, so it never shows up in `ps` output or your
shell history. Day-to-day `git push` doesn't touch the API at all — that's pure
SSH key auth.

## Notes

- Repos are created with `auto_init: false` on purpose. An empty remote means
  your first push can't collide with a server-side initial commit and produce
  the `refusing to merge unrelated histories` mess.
- `forge-new` refuses to run in a directory that already has an `origin`, and it
  checks that *before* creating anything server-side, so a mistake never leaves
  an orphan repo behind.
- `forge-setup` writes only between its `# >>> forge-setup:` markers. Your
  existing SSH config is left untouched.
- Set `FORGE_LAN_HOST` and you also get a `<alias>-lan` host, so you can still
  push at home if the tailnet is down.

## License

MIT — see [LICENSE](LICENSE).
