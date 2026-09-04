"""Shared fixtures: make workflow/scripts importable and provide a config factory."""

from __future__ import annotations

import copy
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "workflow" / "scripts"))


@pytest.fixture(scope="session")
def base_config() -> dict:
    with open(REPO_ROOT / "config" / "config-base.yml") as fh:
        return yaml.safe_load(fh)


@pytest.fixture
def config(base_config) -> dict:
    return copy.deepcopy(base_config)


@pytest.fixture
def model_dir(tmp_path):
    """Factory: a fake dorado model directory with an optional modbases motif."""

    def make(name: str, motif: str | None = None, offset: int = 0) -> Path:
        d = tmp_path / "models" / name
        d.mkdir(parents=True)
        body = "[modbases]\n" + (
            f'motif = "{motif}"\nmotif_offset = {offset}\n' if motif else ""
        )
        (d / "config.toml").write_text(body)
        return d

    return make
