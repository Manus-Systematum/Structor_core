# Reporting a data bug, and what happens next

A parsing bug is noticed while building a list or mid-game — away from the
desk, with a phone in hand. So the report goes to a Telegram bot, and the fix
comes back as a pull request.

```
you → Telegram bot → issue labelled `data-bug` → routine → branch, test, PR → you
```

## Reporting

Message the bot. One sentence is enough; the first line becomes the issue
title and the whole message the body. Say which datasheet, which faction, and
what you expected — the routine reproduces from the same public sources, so
`Ministorum Priest offers holy pistol or power weapon, should be both` is
enough to work from.

The bot answers with the issue link. If it says nothing within five minutes,
the intake workflow is not running; check its Actions tab.

## What the routine does

1. Clones this repository and fetches the dataset from upstream — nothing is
   vendored here, so it reads exactly what the app reads.
2. Reproduces the bug as a **failing test** before changing anything. A bug
   that cannot be reproduced is reported back, not guessed at.
3. Fixes it, runs the whole suite, and opens a pull request that closes the
   issue.

It never pushes to `main`.

## When it stops and asks

Some things are not the routine's to decide, and it is told to stop rather than
guess:

- The rules are ambiguous, or two sources disagree about what is correct.
- The upstream data is wrong, so the fix belongs in `data-corrections.yaml` in
  the Structor repository rather than in the parser.
- The fix would change a decision recorded in `DESIGN.md`.

It comments on the issue with the question and adds the label
`needs-decision`. Those are surfaced in the Claude Code session — ask "any
questions waiting?" and they are read out.

## Setting the intake up

Once, and only the first two steps need a person:

1. Talk to [@BotFather](https://t.me/BotFather) on Telegram: `/newbot`, name
   it, keep the token it gives you.
2. Message your new bot once, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and read
   `message.chat.id` — that is the only chat allowed to file bugs.
3. Put both in this repository's secrets:

```bash
gh secret set TELEGRAM_BOT_TOKEN --repo Manus-Systematum/Structor_core
gh secret set TELEGRAM_ALLOWED_CHAT_ID --repo Manus-Systematum/Structor_core
```

`gh secret set` prompts for the value rather than taking it on the command
line, so the token stays out of your shell history.

The workflow drains the queue every five minutes. Telegram holds unconfirmed
messages for 24 hours, so a message sent while Actions is down is filed when it
comes back rather than lost.
