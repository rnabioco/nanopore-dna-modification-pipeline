"""Reference staging, minimap2 index, alignment, and the final BAM."""


rule stage_reference:
    """Link the reference into the output tree and index it there.

    The source directory may be read-only (a shared reference folder), and
    samtools faidx writes beside the FASTA, so the index is built on a link
    under output_directory. A gzipped reference must be bgzipped for faidx;
    a plain gzip is decompressed once here instead.
    """
    input:
        lambda wc: REFERENCES[wc.ref],
    output:
        fa=os.path.join(outdir, "reference", "{ref}", "genome.fa"),
        fai=os.path.join(outdir, "reference", "{ref}", "genome.fa.fai"),
        sizes=os.path.join(outdir, "reference", "{ref}", "genome.chrom.sizes"),
    log:
        os.path.join(outdir, "logs", "reference", "{ref}.stage.log"),
    shell:
        """
        src=$(realpath {input})
        case "$src" in
            *.gz)
                if bgzip -t "$src" 2>/dev/null; then
                    bgzip -dc "$src" >{output.fa}
                else
                    gzip -dc "$src" >{output.fa}
                fi
                ;;
            *)
                ln -sf "$src" {output.fa}
                ;;
        esac
        samtools faidx {output.fa} 2>{log}
        cut -f1,2 {output.fai} >{output.sizes}
        """


rule mm2_index:
    input:
        fa=os.path.join(outdir, "reference", "{ref}", "genome.fa"),
    output:
        mmi=os.path.join(outdir, "reference", "{ref}", "genome.mmi"),
    log:
        os.path.join(outdir, "logs", "reference", "{ref}.mm2_index.log"),
    threads: 4
    params:
        preset=config["reference"].get("preset", "lr:hq"),
    shell:
        """
        minimap2 -t {threads} -x {params.preset} -d {output.mmi} {input.fa} 2>{log}
        """


def aligner_command(wildcards, input, threads):
    """The producer half of the alignment pipe, for the configured tool.

    dorado aligner keeps every tag on the read (MM/ML modbase calls, mv move
    table, RG) and is ONT's recommended path. The minimap2 path streams the
    uBAM through samtools fastq -T '*' (all tags) and minimap2 -y (copy them).
    """
    tool = config["align"].get("tool", "dorado")
    opts = str(config["align"].get("mm2_opts") or "").strip()
    preset = config["reference"].get("preset", "lr:hq")
    if tool == "dorado":
        mm2 = f'--mm2-opts "{opts}"' if opts else ""
        return f"dorado aligner --threads {threads} --no-sort {mm2} {input.mmi} {input.bam}"
    if tool == "minimap2":
        return (
            f"samtools fastq -T '*' -@ 2 {input.bam} | "
            f"minimap2 -y -ax {preset} -t {threads} {opts} {input.mmi} -"
        )
    sys.exit(f"align.tool must be dorado or minimap2, got {tool!r}")


rule align:
    """Align the basecalled reads; sort, filter, and index."""
    input:
        bam=basecall_bam("{sample}"),
        mmi=lambda wc: staged_mmi(wc.sample),
    output:
        bam=os.path.join(outdir, "bam", "aligned", "{sample}", "{sample}.bam"),
        bai=os.path.join(outdir, "bam", "aligned", "{sample}", "{sample}.bam.bai"),
    log:
        os.path.join(outdir, "logs", "align", "{sample}.log"),
    threads: 16
    params:
        aligner=aligner_command,
        exclude=config["align"].get("exclude_flags", "0x904"),
        min_mapq=int(config["align"].get("min_mapq", 0) or 0),
    shell:
        """
        tmp=$(mktemp -d -p "${{TMPDIR:-/tmp}}" align.{wildcards.sample}.XXXXXX)
        trap 'rm -rf "$tmp"' EXIT
        {params.aligner} 2>>{log} \
            | samtools view -h -F {params.exclude} -q {params.min_mapq} - \
            | samtools sort -@ 4 -m 2G -T "$tmp/sort" -o {output.bam} 2>>{log}
        samtools index -@ {threads} {output.bam}
        """


rule finalize_bam:
    """Stable path for every consumer (modkit, DNAscent, custom steps)."""
    input:
        bam=rules.align.output.bam,
        bai=rules.align.output.bai,
    output:
        bam=final_bam("{sample}"),
        bai=final_bam("{sample}") + ".bai",
    shell:
        """
        ln -f "$(realpath {input.bam})" {output.bam} 2>/dev/null || ln -sf "$(realpath {input.bam})" {output.bam}
        ln -f "$(realpath {input.bai})" {output.bai} 2>/dev/null || ln -sf "$(realpath {input.bai})" {output.bai}
        """
