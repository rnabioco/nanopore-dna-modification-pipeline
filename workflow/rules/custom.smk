"""Config-driven custom steps: see workflow/scripts/custom_steps.py for the contract."""

from custom_steps import render_command, render_outputs


def custom_step_dir(step, unit):
    return os.path.join(outdir, "summary", "custom", step, unit)


def custom_sample_inputs(wc):
    spec = CUSTOM_STEPS[wc.step]
    inputs = {"bam": final_bam(wc.sample), "bai": final_bam(wc.sample) + ".bai"}
    if "modkit_pileup" in spec["requires"]:
        inputs["pileup"] = pileup_bed(wc.sample)
    if "read_summary" in spec["requires"]:
        inputs["read_summary"] = read_summary(wc.sample)
    if "dnascent_bam" in spec["requires"]:
        if not config["dnascent"]["enabled"]:
            sys.exit(
                f"custom step {wc.step!r} requires dnascent_bam but dnascent.enabled is false"
            )
        inputs["dnascent_bam"] = os.path.join(
            outdir, "dnascent", wc.sample, f"{wc.sample}.detect.sorted.bam"
        )
    return inputs


def custom_sample_values(wc, input, threads):
    values = {
        "sample": wc.sample,
        "bam": os.path.abspath(input.bam),
        "bai": os.path.abspath(input.bai),
        "reference": os.path.realpath(staged_fasta(wc.sample)),
        "outdir": os.path.abspath(custom_step_dir(wc.step, wc.sample)),
        "threads": threads,
        "pipeline_dir": PIPELINE_DIR,
        "results_dir": OUTDIR_ABS,
    }
    for key in ("pileup", "read_summary", "dnascent_bam"):
        if hasattr(input, key):
            values[key] = os.path.abspath(getattr(input, key))
    return values


def custom_project_values(wc, threads):
    return {
        "samples": " ".join(SAMPLES),
        "bams": " ".join(os.path.abspath(final_bam(s)) for s in SAMPLES),
        "outdir": os.path.abspath(custom_step_dir(wc.step, "project")),
        "threads": threads,
        "pipeline_dir": PIPELINE_DIR,
        "results_dir": OUTDIR_ABS,
    }


CUSTOM_SHELL = r"""
    mkdir -p {params.outdir}
    ( {params.cmd} ) > {log} 2>&1
    for f in {params.outputs}; do
        if [ ! -e "{params.outdir}/$f" ]; then
            echo "custom step {wildcards.step}: declared output missing: {params.outdir}/$f" | tee -a {log} >&2
            exit 1
        fi
    done
    touch {output.done}
    """


rule custom_sample_step:
    input:
        unpack(custom_sample_inputs),
    output:
        done=os.path.join(outdir, "summary", "custom", "{step}", "{sample}", ".done"),
    log:
        os.path.join(outdir, "logs", "custom", "{step}", "{sample}.log"),
    wildcard_constraints:
        step="|".join(
            re.escape(n) for n, s in CUSTOM_STEPS.items() if s["scope"] == "sample"
        )
        or "__no_step__",
    threads: lambda wc: CUSTOM_STEPS[wc.step]["threads"]
    resources:
        mem_mb=lambda wc: CUSTOM_STEPS[wc.step]["mem_mb"],
    params:
        cmd=lambda wc, input, threads: render_command(
            CUSTOM_STEPS[wc.step], **custom_sample_values(wc, input, threads)
        ),
        outputs=lambda wc, input, threads: " ".join(
            render_outputs(
                CUSTOM_STEPS[wc.step], **custom_sample_values(wc, input, threads)
            )
        ),
        outdir=lambda wc: os.path.abspath(custom_step_dir(wc.step, wc.sample)),
    shell:
        CUSTOM_SHELL


rule custom_project_step:
    input:
        bams=[final_bam(s) for s in SAMPLES],
        bais=[final_bam(s) + ".bai" for s in SAMPLES],
    output:
        done=os.path.join(outdir, "summary", "custom", "{step}", "project", ".done"),
    log:
        os.path.join(outdir, "logs", "custom", "{step}", "project.log"),
    wildcard_constraints:
        step="|".join(
            re.escape(n) for n, s in CUSTOM_STEPS.items() if s["scope"] == "project"
        )
        or "__no_step__",
    threads: lambda wc: CUSTOM_STEPS[wc.step]["threads"]
    resources:
        mem_mb=lambda wc: CUSTOM_STEPS[wc.step]["mem_mb"],
    params:
        cmd=lambda wc, threads: render_command(
            CUSTOM_STEPS[wc.step], **custom_project_values(wc, threads)
        ),
        outputs=lambda wc, threads: " ".join(
            render_outputs(CUSTOM_STEPS[wc.step], **custom_project_values(wc, threads))
        ),
        outdir=lambda wc: os.path.abspath(custom_step_dir(wc.step, "project")),
    shell:
        CUSTOM_SHELL
