# Contributing

## Conventions

- Branch per change (worktree under `.claude/worktrees/` if you use Claude
  Code), Conventional Commits, land through a pull request. Nothing goes on
  `main` directly.
- `pixi run fmt` before committing; CI runs `pixi run lint`
  (`snakefmt --check`, `ruff check` + `ruff format --check`, `yamllint`).
- Tabular outputs are compressed (`.tsv.gz`, bgzip + tabix for BEDs). POD5
  and BAM are never copied into the repository or the output tree.
- A cluster resource number in a profile carries a comment saying what was
  measured, when, on what. Unmeasured numbers say so.

## Running the checks

```bash
pixi run lint
pixi run -e test test-unit        # pytest over workflow/scripts, no data needed
pixi run dry-run-all              # plain, demux + MinKNOW modes, DNAscent DAGs
```

Heavy work (a real run, a fixture build, `pixi run test` on the GPU) goes in
its own Slurm allocation, never in a login or interactive shell.

## Adding a rule

1. Put it in the matching file under `workflow/rules/`
   (`basecall`, `align`, `modcall`, `qc`, `dnascent`, `custom`).
2. Use the path helpers in `common.smk` (`final_bam`, `pileup_bed`,
   `staged_fasta`, ...) rather than spelling paths.
3. Add its output to `pipeline_outputs()` if it is a final target.
4. Add an entry to both cluster profiles under `set-resources`.
5. Extend a dry-run config so CI builds the new part of the DAG.

## Adding a model

ONT models: list them under `models.modified_bases` (a short code needs a
pin in `models.mod_versions` for its simplex model). Custom models: a
dorado-format directory under `resources/models/custom/<name>@v<version>/`
with a README; see [Models](../user-guide/models.md).

## Documentation

The site is built with [zensical](https://zensical.org) from `docs/` and
`zensical.toml`:

```bash
pixi run -e docs docs-serve       # live preview at http://127.0.0.1:8000
pixi run -e docs docs-build       # strict build into site/
```

It deploys to GitHub Pages on every push to `main` that touches `docs/`.

## Releasing

Bump `version` in `pixi.toml`, move `[Unreleased]` in `CHANGELOG.md` to the
new version with the date, commit as `chore(release): vX.Y.Z`, tag with an
annotated `vX.Y.Z` tag on `main`, and `gh release create`.
