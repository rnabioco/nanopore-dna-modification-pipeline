"""POD5 staging, dorado basecalling (per sample or per barcoded run), demux,
and collection of MinKNOW-basecalled BAMs. Every path converges on
bam/basecall/{sample}/{sample}.bam."""


def dorado_common_opts():
    d = config["dorado"]
    opts = [f"--device {d.get('device', 'cuda:all')}"]
    if d.get("emit_moves", True):
        opts.append("--emit-moves")
    if int(d.get("min_qscore", 0) or 0) > 0:
        opts.append(f"--min-qscore {int(d['min_qscore'])}")
    trim = d.get("trim", "all")
    if trim and trim != "all":
        opts.append(f"--trim {trim}")
    if d.get("extra_opts"):
        opts.append(str(d["extra_opts"]))
    return " ".join(opts)


def mod_models_arg():
    if MODEL_STACK is None or not MODEL_STACK.mods:
        return ""
    return f"--modified-bases-models {MODEL_STACK.mod_paths_csv}"


def simplex_model_path():
    return MODEL_STACK.simplex.path if MODEL_STACK is not None else "__no_model__"


def resume_flag():
    return "1" if config["dorado"].get("resume", True) else "0"


# The basecall shell, shared by the per-sample and per-run rules. dorado has
# no resume of its own from an interrupted redirect, but it can skip the reads
# already fully written to an earlier output (--resume-from). The partial
# output is kept OUTSIDE snakemake's declared outputs so a failed job does not
# delete it; it is renamed into place only when dorado exits cleanly.
BASECALL_SHELL = r"""
    partial="{output}.partial"
    resume_arg=""
    if [ "{params.resume}" = "1" ] && [ -s "${{partial}}" ]; then
        mv "${{partial}}" "${{partial}}.prev"
        resume_arg="--resume-from ${{partial}}.prev"
        echo "resuming from ${{partial}}.prev" >> {log}
    fi
    if [[ "${{CUDA_VISIBLE_DEVICES:-}}" ]]; then
        echo "CUDA_VISIBLE_DEVICES=${{CUDA_VISIBLE_DEVICES}}" >> {log}
    fi
    dorado basecaller \
        --models-directory {params.models_dir} \
        --recursive \
        {params.opts} {params.mods} {params.kit} ${{resume_arg}} \
        {params.simplex} {input.pod5_dir} \
        2>> {log} > "${{partial}}"
    rm -f "${{partial}}.prev"
    mv "${{partial}}" {output}
    """


rule link_sample_pod5:
    """Stage a sample's POD5 files (hardlinks, else symlinks; never copies)."""
    input:
        lambda wc: samples[wc.sample]["pod5_files"],
    output:
        manifest=os.path.join(outdir, "pod5", "samples", "{sample}", "pod5_files.txt"),
        links=directory(os.path.join(outdir, "pod5", "samples", "{sample}", "pod5")),
    log:
        os.path.join(outdir, "logs", "link_pod5", "{sample}.log"),
    wildcard_constraints:
        sample=mode_constraint("basecall", "prebasecalled"),
    params:
        src=SCRIPT_DIR,
    shell:
        """
        python {params.src}/link_pod5.py --out {output.links} --manifest {output.manifest} {input} 2>{log}
        """


rule link_run_pod5:
    """Stage a barcoded run's POD5 files (the run is basecalled as a whole)."""
    input:
        lambda wc: barcoded_runs[wc.run]["pod5_files"],
    output:
        manifest=os.path.join(outdir, "pod5", "runs", "{run}", "pod5_files.txt"),
        links=directory(os.path.join(outdir, "pod5", "runs", "{run}", "pod5")),
    log:
        os.path.join(outdir, "logs", "link_pod5", "run_{run}.log"),
    wildcard_constraints:
        run=run_constraint(),
    params:
        src=SCRIPT_DIR,
    shell:
        """
        python {params.src}/link_pod5.py --out {output.links} --manifest {output.manifest} {input} 2>{log}
        """


rule basecall:
    """dorado basecaller with the configured simplex + modified-base stack (GPU)."""
    input:
        pod5_dir=sample_pod5_dir("{sample}"),
        manifest=sample_pod5_manifest("{sample}"),
        models=model_inputs(),
    output:
        maybe_temp(basecall_bam("{sample}"), "basecall"),
    log:
        os.path.join(outdir, "logs", "basecall", "{sample}.log"),
    wildcard_constraints:
        sample=mode_constraint("basecall"),
    threads: 8
    params:
        simplex=simplex_model_path(),
        mods=mod_models_arg(),
        models_dir=lambda wc: MODEL_STACK.models_dir if MODEL_STACK else ".",
        opts=dorado_common_opts(),
        kit="",
        resume=resume_flag(),
    shell:
        BASECALL_SHELL


rule basecall_run:
    """One dorado basecall per barcoded run, classifying barcodes in-line."""
    input:
        pod5_dir=os.path.join(outdir, "pod5", "runs", "{run}", "pod5"),
        manifest=os.path.join(outdir, "pod5", "runs", "{run}", "pod5_files.txt"),
        models=model_inputs(),
    output:
        maybe_temp(
            os.path.join(outdir, "bam", "basecall_run", "{run}", "{run}.bam"),
            "basecall",
        ),
    log:
        os.path.join(outdir, "logs", "basecall_run", "{run}.log"),
    wildcard_constraints:
        run=run_constraint(),
    threads: 8
    params:
        simplex=simplex_model_path(),
        mods=mod_models_arg(),
        models_dir=lambda wc: MODEL_STACK.models_dir if MODEL_STACK else ".",
        opts=dorado_common_opts(),
        kit=lambda wc: (
            f"--kit-name {barcoded_runs[wc.run]['kit']}"
            + (
                " --barcode-both-ends"
                if config["dorado"].get("barcode_both_ends")
                else ""
            )
        ),
        resume=resume_flag(),
    shell:
        BASECALL_SHELL


rule demux_run:
    """Split a run's basecalled BAM by the barcodes dorado assigned (BC tag)."""
    input:
        bam=os.path.join(outdir, "bam", "basecall_run", "{run}", "{run}.bam"),
    output:
        maybe_temp(directory(os.path.join(outdir, "demux", "{run}")), "demux"),
    log:
        os.path.join(outdir, "logs", "demux", "{run}.log"),
    wildcard_constraints:
        run=run_constraint(),
    threads: 8
    shell:
        """
        dorado demux --no-classify --no-trim --emit-summary \
            --threads {threads} --output-dir {output} {input.bam} 2>{log}
        """


def demuxed_bams(wc):
    """The per-barcode BAMs dorado demux wrote for this sample's run(s)."""
    paths = []
    for inp in samples[wc.sample]["inputs"]:
        run = barcoded_runs[inp["run_id"]]
        paths.append(
            os.path.join(
                outdir, "demux", inp["run_id"], f"{run['kit']}_{inp['barcode']}.bam"
            )
        )
    return paths


rule collect_demuxed_sample:
    """Gather a barcoded sample's reads (one file per run) into its basecall BAM."""
    input:
        dirs=lambda wc: [
            os.path.join(outdir, "demux", inp["run_id"])
            for inp in samples[wc.sample]["inputs"]
        ],
    output:
        maybe_temp(basecall_bam("{sample}"), "basecall"),
    log:
        os.path.join(outdir, "logs", "collect_demuxed", "{sample}.log"),
    wildcard_constraints:
        sample=mode_constraint("demux"),
    threads: 4
    params:
        bams=demuxed_bams,
    shell:
        """
        for f in {params.bams}; do
            if [ ! -s "$f" ]; then
                echo "expected demuxed BAM missing: $f" | tee -a {log} >&2
                echo "dorado demux wrote:" >&2
                ls -la "$(dirname "$f")" >&2
                exit 1
            fi
        done
        samtools cat -@ {threads} -o {output} {params.bams} 2>>{log}
        """


rule collect_minknow_bams:
    """Use MinKNOW's live-basecalled BAMs as-is (run marked `basecalled: true`)."""
    input:
        lambda wc: samples[wc.sample]["bam_files"],
    output:
        maybe_temp(basecall_bam("{sample}"), "basecall"),
    log:
        os.path.join(outdir, "logs", "collect_minknow", "{sample}.log"),
    wildcard_constraints:
        sample=mode_constraint("prebasecalled"),
    threads: 4
    shell:
        """
        samtools cat -@ {threads} -o {output} {input} 2>{log}
        """
