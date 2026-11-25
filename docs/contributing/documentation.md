# Documentation

The documentation site is built with [Zensical](https://zensical.org), configured
in `zensical.toml`. Existing READMEs remain the source of truth for directory
guides and runbooks; thin pages under `docs/` include them with
`{% include-markdown "../../path/README.md" %}`.

Included READMEs are inlined as-is: Zensical never rewrites their relative
links. A link between two READMEs that are both included at matching paths
(`omni-server/` and `ansible/omni-host/`, for example) works on GitHub and on
the site. A link from an included README into `docs/` doesn't; use the page's
GitHub URL (`https://github.com/isaiah-harville/homelab/blob/main/docs/...`)
instead. Add any README you include to `watch` in `zensical.toml` so
`zensical serve` rebuilds when it changes.

## Write in the right place

- Keep a short comment next to code when it explains a constraint that is
  necessary to edit the code safely.
- Put setup, recovery, and day-two procedures in the nearest README.
- Put tradeoffs, rejected alternatives, and historical reasoning in
  `docs/decisions/`.
- Put procedures that span multiple components in `docs/operations/`.
- Link to a decision page from code when the rationale is useful but too large
  for an inline comment.

Generated reference pages come from `scripts/generate_reference.py`, which
writes them into `docs/reference/` before the build (Zensical has no gen-files
plugin). The output is gitignored. Extend the generator when a manifest
relationship is more useful as a table than as prose.

## Preview locally

```bash
uv sync
uv run python scripts/generate_reference.py
uv run zensical serve
```

Open the local URL printed by Zensical. The server watches `docs/` and the
paths listed under `watch`; re-run the generator to refresh reference pages.

## Validate

```bash
uv lock --check
uv run python scripts/generate_reference.py
uv run zensical build --strict
```

The generated `site/` directory is disposable and must not be committed.
