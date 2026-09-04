# Models

The basecalling **model stack** is one simplex model plus any number of
modified-base models, resolved from `models:` by `workflow/scripts/models.py`.
The same code drives `pixi run setup` (what to download), the Snakefile (what
to pass to `dorado basecaller`) and `pixi run check-models`.

```yaml
models:
  simplex: dna_r10.4.1_e8.2_400bps_sup@v5.2.0
  modified_bases: [5mC_5hmC, 6mA]
  custom: []
```

```bash
pixi run list-models  --configfile config/my-project.yml
pixi run check-models --configfile config/my-project.yml
pixi run install-models --configfile config/my-project.yml
```

## ONT models

`dorado download --list-yaml` names them. As of dorado 2.1.2 the current DNA
models and their modified-base companions are:

| Simplex model | Modified-base models (`<simplex>_<mod>@<ver>`) |
|---|---|
| `dna_r10.4.1_e8.2_400bps_sup@v5.2.0` (default) | `4mC_5mC@v1`, `5mC_5hmC@v2`, `5mCG_5hmCG@v2`, `6mA@v1` |
| `dna_r10.4.1_e8.2_400bps_hac@v6.0.0` | `4mC_5mC@v1`, `5mC_5hmC@v1`, `5mCG_5hmCG@v1`, `6mA@v1` |
| `dna_r10.4.1_e8.2_400bps_sup@v5.0.0` | `4mC_5mC@v3`, `5mC_5hmC@v3`, `5mCG_5hmCG@v3`, `6mA@v3` |

`modified_bases` entries are either a **short code** (`5mC_5hmC`), expanded to
the version pinned in `models.mod_versions` for the simplex model, or a
**full name** (`dna_r10.4.1_e8.2_400bps_sup@v5.2.0_5mC_5hmC@v2`). The base
config pins versions for the three simplex models above; another simplex
model needs its own `mod_versions` entry or full names.

What the codes mean:

| Code | Calls | Canonical base | Context |
|---|---|---|---|
| `5mC_5hmC` | 5-methylcytosine, 5-hydroxymethylcytosine | C | all |
| `5mCG_5hmCG` | same | C | CpG only |
| `4mC_5mC` | N4-methylcytosine, 5-methylcytosine | C | all |
| `6mA` | N6-methyladenine | A | all |

## Rules the resolver enforces

1. **One model per canonical base.** dorado runs at most one modified-base
   model per base. `5mC_5hmC` + `6mA` stack; `5mC_5hmC` + `4mC_5mC` is
   refused at DAG construction.
2. **Modified-base models belong to their simplex model.** A `hac@v6.0.0`
   6mA model with a `sup@v5.2.0` simplex model is refused.
3. **Swapping a model reruns basecalling.** Each model's `config.toml` is an
   input of the basecall rule.

## Custom models

A dorado-format modified-base model is a directory holding `config.toml` and
the weights, as written by `remora model export` (Remora) or shipped by ONT.
List it under `models.custom`:

```yaml
models:
  modified_bases: [5mC_5hmC]
  custom:
    - resources/models/custom/lab_6mA@v0.3.0
    - {name: spikein_caller, path: /beevol/data/models/spikein@v1}
```

The resolver reads `[modbases] motif` / `motif_offset` from `config.toml` to
know the canonical base for rule 1; a model without one is accepted with a
warning. Custom models are passed to dorado together with the ONT ones as
`--modified-bases-models a,b,c`, so they must have been trained against the
configured simplex model.

Vendor a custom model under `resources/models/custom/<name>@v<version>/`
with a `README.md` (training data, paired simplex model, canonical base and
motif, validation), and commit it: `resources/models/custom/` is the one
tracked directory under `resources/models/`.

## Where models live

`models.directory` (default `resources/models`, gitignored). ONT models are
downloaded there by name; a model already present is never re-downloaded. The
resolved directories are recorded in `manifest.json` for every run.
