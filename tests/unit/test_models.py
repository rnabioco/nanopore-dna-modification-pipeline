import models
import pytest


def test_parse_ont_name_simplex_and_mod():
    assert models.parse_ont_name("dna_r10.4.1_e8.2_400bps_sup@v5.2.0") == (
        "dna_r10.4.1_e8.2_400bps_sup@v5.2.0",
        None,
        None,
    )
    assert models.parse_ont_name("dna_r10.4.1_e8.2_400bps_sup@v5.2.0_5mC_5hmC@v2") == (
        "dna_r10.4.1_e8.2_400bps_sup@v5.2.0",
        "5mC_5hmC",
        "v2",
    )
    with pytest.raises(models.ModelError):
        models.parse_ont_name("not a model")


def test_expand_short_code_uses_pinned_version(config):
    simplex = config["models"]["simplex"]
    name = models.expand_mod_name(simplex, "5mC_5hmC", config["models"]["mod_versions"])
    assert name == f"{simplex}_5mC_5hmC@v2"
    assert models.canonical_of_ont(name) == "C"


def test_expand_rejects_mod_for_other_simplex(config):
    with pytest.raises(models.ModelError, match="belongs to simplex model"):
        models.expand_mod_name(
            config["models"]["simplex"],
            "dna_r10.4.1_e8.2_400bps_hac@v6.0.0_6mA@v1",
            config["models"]["mod_versions"],
        )


def test_expand_unknown_short_code(config):
    with pytest.raises(models.ModelError, match="no pinned version"):
        models.expand_mod_name(
            config["models"]["simplex"], "7mG", config["models"]["mod_versions"]
        )


def test_resolve_default_stack(config, tmp_path):
    config["models"]["directory"] = str(tmp_path / "models")
    stack = models.resolve(config, pipeline_dir=str(tmp_path))
    assert stack.simplex.name == config["models"]["simplex"]
    assert [m.name for m in stack.mods] == [
        f"{stack.simplex.name}_5mC_5hmC@v2",
        f"{stack.simplex.name}_6mA@v1",
    ]
    assert stack.mod_paths_csv.count(",") == 1
    assert all(not m.present for m in stack.all)
    assert len(stack.missing) == 3


def test_resolve_rejects_two_models_on_one_canonical_base(config, tmp_path):
    config["models"]["directory"] = str(tmp_path / "models")
    config["models"]["modified_bases"] = ["5mC_5hmC", "4mC_5mC"]
    with pytest.raises(models.ModelError, match="both call canonical base C"):
        models.resolve(config, pipeline_dir=str(tmp_path))


def test_custom_model_canonical_from_config_toml(config, tmp_path, model_dir):
    custom = model_dir("my_6ma_model", motif="A", offset=0)
    config["models"]["directory"] = str(tmp_path / "models")
    config["models"]["modified_bases"] = ["5mC_5hmC"]
    config["models"]["custom"] = [{"name": "my6mA", "path": str(custom)}]
    stack = models.resolve(config, pipeline_dir=str(tmp_path))
    assert stack.mods[-1].kind == "custom_mod"
    assert stack.mods[-1].canonical == "A"
    assert stack.mods[-1].present

    # ...and a custom C-caller collides with the ONT 5mC model
    custom_c = model_dir("my_c_model", motif="CG", offset=0)
    config["models"]["custom"] = [str(custom_c)]
    with pytest.raises(models.ModelError, match="canonical base C"):
        models.resolve(config, pipeline_dir=str(tmp_path))


def test_custom_model_without_motif_warns_not_fails(config, tmp_path, model_dir):
    custom = model_dir("opaque_model")
    config["models"]["directory"] = str(tmp_path / "models")
    config["models"]["custom"] = [str(custom)]
    stack = models.resolve(config, pipeline_dir=str(tmp_path))
    warnings = models.validate(stack)
    assert any("canonical base unknown" in w for w in warnings)


def test_deep_update_merges_nested():
    base = {"models": {"simplex": "a", "modified_bases": ["x"]}, "k": 1}
    over = {"models": {"modified_bases": ["y"]}}
    merged = models.deep_update(base, over)
    assert merged["models"]["simplex"] == "a"
    assert merged["models"]["modified_bases"] == ["y"]
    assert merged["k"] == 1


def test_cli_get_and_list(capsys):
    assert models.main(["get", "dorado.version"]) == 0
    assert capsys.readouterr().out.strip() == "2.1.2"
    assert models.main(["list"]) == 0
    out = capsys.readouterr().out
    assert "simplex" in out and "6mA" in out
    assert models.main(["get", "nope.nope"]) == 1
