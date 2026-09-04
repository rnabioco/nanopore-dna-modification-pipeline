# Models

`resources/models/` holds the ONT basecalling and modified-base models
downloaded by name (`pixi run install-models`; gitignored) and, under
`custom/`, any locally trained dorado-format modified-base models that are
vendored with the pipeline (tracked).

The stack a run uses is resolved from `models:` in the config by
`workflow/scripts/models.py` (`pixi run list-models`, `pixi run check-models`).

## Vendoring a custom model

A dorado-compatible modified-base model is a directory with `config.toml`
plus the weights, as produced by `remora model export` (Remora) or shipped by
ONT. Put it under `resources/models/custom/<name>@v<version>/` with a
`README.md` stating training data, basecalling model it pairs with, canonical
base and motif, and how it was validated. Then list it:

```yaml
models:
  custom:
    - resources/models/custom/my_mod_model@v0.1.0
```

`models.py` reads `[modbases] motif` / `motif_offset` from `config.toml` to
enforce one model per canonical base in the stack.
