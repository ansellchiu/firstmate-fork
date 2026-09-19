# The Discord spike

A two-week, disposable trial of a private Discord channel as Fred's phone-side attention and receipt surface.
It exists to answer one empirical question cheaply: is a chat app the captain already has installed good enough as the place work arrives, or does the captain want a purpose-built board?
Answering that with a purpose-built push backend costs days of building; answering it with a channel and a webhook costs an afternoon.

This is a spike, not an adoption.
Discord does not end-to-end encrypt message text and has announced no plan to, so everything posted here is read by Discord Inc.
That is acceptable for two weeks of non-sensitive fleet chatter and is not acceptable permanently, which is why the exit is part of the design rather than an afterthought.

## The shape

```
  Firstmate (primary harness unchanged)              Discord (private guild, one member)
  -------------------------------------              -----------------------------------
  an attention or receipt event
        |
        v
  bin/fm-discord-post.sh  --- incoming webhook --->   #fred   "PR ready ..." plus its anchors
                                (one curl)


  the captain types a reply in #fred
        |
        v
  bin/fm-procevent-discord.sh poll  (registered under bin/fm-procevent.sh)
        |
        v
  bin/fm-inbox.sh note  --->  ONE `check` wake  --->  the existing wake queue, drain, and acknowledgement
```

Both halves ride seams Firstmate already owns.
Outbound is an incoming webhook, so there is no bot, no token, no gateway process, and no inbound HTTPS endpoint to expose.
Inbound is a registered long-polling source whose only action is `bin/fm-inbox.sh note`, the same surface the captain's own out-of-band capture and the spoken interface already use.

## What it deliberately is not

A Discord message can only ever become a captain note.
The inbound path dispatches nothing, merges nothing, closes nothing, and answers no held decision.
Merges in particular stay out of Discord for the spike: merge authority is an explicit captain instruction or a project's standing posture, and a low-friction chat path that Firstmate cannot authenticate is the wrong thing to give that authority to.

There is no second queue and no second ledger.
The backlog stays the only queue and the held-task record stays the only decision store.
Anything Fred must be able to find later belongs in the durable records, never in the channel, and not only as a rule: Discord does not expose its search API to bots, so an agent can page roughly the last hundred messages of a channel and nothing more.

Fred is the only Discord identity.
No worker, scout, or second mate ever gets one, because a worker with its own Discord identity is a second mouth to the captain by construction.

## Setup

The captain does the first four steps once; they take about ten minutes, cost nothing, and are all reversible.

1. Create a new private Discord server and invite nobody.
2. Create one text channel named `#fred`.
3. In that channel: Integrations, then Webhooks, then New Webhook, named "Fred", and copy its URL.
4. Write the URL into this home's gitignored `config/discord-webhook`.

The webhook URL is a bearer secret: whoever holds it can post as Fred in that channel.
It never travels in a worker's instructions, a status line, a commit, or a packet.
Rotate it by deleting the webhook in Discord and creating a new one.

Check the outbound half without posting:

```
bin/fm-discord-post.sh check
bin/fm-discord-post.sh receipt "a test receipt" --anchor "https://example.com/x" --dry-run
```

The inbound half needs a bot, so set it up only once outbound has proved the notifications land and the register is right.

5. Create an application and a bot in the Discord developer portal, enable its Message Content Intent, and invite it to the one server with read access to `#fred` only.
6. Write the bot token into `config/discord-bot-token`, the channel's id into `config/discord-channel`, and the captain's own user id into `config/discord-captain`.
7. Arm the poll:

```
bin/fm-procevent-discord.sh check
bin/fm-procevent-discord.sh arm
```

Arming seeds its position from the newest message and notes nothing, so it never imports the channel's history into the captain's inbox.

## Configuration

Each setting is one line in a local, gitignored `config/` file, and each has an environment variable that overrides it for a single run.
A missing or malformed value refuses with the path to write, naming the setting and never the value.

| File | Environment | Holds |
| --- | --- | --- |
| `config/discord-webhook` | `FM_DISCORD_WEBHOOK_URL` | The incoming webhook URL Fred posts through. Required by `bin/fm-discord-post.sh`. Bearer secret. |
| `config/discord-bot-token` | `FM_DISCORD_BOT_TOKEN` | The bot token the inbound poll reads the channel with. Required by `bin/fm-procevent-discord.sh`. Bearer secret. |
| `config/discord-channel` | `FM_DISCORD_CHANNEL_ID` | The `#fred` channel's id. Required by the inbound poll. |
| `config/discord-captain` | `FM_DISCORD_CAPTAIN_ID` | The captain's own user id. The inbound allowlist: no other author can produce a note. |

The environment winning over the file is also the vault path.
A call made as `bin/fm-av-run.sh FM_DISCORD_WEBHOOK_URL -- bin/fm-discord-post.sh receipt "..."` puts the secret in that one process and nothing else, which is the point-of-use contract [`configuration.md`](configuration.md#automic-vault-secret-injection-configav-inject--fm_av_inject) already owns.
No second secret mechanism is introduced for the spike.

Both secrets reach `curl` through a configuration file on its standard input rather than through its arguments, so neither is visible in the process table to another user on the machine.
Each value is shape-checked before use: the webhook must be a Discord webhook URL, so a mistyped host cannot receive the fleet's business along with the secret, and a token carrying whitespace is refused, so it cannot forge a second HTTP header.

`FM_DISCORD_MAX_CHARS` lowers the per-message budget below Discord's hard 2000-character ceiling; it defaults to 1900.

## What goes out

Attention and receipts only, and the allowlist is enforced rather than remembered: `bin/fm-discord-post.sh` refuses any other kind.

| Kind | Posted for |
| --- | --- |
| `pr-ready` | Work ready for the captain's review, with the pull request's full URL as its anchor. |
| `blocker` | A real blocker or failure, after the relevant playbook is spent. |
| `finding` | A finished investigation's one-line finding, with its report path. |
| `receipt` | A landing receipt: one line plus its anchors. |

Routine progress, empty polls, heartbeats, worker status lines, task ids, and internal mechanics have no kind and cannot be posted.
The outcome-not-mechanics translation rule applies here exactly as it does in the terminal, and a chat app's low friction makes breaking it easier, which is itself something the spike should watch for.

The 2000-character ceiling is Discord's and is hard.
A long summary is truncated with a marker; anchors are never truncated, and a message whose anchors alone will not fit is refused rather than posted with half a URL in it.

## What comes in

Free text from the allowlisted captain account, and nothing else.
It becomes a captain note carrying the message verbatim under a provenance line that marks it as quoted, untrusted chat text.
The text reaches `bin/fm-inbox.sh note` on standard input, so no shell ever parses it, and the note's own shape is what keeps it inert; the allowlist gates who can produce a note, not what the text may say.
Messages from anyone else, from a bot account, and from the webhook itself are ignored, which is also what stops Fred's own posts from feeding back in.

A note is presented at the next wake drain and is acknowledged with `bin/fm-inbox.sh drain --ack <id>`, exactly like any other captain note.

If the bot token, the channel, or the bot's access to the channel is wrong, the source reports it once and stops, rather than reporting the same broken credential on every cycle.
Fix the setting and arm it again.

Discord merely being unreadable is a different outcome and needs no operator action: a wifi drop, a sleeping laptop, or a sustained rate limit is reported once as a wait, the source stays registered, and the poll re-arms itself and picks up where it left off.
An outage is announced once when it starts and once when it clears, however long it lasts, so do not run `arm` again after one; the source is still live and a second registration is not what fixes it.

## Judging the spike

Call it a failure and drop Discord on any of these:

1. The captain scrolls the channel to remember state, which is the second-ledger failure arriving; the backlog answers that question.
2. Anything sensitive lands in it, such as credential names, client-contract material, or private strategy.
3. The urge appears to give a worker its own bot, which is a second mouth.
4. Threads start being used as task threads, which is a second ledger.
5. The notification volume becomes ignorable and the captain mutes the channel, at which point the surface has failed at its one job.
6. It answers the underlying question negatively, meaning chat is not enough and the captain wants a board, which is the spike succeeding by killing scope.

## The exit

Two weeks, then delete the server.
Nothing durable was created, so the whole exit is:

```
bin/fm-procevent-discord.sh retire
rm -f config/discord-webhook config/discord-bot-token config/discord-channel config/discord-captain
```

Then delete the Discord server and the bot application.
Retiring the source also clears its outage marker, and the stale poll position and the noted-message records left under `state/` are inert and can be removed with it.

## Where the details live

`bin/fm-discord-lib.sh`'s header owns the exact secret handling and budget mechanics.
`bin/fm-discord-post.sh --help` owns the outbound calling syntax, and `bin/fm-procevent-discord.sh --help` owns the inbound adapter's commands and its contract with the process-event runner.
[`.agents/skills/process-event-sources/SKILL.md`](../.agents/skills/process-event-sources/SKILL.md) owns how a registered source's wakes are handled.
