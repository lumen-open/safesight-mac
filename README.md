# SafeSight Mac

**Free, open-source blocking of explicit images and video on your Mac. Once it's on, it stays on.**

**[Visit the website](https://lumen-open.github.io/safesight-mac/)** for a quick tour and straight answers to the hard questions, like streaming, downloads and other browsers.

SafeSight Mac covers explicit images and video as soon as they appear on your screen: in any app, in any browser, on every display. Everything else is left alone. Your work, your calls, your music and your code carry on as normal.

What makes it different is that it stays on. There's no off switch for a bad night, no password to beg for, and nobody who can unlock it early, not even us. When you set it up, you choose how long getting out should take, anywhere from a week to a year, and you can always make it longer. If you ever ask to leave, the countdown starts; change your mind, press **Stay**, and it's as if you never asked. The only shortcut is an optional friend you choose to add, who can bring the wait down to a day but can never stop you leaving.

**Going all in?** We're working on a Hardcore lock, where even wiping your Mac won't get you out early. The only way around it is Apple's own proof-of-purchase check, which takes weeks. It comes after the first release.

**Looking for something for your phone?** We recommend [SHIFT](https://shiftyourphone.com/content-filter/). Its Content Filter is free, works on iPhone and Android, and is set up from your computer so it can't simply be deleted from the phone. We're not affiliated with SHIFT; we just think it's good.

## Why it exists

Pornography is built to wait you out. It's free, it never closes, it never runs out, and every inch of it was designed by people who get paid when you stay. It doesn't have to win the argument. It only has to be there when you're tired, when it's late, when the house is quiet and the part of you that knows better has gone to sleep. Then it takes a little more of the person you were trying to become.

Willpower alone rarely beats that, because willpower is the first thing to leave at two in the morning. So SafeSight Mac moves the decision. You make it in daylight, clear-eyed, knowing what you want your life to look like, and it keeps that promise on the nights you can't. The person you are on your best day gets the final word. The worst hour of your week doesn't get a vote.

Nobody looks over your shoulder, nothing is reported to anyone, and there's no lecture. Wanting this isn't a confession. It's the same instinct that makes someone leave their card at home before a night out, or pour the bottle down the sink while they still can. You're locking a door from the inside. The key is still yours; you've just made the walk to it long enough to remember why you locked it.

This is about freedom. Not the thin kind, where you do whatever the next five minutes want, but the real kind: being the same person at midnight that you were at noon.

## Why we build it with AI

The technology on the other side keeps getting better. Feeds learn exactly what keeps you scrolling, recommendations learn what you can't resist, and AI can now make explicit images of anything, on demand. Every year it gets easier to get pulled in and lose yourself to the void.

Those tools are improving fast, and the way to keep up is to turn the same power around and use it for good. So we build SafeSight Mac with AI, on purpose, to fight back: it lets a small project build faster and probe its own defences harder than it ever could alone. Every line is public, every change has to pass the project's checks, and the lock's core needs a second human reader before it ships.

## Hard to get around, by design

Most blockers fall to a five-minute trick, and everyone who's needed one knows the tricks. SafeSight Mac is built to be airtight. Here's what happens to the usual ones.

| The usual way around it | Most blockers | SafeSight Mac |
|---|---|---|
| Open a private window or a different browser | Often slips straight through | Still covered. It works on the screen itself, not inside the browser |
| Turn on a VPN or change your DNS | Defeats network filters | Changes nothing. The cover works on the screen, not the network, and the site blocking we're adding runs on your Mac, where a VPN or new DNS can't switch it off |
| Find it on a "safe" site: social media, image search, a chat app | Blocklists can't see it | Covered wherever it shows up |
| Use an app instead of a browser | Usually not filtered | Covered in every app |
| Delete the extension or quit the app | Done in seconds | You're not an admin any more, and leaving takes the wait you chose |
| Ask whoever holds the password | One weak moment, one text | Nobody holds a password. Only a friend you chose to add, if you added one, can shorten your wait, and only to a day. Not even we can |
| Change your Mac's clock | Fools some timers | The wait is checked against a public time signal |
| Wipe the Mac | Works | Works here too. That's an evening of work, not a click |

**About that last row:** wiping is the one way around it we haven't closed yet, and we're working on it. If you know macOS well and have ideas for making a wipe harder to use as an escape hatch, we'd love your help. Open an issue or start with [CONTRIBUTING.md](CONTRIBUTING.md). If your idea involves a way around the lock, please send it privately through [SECURITY.md](SECURITY.md) instead.

## How it works

- **Everything stays on your Mac.** There's no account and no server, and your screen is checked on the device itself. Nothing you see is ever uploaded.
- **It's free forever.** No trial, no card, no account. The core will never be put behind a paywall ([CORE.md](CORE.md)).
- **The code is public,** and the lock is designed to hold even though anyone can read every line.

## What it can't do

- Wiping your Mac removes it.
- It can miss something, and it sometimes covers something harmless.
- It can't check protected video, like films in streaming apps, because macOS hides it from screen capture.
- It only protects this Mac, not your phone, a TV or another computer.

## Where things stand

This is an early preview, and there's no download yet. The screen cover is built and tested in the lab; the lock is being built now. For the details, see [docs/STEP-1-STATUS.md](docs/STEP-1-STATUS.md). What isn't built or proven yet is listed plainly in [docs/KNOWN-GAPS.md](docs/KNOWN-GAPS.md).

The first full release brings the screen cover; the lock, with your wait and the optional friend; site blocking through the browser extension and your Mac's hosts file; optional switches to turn off ways of sending files, like AirDrop; and safe admin tasks through Apple's own routes. After it come cinema mode for films in your browser, checking and locking downloaded files, a filter for your whole Mac's network, instant installs of parts from known vendors, and the Hardcore lock.

## Our promise

> SafeSight Mac is free, open-source software that runs entirely on your Mac. It covers explicit images and video on your screen, and once it's on, it stays on until a waiting period you chose ahead of time has passed. If you choose to add a friend, they can shorten that wait, but never to less than a day. Nobody else can, including us. It isn't perfect: wiping your Mac removes it, it can miss something or cover something harmless, and it only protects this Mac. It's an early release built with the help of AI, so keep a backup.

## Terms and risks

Please read [TERMS-AND-RISKS.md](TERMS-AND-RISKS.md) before you install it. It's short.

## Found a weakness?

Please tell us privately rather than in a public issue. [SECURITY.md](SECURITY.md) explains how.

## Contributing

Help is welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Every commit needs a `Signed-off-by` line ([DCO](DCO)).

## Licence

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
