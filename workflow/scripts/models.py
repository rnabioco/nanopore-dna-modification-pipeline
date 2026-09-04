"""Resolve the dorado model stack named in the pipeline config.

This is the single source of truth for which models a run uses. Three
consumers share it, so they cannot disagree:

- ``pixi run setup`` / ``install-models`` download what it resolves,
- the Snakefile hands the resolved directories to ``dorado basecaller``,
- ``pixi run check-models`` verifies the stack before a cluster submission.

Vocabulary
----------
``models.simplex``          the ONT simplex model, e.g.
                            ``dna_r10.4.1_e8.2_400bps_sup@v5.2.0``. A local
                            directory path is also accepted.
``models.modified_bases``   ONT modified-base models to STACK on the simplex
                            model. Entries are either a full ONT name
                            (``dna_..._sup@v5.2.0_5mC_5hmC@v2``) or a short
                            code (``5mC_5hmC``) expanded through
                            ``models.mod_versions`` to a pinned version.
``models.custom``           local dorado-format modified-base model
                            directories (e.g. exported from Remora), stacked
                            alongside the ONT ones. A string path or
                            ``{name: ..., path: ...}``.

dorado accepts several modified-base models in one run as long as they
call DIFFERENT canonical bases (``5mC_5hmC`` + ``6mA`` is fine; ``5mC_5hmC``
+ ``4mC_5mC`` both call C and conflict). ``validate`` enforces that here, at
DAG construction, rather than an hour into a GPU job.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
from dataclasses import asdict, dataclass, field

import yaml

PIPELINE_DIR = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
DEFAULT_CONFIG_BASE = os.path.join(PIPELINE_DIR, "config", "config-base.yml")

# Canonical base called by each modification code in dorado's
# ``--modified-bases`` vocabulary (dorado 2.1 `basecaller --help`).
MOD_CANONICAL: dict[str, str] = {
    # DNA
    "5mC_5hmC": "C",
    "5mCG_5hmCG": "C",
    "4mC_5mC": "C",
    "5mC": "C",
    "5mCG": "C",
    "6mA": "A",
    # RNA (listed so a mistaken RNA code is still recognised and rejected
    # by canonical-base collision rather than by a KeyError)
    "m5C": "C",
    "m5C_2OmeC": "C",
    "m6A": "A",
    "m6A_DRACH": "A",
    "inosine_m6A": "A",
    "inosine_m6A_2OmeA": "A",
    "pseU": "T",
    "pseU_2OmeU": "T",
    "2OmeG": "G",
}

# ``<simplex>@v<ver>`` optionally followed by ``_<mod>@v<ver>``. The simplex
# part has exactly one ``@``; everything after the second underscore-``@``
# pair is the modification.
ONT_MODEL_RE = re.compile(
    r"^(?P<simplex>[^@\s]+@v[0-9][0-9.]*)(?:_(?P<mod>[^@\s]+)@(?P<modver>v[0-9][0-9.]*))?$"
)


class ModelError(Exception):
    """A config that cannot be resolved into a runnable model stack."""


@dataclass
class ResolvedModel:
    name: str
    path: str
    kind: str  # simplex | ont_mod | custom_mod
    source: str  # ont | local
    canonical: str | None = None

    @property
    def present(self) -> bool:
        return os.path.isdir(self.path)


@dataclass
class ModelStack:
    simplex: ResolvedModel
    mods: list[ResolvedModel] = field(default_factory=list)
    models_dir: str = ""

    @property
    def all(self) -> list[ResolvedModel]:
        return [self.simplex, *self.mods]

    @property
    def ont(self) -> list[ResolvedModel]:
        return [m for m in self.all if m.source == "ont"]

    @property
    def missing(self) -> list[ResolvedModel]:
        return [m for m in self.all if not m.present]

    @property
    def mod_paths_csv(self) -> str:
        """The value for ``dorado basecaller --modified-bases-models``."""
        return ",".join(m.path for m in self.mods)

    def to_dict(self) -> dict:
        return {
            "models_dir": self.models_dir,
            "simplex": asdict(self.simplex),
            "modified_bases": [asdict(m) for m in self.mods],
        }


# ---------------------------------------------------------------------------
# Config loading (deep merge, the way snakemake merges --configfile)
# ---------------------------------------------------------------------------
def deep_update(base: dict, override: dict) -> dict:
    out = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_update(out[key], value)
        else:
            out[key] = value
    return out


def load_config(
    configfiles: list[str] | None = None, config_base: str = DEFAULT_CONFIG_BASE
) -> dict:
    with open(config_base) as fh:
        config = yaml.safe_load(fh) or {}
    for path in configfiles or []:
        with open(path) as fh:
            config = deep_update(config, yaml.safe_load(fh) or {})
    return config


def get_key(config: dict, dotted: str):
    node = config
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(dotted)
        node = node[part]
    return node


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------
def parse_ont_name(name: str) -> tuple[str, str | None, str | None]:
    """Split an ONT model name into (simplex, mod, modver)."""
    m = ONT_MODEL_RE.match(name)
    if not m:
        raise ModelError(
            f"{name!r} is not an ONT model name (expected e.g. "
            "dna_r10.4.1_e8.2_400bps_sup@v5.2.0 or "
            "dna_r10.4.1_e8.2_400bps_sup@v5.2.0_5mC_5hmC@v2)"
        )
    return m.group("simplex"), m.group("mod"), m.group("modver")


def expand_mod_name(simplex: str, entry: str, mod_versions: dict) -> str:
    """Turn a ``modified_bases`` entry into a full, pinned ONT model name."""
    if "@" in entry:
        prefix, mod, _ = parse_ont_name(entry)
        if mod is None:
            raise ModelError(
                f"{entry!r} names a simplex model, not a modified-base model"
            )
        if prefix != simplex:
            raise ModelError(
                f"modified-base model {entry!r} belongs to simplex model {prefix!r}, "
                f"but models.simplex is {simplex!r}; modified-base models only run on "
                "the simplex model they were trained against"
            )
        return entry
    versions = mod_versions.get(simplex, {})
    if entry not in versions:
        known = ", ".join(sorted(versions)) or "(none)"
        raise ModelError(
            f"no pinned version for modification {entry!r} on {simplex!r}. "
            f"Known short codes for this simplex model: {known}. Either add "
            f"models.mod_versions.{simplex}.{entry}, or give the full model name."
        )
    return f"{simplex}_{entry}@{versions[entry]}"


def canonical_of_ont(name: str) -> str | None:
    _, mod, _ = parse_ont_name(name)
    if mod is None:
        return None
    return MOD_CANONICAL.get(mod)


def canonical_of_dir(path: str) -> str | None:
    """Read the canonical base from a dorado model directory's config.toml.

    dorado (and Remora's dorado export) write ``[modbases] motif`` plus
    ``motif_offset``; the canonical base is the motif character at the
    offset. Missing or unreadable means None, and validation then skips the
    collision check for that model with a warning rather than refusing.
    """
    cfg = os.path.join(path, "config.toml")
    if not os.path.isfile(cfg):
        return None
    try:
        with open(cfg, "rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return None
    modbases = data.get("modbases", {})
    motif = modbases.get("motif")
    if not motif:
        return None
    offset = int(modbases.get("motif_offset", 0))
    if 0 <= offset < len(motif):
        return motif[offset].upper()
    return None


def _abspath(path: str, pipeline_dir: str) -> str:
    return path if os.path.isabs(path) else os.path.join(pipeline_dir, path)


def resolve(config: dict, pipeline_dir: str = PIPELINE_DIR) -> ModelStack:
    models = config.get("models") or {}
    if "simplex" not in models:
        raise ModelError("models.simplex is unset")
    models_dir = _abspath(models.get("directory", "resources/models"), pipeline_dir)
    mod_versions = models.get("mod_versions") or {}

    simplex_entry = str(models["simplex"])
    if os.path.isdir(_abspath(simplex_entry, pipeline_dir)):
        simplex_path = os.path.abspath(_abspath(simplex_entry, pipeline_dir))
        simplex = ResolvedModel(
            os.path.basename(simplex_path.rstrip("/")), simplex_path, "simplex", "local"
        )
        simplex_name_for_mods = simplex.name
    else:
        parse_ont_name(simplex_entry)
        simplex = ResolvedModel(
            simplex_entry, os.path.join(models_dir, simplex_entry), "simplex", "ont"
        )
        simplex_name_for_mods = simplex_entry

    mods: list[ResolvedModel] = []
    for entry in models.get("modified_bases") or []:
        name = expand_mod_name(simplex_name_for_mods, str(entry), mod_versions)
        mods.append(
            ResolvedModel(
                name,
                os.path.join(models_dir, name),
                "ont_mod",
                "ont",
                canonical_of_ont(name),
            )
        )

    for entry in models.get("custom") or []:
        if isinstance(entry, dict):
            path = entry.get("path")
            name = entry.get("name") or os.path.basename(str(path).rstrip("/"))
        else:
            path = str(entry)
            name = os.path.basename(path.rstrip("/"))
        if not path:
            raise ModelError(f"models.custom entry without a path: {entry!r}")
        path = os.path.abspath(_abspath(path, pipeline_dir))
        mods.append(
            ResolvedModel(name, path, "custom_mod", "local", canonical_of_dir(path))
        )

    stack = ModelStack(simplex=simplex, mods=mods, models_dir=models_dir)
    validate(stack)
    return stack


def validate(stack: ModelStack) -> list[str]:
    """Refuse a stack dorado would refuse (or silently misuse). Returns warnings."""
    warnings: list[str] = []
    seen: dict[str, str] = {}
    names = [m.name for m in stack.mods]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        raise ModelError(f"modified-base model listed more than once: {sorted(dupes)}")
    for m in stack.mods:
        if m.canonical is None:
            warnings.append(
                f"{m.name}: canonical base unknown (no readable config.toml motif); "
                "skipping the collision check for it"
            )
            continue
        if m.canonical in seen:
            raise ModelError(
                f"modified-base models {seen[m.canonical]!r} and {m.name!r} both call "
                f"canonical base {m.canonical}; dorado runs at most one model per "
                "canonical base. Drop one of them."
            )
        seen[m.canonical] = m.name
    return warnings


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
def download_missing(stack: ModelStack, dorado: str = "dorado") -> list[str]:
    """``dorado download`` every ONT model that is not on disk yet."""
    os.makedirs(stack.models_dir, exist_ok=True)
    downloaded = []
    for m in stack.ont:
        if m.present:
            print(f"present: {m.name}")
            continue
        print(f"downloading {m.name} -> {stack.models_dir}", flush=True)
        subprocess.run(
            [
                dorado,
                "download",
                "--model",
                m.name,
                "--models-directory",
                stack.models_dir,
            ],
            check=True,
        )
        if not m.present:
            raise ModelError(
                f"dorado download reported success but {m.path} does not exist"
            )
        downloaded.append(m.name)
    for m in stack.all:
        if m.source == "local" and not m.present:
            raise ModelError(f"local model directory not found: {m.path} ({m.name})")
    return downloaded


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--configfile",
        action="append",
        default=[],
        help="project config layered over config/config-base.yml (repeatable, like snakemake)",
    )
    parser.add_argument("--config-base", default=DEFAULT_CONFIG_BASE)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list", help="print the resolved model stack")
    sub.add_parser(
        "check", help="verify every resolved model is present and the stack is valid"
    )
    sub.add_parser("json", help="dump the resolved stack as JSON")
    sub.add_parser("download", help="dorado download every missing ONT model")
    p_get = sub.add_parser("get", help="print one config value by dotted key")
    p_get.add_argument("key")
    args = parser.parse_args(argv)

    config = load_config(args.configfile, args.config_base)

    if args.command == "get":
        try:
            value = get_key(config, args.key)
        except KeyError:
            print(f"config key not found: {args.key}", file=sys.stderr)
            return 1
        print(value if not isinstance(value, (dict, list)) else json.dumps(value))
        return 0

    try:
        stack = resolve(config)
        warnings = validate(stack)
    except ModelError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    for w in warnings:
        print(f"WARNING: {w}", file=sys.stderr)

    if args.command == "json":
        print(json.dumps(stack.to_dict(), indent=2))
        return 0
    if args.command == "list":
        for m in stack.all:
            status = "present" if m.present else "MISSING"
            canon = f" (canonical {m.canonical})" if m.canonical else ""
            print(f"{m.kind:10s} {status:8s} {m.name}{canon}\n{'':19s}{m.path}")
        return 0
    if args.command == "check":
        missing = stack.missing
        for m in missing:
            hint = (
                "pixi run install-models"
                if m.source == "ont"
                else "check models.custom path"
            )
            print(f"MISSING: {m.name} -> {m.path}  ({hint})", file=sys.stderr)
        if missing:
            return 1
        print(f"OK: {len(stack.all)} model(s) present, stack valid")
        return 0
    if args.command == "download":
        try:
            done = download_missing(stack)
        except (ModelError, subprocess.CalledProcessError) as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1
        print(f"downloaded {len(done)} model(s)")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
