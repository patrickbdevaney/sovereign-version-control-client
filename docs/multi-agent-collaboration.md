# Two agents, two repos, one running system

A record of how this repository and its server counterpart were actually built,
written because the *mechanics* of the collaboration turned out to be more
interesting than either codebase.

Two Claude Code instances worked on a single system from opposite sides:

- **the laptop agent** — wrote this client repo, had no shell access to the
  server
- **the server agent** — ran on the mini PC, wrote
  [sovereign-version-control](https://github.com/patrickbdevaney/sovereign-version-control),
  had root on the machine hosting the forge

They shared no context window and had no channel to one another. Neither could
read the other's reasoning, working notes, or intermediate state.

## The three shared media

Everything the two agents coordinated through was external, durable, and
independently inspectable.

**1. GitHub, over the public internet.** Both repos are public. Either agent
could clone the other's work, read its history, and push. This carried the
source — but more importantly, it carried *conflict detection*.

**2. The running Forgejo instance, over Tailscale.** The forge is reachable at a
MagicDNS name that resolves identically at home and away, with a real TLS
certificate. Both agents could query it. Neither controlled it unilaterally.
This is the part that made claims falsifiable: an assertion about the system
could be checked by *asking the system*.

**3. A human relaying summaries.** Intent, priorities, and decisions moved
through a person. This was the lowest-bandwidth channel and the only one that
could lose information.

None of these is a message bus. The agents never addressed each other. They
modified a shared environment and read what the other had left behind —
stigmergy, the same mechanism by which ants coordinate through pheromone trails
rather than conversation.

## Network topology as a capability boundary

The mini PC's own `sshd` is closed. Only Forgejo's git-SSH port (2222) and its
HTTPS API are reachable from the tailnet.

The laptop agent therefore *could not*:

- read the server's filesystem
- inspect the deployed systemd units
- verify what was actually running, as opposed to what was committed

It could only observe the forge through the interfaces any client uses. This
sounds like a handicap. In practice it forced a discipline that improved the
work: **every claim about the server had to be established by running
something.**

- *Is push-to-create enabled?* Push to a nonexistent repo and read the error:
  `Forgejo: Push to create is not enabled for users.`
- *Does the backup retention policy discard intra-day snapshots?* Run
  `restic forget --dry-run` against a scratch repository in a container, with
  five synthetic hourly snapshots, and read which ones it plans to remove.
- *Does creating a repo in an organisation need a different token scope?* Try
  it and read the 403.

None of these required trusting the other agent, and all of them are
reproducible by anyone who doubts the result. That property — *the other party
can re-run my evidence* — is what made cross-agent review work at all.

The general pattern: **give an agent an API surface rather than a shell.** The
boundary was enforced by network configuration, not by instructions, so it could
not be argued past.

## What the repository itself coordinated

The clearest example needed no communication at all.

The laptop agent reviewed the server repo at `0e890f4`, produced a set of
findings, and handed them over. It then wrote fixes for six of them. On
`git push`:

```
! [rejected]  main -> main (fetch first)
```

That rejection *was* the message. The server agent had already shipped the same
six fixes in `2abed50` while the laptop agent was working. The laptop agent
fetched, read the upstream diff, confirmed the other implementation was as good
or better — it had added a real `scripts/create-admin.sh` rather than merely
correcting a dangling comment — discarded its own commit, reset onto upstream,
and contributed only the delta that was genuinely still missing (`6d8f0f5`).

Git's refusal to fast-forward is a coordination primitive. No lock, no
scheduler, no negotiation protocol: the shared medium refused an action that
would have destroyed work, and the agent recovered by reading state it could
already see.

## Correlated failure: the part that should worry you

Both agents independently wrote this line into the config template:

```
RESTIC_REPOSITORY=s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>
```

A value ending in `>` is an output redirect with no target. Because every script
does `set -a; . .env; set +a`, the file is executed shell, and that line makes
bash abort the entire source with `syntax error near unexpected token
'newline'` — leaving *nothing* set. Two agents, working separately, produced
the identical defect.

This is the central caution. **Two instances of the same model are not two
independent reviewers.** Their errors correlate, because their priors do. A
fleet of agents cross-checking each other's work will confidently converge on
the same blind spots.

What actually caught it was not a second author but a different *method*:
running `bash -n` on the file rather than reading it. The laptop agent found the
bug in its own draft during validation, then went looking for it in the
already-merged upstream version and found it there too.

The lesson generalises past agents: **redundant verification buys far more than
redundant authorship**, and verification only counts when the method differs
from the one that produced the artifact.

## The cost: duplicated work

Six findings were fixed twice, in parallel, because neither agent announced what
it was starting. At two agents this is a rounding error. At ten it is the
dominant cost.

The fix is unglamorous and already available in the shared medium: claim work
before doing it — a branch, an issue, a commit with an obvious title. The
infrastructure for agent coordination mostly already exists; it is the same
infrastructure human teams use to avoid stepping on each other.

## Where the agents disagreed

One genuine disagreement is worth recording, because it shows the human channel
doing something the other two could not.

`forge-new` could originally create repos only under the authenticated user,
while two existing repos lived in an organisation. The server agent proposed
resolving this by keeping all new repos in the user namespace, leaving the
client unmodified. The laptop agent disagreed — that constrains where repos may
live in order to suit a script — and instead implemented organisation support
(`1c5349c`), since `forge-clone` already accepted `owner/name` and the two halves
were merely inconsistent.

Neither agent could overrule the other. The disagreement surfaced through the
human, who chose. Shared media are excellent at propagating facts and terrible
at resolving values; that is where the slow channel earns its place.

## Staleness travels

The server's documentation described backups as running nightly at 02:30. That
had been true. By the time the laptop agent read it, the schedule had changed to
hourly and six places in the docs still said otherwise.

The laptop agent absorbed "nightly 02:30" from the human summary, repeated it in
three of its own files, and had to correct all three once it read the actual
timer unit. **Derived facts inherit the staleness of their source**, and an
agent restating something confidently is not evidence, no matter how many hops
it has travelled. Only the timer unit was authoritative — and even that only
described the repository, not the deployed machine, which remained unverifiable
from the laptop.

## Credential handling, including a mistake

The laptop agent needed API access to create repositories. The sequence is worth
recording honestly:

1. It was given the account password, used it once to mint a scoped API token,
   and shredded the password from disk.
2. Later, while grep-scanning the repo for secrets before publishing, it passed
   the token as a search pattern — **printing the token into the session
   transcript.** A precaution leaked the thing it was protecting.
3. It could not revoke the token itself: Forgejo requires basic auth for token
   management, so a token cannot revoke itself (`HTTP 401`). Recovery required
   the higher credential.
4. The token was later revoked with the password and replaced with a
   correctly-scoped one, never printed.

Three transferable points. **Scoped, revocable tokens are the right default** —
the blast radius was bounded, and the forge is unreachable from the public
internet, so the exposed credential was useless without tailnet access. **Design
so that recovery does not depend on the compromised credential** — here it
depended on a *stronger* one, which was survivable only because the human held
it. And **an agent's own safety tooling is a place secrets leak**; the scan that
prints what it found is a common shape of this bug.

## What this suggests for multi-agent work

- **Shared environment beats shared context.** Neither agent could see the
  other's reasoning. It did not matter, because both could run commands against
  the same live system and read the same repositories. Coordinate through
  artifacts, not through synchronised state.
- **Prefer media that detect conflict.** Git rejected a push and that single
  refusal replaced an entire coordination protocol. A shared document with
  last-write-wins would have silently destroyed work.
- **Bound capability with topology, not instructions.** A closed port is not
  negotiable. An agent told to be careful is.
- **Make evidence reproducible.** Findings survived cross-agent review because
  they came with commands the other party could re-run, not because the
  reviewing agent was trusted.
- **Diversify verification methods, not just authors.** Same-family agents share
  blind spots; the check must differ in kind from the work.
- **Keep a human on the values.** Facts propagated fine through the machine
  channels. The one real disagreement needed a person.
