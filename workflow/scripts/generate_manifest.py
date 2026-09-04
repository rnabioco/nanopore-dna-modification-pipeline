"""Write ``manifest.json`` into the output directory: what ran, on what, with which tools."""

from __future__ import annotations

import datetime
import getpass
import json
import os
import re
import socket
import subprocess


def get_pipeline_version(pipeline_dir: str) -> dict:
    try:
        from git import Repo

        repo = Repo(pipeline_dir)
        commit = repo.head.commit
        tags = [t.name for t in repo.tags if t.commit == commit]
        try:
            branch = repo.active_branch.name
        except TypeError:
            branch = None
        return {
            "git_commit": str(commit),
            "git_tag": tags[0] if tags else None,
            "git_branch": branch,
            "git_dirty": repo.is_dirty(),
        }
    # Deliberately broad: provenance must never fail the run (no checkout, no
    # git binary, an empty repository ...).
    except Exception:  # noqa: BLE001
        return {
            "git_commit": None,
            "git_tag": None,
            "git_branch": None,
            "git_dirty": None,
        }


def parse_pixi_lock_version(lock_path: str, package_name: str) -> str | None:
    if not os.path.exists(lock_path):
        return None
    pattern = re.compile(
        rf"/{re.escape(package_name)}-([0-9][0-9a-zA-Z.\-]*)-[^/]+\.(?:conda|tar\.bz2)"
    )
    with open(lock_path) as fh:
        for line in fh:
            m = pattern.search(line)
            if m:
                return m.group(1)
    return None


def get_command_version(cmd: list[str]) -> str | None:
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30, check=False
        )
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return None
    output = (result.stdout.strip() or result.stderr.strip()).splitlines()
    return output[0] if output else None


def get_tool_versions(pipeline_dir: str, config: dict) -> dict:
    lock = os.path.join(pipeline_dir, "pixi.lock")
    versions = {}
    for tool, pkg in {
        "samtools": "samtools",
        "minimap2": "minimap2",
        "modkit": "ont-modkit",
        "mosdepth": "mosdepth",
        "snakemake": "snakemake",
    }.items():
        v = parse_pixi_lock_version(lock, pkg)
        if v:
            versions[tool] = v
    dorado_version = (config.get("dorado") or {}).get("version")
    if dorado_version:
        versions["dorado"] = str(dorado_version)
        dorado_bin = os.path.join(
            pipeline_dir,
            "resources",
            "tools",
            "dorado",
            str(dorado_version),
            "bin",
            "dorado",
        )
        if os.path.exists(dorado_bin):
            versions["dorado_reported"] = get_command_version([dorado_bin, "--version"])
    if config.get("escpod_version"):
        versions["escpod"] = str(config["escpod_version"])
    dnascent = config.get("dnascent") or {}
    if dnascent.get("enabled"):
        versions["dnascent"] = str(dnascent.get("version"))
    return versions


def extract_config_params(config: dict) -> dict:
    keep = (
        "samples",
        "output_directory",
        "reference",
        "dorado",
        "models",
        "align",
        "modkit",
        "dmr",
        "qc",
        "dnascent",
        "custom",
        "cleanup_intermediates",
    )
    return {k: config[k] for k in keep if k in config}


def extract_sample_info(samples: dict) -> dict:
    return {
        "count": len(samples),
        "names": list(samples),
        "inputs": {
            s: [
                {"path": i["path"], "barcode": i.get("barcode")}
                for i in info.get("inputs", [])
            ]
            for s, info in samples.items()
        },
        "references": {s: info.get("reference") for s, info in samples.items()},
    }


def generate_manifest(
    config, samples, status, start_time, output_dir, pipeline_dir, models=None
):
    manifest = {
        "manifest_version": "1.0",
        "pipeline": {
            "name": "nanopore-dna-modification-pipeline",
            **get_pipeline_version(pipeline_dir),
        },
        "execution": {
            "timestamp_start": start_time,
            "timestamp_end": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": status,
            "hostname": socket.gethostname(),
            "user": getpass.getuser(),
            "working_directory": os.getcwd(),
        },
        "config": extract_config_params(config),
        "resolved_models": models,
        "samples": extract_sample_info(samples),
        "tools": get_tool_versions(pipeline_dir, config),
    }
    os.makedirs(output_dir, exist_ok=True)
    path = os.path.join(output_dir, "manifest.json")
    with open(path, "w") as fh:
        json.dump(manifest, fh, indent=2)
    print(f"Pipeline manifest written to: {path}")
