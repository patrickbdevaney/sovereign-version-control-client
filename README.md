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
                    on a timer, restic encrypts HERE
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
forge-new acme/myproject               # create inside the "acme" organisation
forge-new                              # run inside an existing repo with no
                                       #   origin, and it adopts that repo
```

A bare name goes in your own namespace; `owner/name` targets an organisation.
`forge-clone` takes the same two forms. Organisations use a different API
endpoint (`/orgs/{org}/repos`) and need a token carrying `write:organization` —
without it the server returns 403 and `forge-new` tells you exactly which scope
is missing.

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
   `write:user` and `write:repository` — plus `write:organization` if you
   create repos inside organisations — then:

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

## How this was built: two agents, two repos, one running system

This repo and its server counterpart
([sovereign-version-control](https://github.com/patrickbdevaney/sovereign-version-control))
were written by two separate Claude Code instances — one on the laptop, one on
the mini PC running the forge. They had **no shared context window and no
channel to each other.** Everything they coordinated through was external and
inspectable:

| Shared medium | What it carried |
|---|---|
| GitHub, over the public internet | Source, history, and — critically — *conflict detection* |
| The live Forgejo instance, over Tailscale | Ground truth neither agent controlled alone |
| A human relaying summaries | Intent, priorities, and decisions |

That is stigmergic coordination: the agents never addressed one another, they
just kept modifying a shared environment and reading what the other had left
behind.

**The network topology decided what each agent could do.** The mini PC's own
`sshd` is closed; only Forgejo's port 2222 and its HTTPS API are reachable. So
the laptop agent could never read the server's filesystem or trust its claims
directly — it could only observe the forge through the same interfaces any
client uses, and had to *prove* things by running them. When it needed to know
whether push-to-create was enabled, it pushed to a nonexistent repo and read the
error. When it needed to know whether a backup retention policy discarded
intra-day snapshots, it ran `restic forget --dry-run` against a scratch
repository in a container rather than reasoning about the flags.

Giving an agent an API surface instead of a shell is a real design pattern, not
a limitation to work around. Capability was bounded by network configuration —
something neither agent could talk its way past.

**What went well.** Git's refusal to fast-forward is a coordination primitive.
The laptop agent finished a set of fixes, tried to push, and was rejected — that
non-fast-forward was how it *learned* the other agent had already shipped the
same work (`2abed50`). It read the upstream diff, discarded its own duplicate
commit, rebased, and contributed only the delta that was genuinely missing
(`6d8f0f5`). No message passing was needed for that handoff; the repository
itself carried the signal.

**What went badly, and matters more.** Both agents independently introduced the
*same* bug — a config template line ending in `>`, which silently turns into a
shell redirect and breaks the file. Two agents from the same model family are
not two independent reviewers; their mistakes correlate. What caught it was not
a second author but a different *method*: running `bash -n` on the file instead
of reading it. Redundant authorship buys much less than redundant verification.

The other real cost was duplicated effort — the same six findings fixed twice,
in parallel, because neither agent announced what it was working on. At this
scale that is cheap. At ten agents it is the dominant cost, and the fix is
boring: claim work in the shared medium (a branch, an issue, a commit) before
starting it.

A fuller account, with the commit-by-commit timeline and the credential-handling
incident, is in
[docs/multi-agent-collaboration.md](docs/multi-agent-collaboration.md).

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
