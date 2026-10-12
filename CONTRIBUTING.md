# Contributing to Bipuu

Bipuu is in its foundation phase (see [docs/ROADMAP.md](docs/ROADMAP.md)); please open an issue before
starting significant work.

- Keep changes small and reviewable; one concern per commit.
- Run `for s in scripts/test-*.sh; do bash $s; done` and `scripts/forbidden-content-check.sh` before pushing.
- No telemetry, no third-party default endpoints, no secrets in git.
- Never reuse third-party creative assets. The Coucou/Mochi identity is explicitly out of bounds
  (see [docs/IP_MIGRATION.md](docs/IP_MIGRATION.md)).
- By contributing you agree your contribution is licensed under the MIT licence of this repository.
