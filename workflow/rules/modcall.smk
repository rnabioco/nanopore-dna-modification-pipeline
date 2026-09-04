"""modkit: dorado's MM/ML modified-base calls -> pileups, summaries, per-read calls, DMR."""


def modkit_pileup_opts():
    m = config["modkit"]
    opts = []
    if m.get("filter_threshold") is not None:
        opts.append(f"--filter-threshold {m['filter_threshold']}")
    for code, thr in (m.get("mod_thresholds") or {}).items():
        if thr is not None:
            opts.append(f"--mod-threshold {code}:{thr}")
    if m.get("cpg"):
        opts.append("--cpg")
    if m.get("combine_strands"):
        opts.append("--combine-strands")
    for motif in m.get("motifs") or []:
        try:
            seq, offset = str(motif).split(",")
        except ValueError:
            sys.exit(f"modkit.motifs entries must be 'MOTIF,OFFSET', got {motif!r}")
        opts.append(f"--motif {seq.strip()} {offset.strip()}")
    if m.get("extra_opts"):
        opts.append(str(m["extra_opts"]))
    return " ".join(opts)


rule modkit_pileup:
    """bedMethyl of every modification the basecaller emitted, bgzipped + tabix indexed."""
    input:
        bam=final_bam("{sample}"),
        bai=final_bam("{sample}") + ".bai",
        fa=lambda wc: staged_fasta(wc.sample),
        fai=lambda wc: staged_fai(wc.sample),
    output:
        bed=pileup_bed("{sample}"),
        tbi=pileup_bed("{sample}") + ".tbi",
    log:
        os.path.join(outdir, "logs", "modkit", "pileup", "{sample}.log"),
    threads: 8
    params:
        opts=modkit_pileup_opts(),
    shell:
        """
        modkit pileup {params.opts} \
            --threads {threads} --ref {input.fa} \
            --log-filepath {log} --suppress-progress \
            {input.bam} - \
            | bgzip -@ 4 >{output.bed}
        tabix -f -p bed {output.bed}
        """


rule modkit_summary:
    """Sampled per-modification pass fractions and thresholds (modkit summary)."""
    input:
        bam=final_bam("{sample}"),
        bai=final_bam("{sample}") + ".bai",
    output:
        tsv=os.path.join(
            outdir, "summary", "modkit", "{sample}", "{sample}.modkit_summary.tsv"
        ),
    log:
        os.path.join(outdir, "logs", "modkit", "summary", "{sample}.log"),
    threads: 4
    shell:
        """
        modkit summary --tsv --threads {threads} \
            --log-filepath {log} --suppress-progress \
            {input.bam} >{output.tsv}
        """


rule modkit_extract_calls:
    """Per-read, per-position modification calls (large; modkit.extract_calls)."""
    input:
        bam=final_bam("{sample}"),
        bai=final_bam("{sample}") + ".bai",
        fa=lambda wc: staged_fasta(wc.sample),
    output:
        tsv=os.path.join(
            outdir, "summary", "modkit", "{sample}", "{sample}.mod_calls.tsv.gz"
        ),
    log:
        os.path.join(outdir, "logs", "modkit", "extract_calls", "{sample}.log"),
    threads: 8
    shell:
        """
        modkit extract calls --threads {threads} \
            --reference {input.fa} --mapped-only --pass-only \
            --log-filepath {log} --suppress-progress \
            {input.bam} - \
            | pigz -p 4 >{output.tsv}
        """


rule modkit_bigwig:
    """One bigWig of modification fraction per mod code found in the pileup."""
    input:
        bed=pileup_bed("{sample}"),
        sizes=lambda wc: staged_sizes(wc.sample),
    output:
        done=os.path.join(
            outdir, "summary", "modkit", "{sample}", "{sample}.bigwig.done"
        ),
    log:
        os.path.join(outdir, "logs", "modkit", "bigwig", "{sample}.log"),
    threads: 4
    params:
        prefix=os.path.join(outdir, "summary", "modkit", "{sample}", "{sample}"),
    shell:
        """
        codes=$(zcat {input.bed} | cut -f4 | sort -u)
        for code in $codes; do
            modkit bedmethyl tobigwig --sizes {input.sizes} --mod-codes "$code" \
                --nthreads {threads} --log-filepath {log} --suppress-progress \
                {input.bed} {params.prefix}.$code.bw
        done
        echo "$codes" >{output.done}
        """


def dmr_contrast(name):
    for c in config.get("dmr", {}).get("contrasts") or []:
        if c.get("name") == name:
            for k in ("a", "b"):
                if c.get(k) not in samples:
                    sys.exit(
                        f"dmr contrast {name!r}: sample {c.get(k)!r} not in samples file"
                    )
            if ref_key_for(c["a"]) != ref_key_for(c["b"]):
                sys.exit(
                    f"dmr contrast {name!r}: samples {c['a']} and {c['b']} use different references"
                )
            return c
    sys.exit(f"unknown dmr contrast {name!r}")


rule modkit_dmr:
    """Pairwise differential modification between two samples (modkit dmr pair)."""
    input:
        a=lambda wc: pileup_bed(dmr_contrast(wc.contrast)["a"]),
        a_tbi=lambda wc: pileup_bed(dmr_contrast(wc.contrast)["a"]) + ".tbi",
        b=lambda wc: pileup_bed(dmr_contrast(wc.contrast)["b"]),
        b_tbi=lambda wc: pileup_bed(dmr_contrast(wc.contrast)["b"]) + ".tbi",
        fa=lambda wc: staged_fasta(dmr_contrast(wc.contrast)["a"]),
    output:
        bed=os.path.join(outdir, "summary", "dmr", "{contrast}.dmr.bed"),
    log:
        os.path.join(outdir, "logs", "modkit", "dmr", "{contrast}.log"),
    threads: 8
    params:
        base=lambda wc: dmr_contrast(wc.contrast).get("base", "C"),
        extra=lambda wc: dmr_contrast(wc.contrast).get("opts", ""),
    shell:
        """
        modkit dmr pair -a {input.a} -b {input.b} -o {output.bed} \
            --ref {input.fa} --base {params.base} --header \
            --threads {threads} --log-filepath {log} --suppress-progress {params.extra}
        """
