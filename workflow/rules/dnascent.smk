"""DNAscent (BrdU/EdU nucleoside-analogue detection and replication fork calls).

Included only when dnascent.enabled is true. The tool runs from a Singularity
image by default (`pixi run install-dnascent`; Bodhi also ships one at
/cluster/singularity_images/DNAscent.sif) or from a native binary named by
dnascent.command.
"""

DNASCENT = config["dnascent"]


def dnascent_sif():
    sif = DNASCENT.get("sif")
    if not sif:
        sif = os.path.join(
            PIPELINE_DIR,
            "resources",
            "tools",
            "dnascent",
            str(DNASCENT["version"]),
            "DNAscent.sif",
        )
    return sif if os.path.isabs(sif) else os.path.join(PIPELINE_DIR, sif)


def dnascent_exec():
    """The command prefix that runs `DNAscent <subcommand> ...`."""
    if DNASCENT.get("command"):
        return str(DNASCENT["command"])
    binds = list(DNASCENT.get("singularity_bind") or [])
    for site_path in ("/beevol", "/scratch/alpine", "/projects", "/pl"):
        if os.path.isdir(site_path) and site_path not in binds:
            binds.append(site_path)
    bind_arg = " ".join(f"-B {b}" for b in binds)
    nv = "--nv" if DNASCENT.get("gpu", True) else ""
    setup = str(DNASCENT.get("singularity_setup") or "").strip().rstrip(";")
    prefix = f"{setup} && " if setup else ""
    return f"{prefix}singularity exec {nv} {bind_arg} {dnascent_sif()} DNAscent"


if not DNASCENT.get("command") and not os.path.exists(dnascent_sif()):
    logger.warning(
        f"DNAscent image not found at {dnascent_sif()}; run 'pixi run install-dnascent' "
        "or set dnascent.sif / dnascent.command"
    )

DNASCENT_DIR = os.path.join(OUTDIR_ABS, "dnascent")


rule dnascent_index:
    """Map read ids to their POD5 (DNAscent index) over the staged POD5 directory."""
    input:
        pod5_dir=sample_pod5_dir("{sample}"),
        manifest=sample_pod5_manifest("{sample}"),
    output:
        index=os.path.join(outdir, "dnascent", "{sample}", "index.dnascent"),
    log:
        os.path.join(outdir, "logs", "dnascent", "{sample}.index.log"),
    wildcard_constraints:
        sample=mode_constraint("basecall", "prebasecalled"),
    params:
        exe=dnascent_exec(),
        pod5_abs=lambda wc, input: os.path.abspath(input.pod5_dir),
        out_abs=lambda wc, output: os.path.abspath(output.index),
    shell:
        """
        {params.exe} index -f {params.pod5_abs} -o {params.out_abs} >{log} 2>&1
        """


rule dnascent_detect:
    """BrdU/EdU probabilities at every thymidine, written as a modBAM (N+b / N+e)."""
    input:
        bam=final_bam("{sample}"),
        bai=final_bam("{sample}") + ".bai",
        fa=lambda wc: staged_fasta(wc.sample),
        index=rules.dnascent_index.output.index,
    output:
        bam=dnascent_bam("{sample}"),
    log:
        os.path.join(outdir, "logs", "dnascent", "{sample}.detect.log"),
    threads: 16
    params:
        exe=dnascent_exec(),
        gpu="--GPU 0" if DNASCENT.get("gpu", True) else "",
        min_mapq=int(DNASCENT.get("min_mapq", 20)),
        min_length=int(DNASCENT.get("min_length", 1000)),
        bam_abs=lambda wc, input: os.path.abspath(input.bam),
        fa_abs=lambda wc, input: os.path.realpath(input.fa),
        index_abs=lambda wc, input: os.path.abspath(input.index),
        out_abs=lambda wc, output: os.path.abspath(output.bam),
    shell:
        """
        {params.exe} detect \
            -b {params.bam_abs} -r {params.fa_abs} -i {params.index_abs} \
            -o {params.out_abs} -t {threads} {params.gpu} \
            -q {params.min_mapq} -l {params.min_length} >{log} 2>&1
        """


rule dnascent_sort:
    """Coordinate-sorted, indexed copy of the detect BAM for browsers and pysam."""
    input:
        bam=dnascent_bam("{sample}"),
    output:
        bam=os.path.join(outdir, "dnascent", "{sample}", "{sample}.detect.sorted.bam"),
        bai=os.path.join(
            outdir, "dnascent", "{sample}", "{sample}.detect.sorted.bam.bai"
        ),
    log:
        os.path.join(outdir, "logs", "dnascent", "{sample}.sort.log"),
    threads: 4
    shell:
        """
        tmp=$(mktemp -d -p "${{TMPDIR:-/tmp}}" dnascent.{wildcards.sample}.XXXXXX)
        trap 'rm -rf "$tmp"' EXIT
        samtools sort -@ {threads} -m 2G -T "$tmp/sort" -o {output.bam} {input.bam} 2>{log}
        samtools index -@ {threads} {output.bam}
        """


rule dnascent_per_read:
    """Per-read BrdU/EdU summary table from the detect modBAM."""
    input:
        bam=rules.dnascent_sort.output.bam,
        bai=rules.dnascent_sort.output.bai,
    output:
        tsv=os.path.join(outdir, "dnascent", "{sample}", "{sample}.per_read.tsv.gz"),
    log:
        os.path.join(outdir, "logs", "dnascent", "{sample}.per_read.log"),
    params:
        src=SCRIPT_DIR,
        probs="--probs" if DNASCENT.get("per_read_probs_full", False) else "",
    shell:
        """
        python {params.src}/dnascent_per_read.py {input.bam} --output {output.tsv} \
            --mapped-only {params.probs} 2>{log}
        """


rule dnascent_forksense:
    """Origins, terminations, forks and analogue tracks (DNAscent forkSense).

    forkSense writes its BED files into the working directory under fixed
    names (origins_DNAscent_forkSense.bed, leftForks_..., rightForks_...,
    BrdU_..., EdU_..., *_stressSignatures.bed), so it runs inside a
    per-sample directory; the .forkSense file is the declared output.
    """
    input:
        bam=dnascent_bam("{sample}"),
    output:
        fs=os.path.join(
            outdir, "dnascent", "{sample}", "forksense", "{sample}.forkSense"
        ),
    log:
        os.path.join(outdir, "logs", "dnascent", "{sample}.forksense.log"),
    threads: 8
    params:
        exe=dnascent_exec(),
        order=DNASCENT["forksense"].get("order", "EdU,BrdU"),
        opts=DNASCENT["forksense"].get("opts", ""),
        workdir=lambda wc, output: os.path.abspath(os.path.dirname(output.fs)),
        bam_abs=lambda wc, input: os.path.abspath(input.bam),
        log_abs=lambda wc: os.path.abspath(
            os.path.join(outdir, "logs", "dnascent", f"{wc.sample}.forksense.log")
        ),
    shell:
        """
        mkdir -p {params.workdir}
        cd {params.workdir}
        {params.exe} forkSense -d {params.bam_abs} -o {wildcards.sample}.forkSense \
            --order {params.order} -t {threads} {params.opts} >{params.log_abs} 2>&1
        """
