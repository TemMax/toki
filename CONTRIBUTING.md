# Contributing to Toki

Thanks for helping improve Toki. This repository publishes the source snapshot for each release. Day-to-day development and release signing happen in a private repository, so the public `main` branch contains release snapshots rather than individual development commits.

## Report a problem or propose a change

Open a GitHub issue with the Toki version, macOS version, expected and actual behavior, and steps to reproduce. Please remove account identifiers, tokens, private transcript content, and logs containing personal data. For a security vulnerability, follow [SECURITY.md](SECURITY.md) instead of filing a public issue.

For a larger feature, open an issue first so we can discuss scope before you spend time implementing it.

## Submit a patch

1. Fork this repository and branch from the latest public `main` snapshot.
2. Make a focused change and add meaningful tests when behavior changes. Keep changes to public code and documentation; do not add credentials, personal data, private research, or `AGENTS.md`/`CLAUDE.md` files.
3. Run `swift test` for code changes, and build the app with the documented unsigned build recipe when app code changes. If you cannot run a check, state what remains unverified.
4. Open a pull request against public `main`. Explain the problem, approach, tests, and any user-visible behavior change. Link the issue when there is one.

Maintainers review public pull requests here. An accepted patch is applied to the private development repository and appears in a later public release snapshot. We close the contribution PR with an explanation and link to the release when it ships; we do not merge contribution PRs directly into the snapshot branch. This also means GitHub may not show a merged PR or a separate public commit for your contribution. We credit your GitHub handle in the public release notes unless you ask for a different attribution or no public credit. We may adapt a patch during integration and will discuss substantial changes with you.

## Licensing

Toki-owned code and the AppIcon and BrandMark artwork in this repository are licensed under Apache License 2.0; see `LICENSE`. By submitting a contribution, you confirm that you have the right to submit it under that license. Do not include third-party code, images, or other material unless its license is compatible and you identify the source and required notices in the PR. Contributions remain yours; no copyright assignment or separate contributor license agreement is required.

Some bundled dependencies retain their own licenses and notices. The license does not grant trademark rights in the Toki name or logo.
