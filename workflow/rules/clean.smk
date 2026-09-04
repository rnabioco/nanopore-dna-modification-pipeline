"""On-demand cleanup of large, regenerable intermediates:

    snakemake clean --configfile <project.yml> --cores 1

Removes the staged POD5 links, dorado uBAMs, per-run basecalls, demux output
and the pre-final aligned BAM from output_directory, keeping summary/,
bam/final/ (a hardlink, so it survives removing bam/aligned), reference/,
dnascent/ and logs/. Everything removed is rebuilt on the next run when
something downstream asks for it. This is the superset of the auto-`temp()`
tiers selected by `cleanup_intermediates`.
"""

CLEAN_TARGETS = [
    "pod5",  # hard/symlinks only; no data
    "bam/basecall",  # dorado uBAM per sample (GPU-hours to regenerate)
    "bam/basecall_run",  # per-run basecall on the demux path
    "demux",  # dorado demux output
    "bam/aligned",  # bam/final is a hardlink of this
]


rule clean:
    params:
        outdir=outdir,
        targets=" ".join(CLEAN_TARGETS),
    shell:
        r"""
        freed_kb=0
        for rel in {params.targets}; do
            target="{params.outdir}/$rel"
            if [ -L "$target" ]; then
                rm -f "$target"
                echo "clean: unlinked $rel"
            elif [ -d "$target" ]; then
                sz_kb=$(du -sk "$target" | cut -f1)
                sz_h=$(du -sh "$target" | cut -f1)
                rm -rf "$target"
                freed_kb=$((freed_kb + sz_kb))
                echo "clean: removed $rel ($sz_h)"
            fi
        done
        echo "clean: freed ~$((freed_kb / 1024)) MB under {params.outdir}"
        """
