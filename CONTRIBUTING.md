# Contributing

Thank you for helping. Please read the [code of conduct](CODE_OF_CONDUCT.md) first. If you use an AI coding tool, point it at [AGENTS.md](AGENTS.md). New here? [ARCHITECTURE.md](ARCHITECTURE.md) shows how the parts fit together, and [docs/HANDOVER.md](docs/HANDOVER.md) covers adopting the project as a whole.

## Where to start

Issues labelled **good first issue** and **help wanted** are the best places to begin: the website, the docs, tests and the app's look and wording. Changes to the lock (`keeper/`, `opener/`) are welcome too, but they need a second reader and take longer to review.

## Rules for every change

1. **Sign off every commit** (`git commit -s`). The sign-off says you agree to the [DCO](DCO).
2. **Every source file starts with an SPDX licence line**, for example `// SPDX-License-Identifier: Apache-2.0`.
3. **New dependencies must use an allowed licence** (Apache-2.0, MIT, BSD, ISC or similar). Nothing under GPL, AGPL or a non-commercial licence.
4. **Protections must hold with the code public.** No change may rely on secret code, thresholds or heuristics.
5. **Faults never punish.** Any failure in a check leads to more covering, never to a locked screen, a logout or a report to anyone.
6. **Lock-core changes need a second reader.** Any change to the keeper, the time lock or the update gate is read and approved by a second reviewer before it merges.
7. **No explicit material, ever,** in issues, tests, fixtures or examples. Use synthetic test patterns.

## Weaknesses

Never in public. See [SECURITY.md](SECURITY.md).

## Words we never use

The project never says "can't be bypassed", "100%", "blocks all", "treats addiction" or "nobody can ever unlock it". The app's text is checked for these (`AppTextTests`).
