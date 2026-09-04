"""Alignment and read-level QC, and the per-project summary table."""


rule samtools_qc:
    input:
        bam=final_bam("{sample}"),
        bai=final_bam("{sample}") + ".bai",
    output:
        flagstat=os.path.join(
            outdir, "summary", "qc", "{sample}", "{sample}.flagstat.tsv"
        ),
        stats=os.path.join(outdir, "summary", "qc", "{sample}", "{sample}.stats.txt"),
    log:
        os.path.join(outdir, "logs", "qc", "{sample}.samtools.log"),
    threads: 4
    shell:
        """
        samtools flagstat -@ {threads} -O tsv {input.bam} >{output.flagstat} 2>{log}
        samtools stats -@ {threads} {input.bam} >{output.stats} 2>>{log}
        """


rule mosdepth:
    """Depth summary per contig and global distribution (mosdepth, fast mode)."""
    input:
        bam=final_bam("{sample}"),
        bai=final_bam("{sample}") + ".bai",
    output:
        summary=os.path.join(
            outdir, "summary", "qc", "{sample}", "{sample}.mosdepth.summary.txt"
        ),
        dist=os.path.join(
            outdir, "summary", "qc", "{sample}", "{sample}.mosdepth.global.dist.txt"
        ),
    log:
        os.path.join(outdir, "logs", "qc", "{sample}.mosdepth.log"),
    threads: 4
    params:
        prefix=os.path.join(outdir, "summary", "qc", "{sample}", "{sample}"),
    shell:
        """
        mosdepth -t {threads} -n --fast-mode {params.prefix} {input.bam} 2>{log}
        """


rule dorado_read_summary:
    """Per-read table (length, qscore, alignment) from dorado summary."""
    input:
        bam=final_bam("{sample}"),
    output:
        tsv=read_summary("{sample}"),
    log:
        os.path.join(outdir, "logs", "qc", "{sample}.read_summary.log"),
    threads: 2
    shell:
        """
        dorado summary {input.bam} 2>{log} | pigz -p {threads} >{output.tsv}
        """


def samples_summary_inputs():
    inputs = []
    for s in SAMPLES:
        inputs.append(os.path.join(outdir, "summary", "qc", s, f"{s}.flagstat.tsv"))
        if config["qc"].get("mosdepth", True):
            inputs.append(
                os.path.join(outdir, "summary", "qc", s, f"{s}.mosdepth.summary.txt")
            )
        if config["qc"].get("read_summary", True):
            inputs.append(read_summary(s))
        if config["modkit"].get("summary", True):
            inputs.append(
                os.path.join(outdir, "summary", "modkit", s, f"{s}.modkit_summary.tsv")
            )
    return inputs


rule samples_summary:
    """One row per sample: reads, mapping, depth, read length/qscore, modification fractions."""
    input:
        samples_summary_inputs(),
    output:
        tsv=os.path.join(outdir, "summary", "samples_summary.tsv"),
    log:
        os.path.join(outdir, "logs", "qc", "samples_summary.log"),
    params:
        src=SCRIPT_DIR,
        outdir=outdir,
        samples=" ".join(SAMPLES),
    shell:
        """
        python {params.src}/summarize_samples.py \
            --outdir {params.outdir} --samples {params.samples} --output {output.tsv} 2>{log}
        """
