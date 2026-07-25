# Documentation

The documentation site uses MkDocs and Material for MkDocs. Existing READMEs
remain the source of truth for directory guides and runbooks; thin pages under
`docs/` include them in the generated site.

## Write in the right place

- Keep a short comment next to code when it explains a constraint that is
  necessary to edit the code safely.
- Put setup, recovery, and day-two procedures in the nearest README.
- Put tradeoffs, rejected alternatives, and historical reasoning in
  `docs/decisions/`.
- Put procedures that span multiple components in `docs/operations/`.
- Link to a decision page from code when the rationale is useful but too large
  for an inline comment.

Generated reference pages come from `scripts/generate_reference.py`. Extend the
generator when a manifest relationship is more useful as a table than as prose.
Do not commit generated output.

## Preview locally

```bash
uv sync
uv run mkdocs serve
```

Open the local URL printed by MkDocs. The server watches both `docs/` and the
included READMEs.

## Validate

```bash
uv lock --check
uv run mkdocs build --strict
```

The generated `site/` directory is disposable and must not be committed.
