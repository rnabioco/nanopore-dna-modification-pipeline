"""Stage POD5 files into one directory WITHOUT copying them.

dorado and DNAscent take a directory; a sample can be spread over several
run directories. Each file is hard-linked when the output sits on the same
filesystem (indistinguishable from a regular file, no extra space) and
symlinked otherwise. Names are prefixed with the input's ordinal so two runs
that reuse a basename cannot collide. A manifest of the real paths is written
beside them.

Never copy POD5: see the storage notes in CLAUDE.md.
"""

from __future__ import annotations

import argparse
import os
import sys


def stage(files: list[str], out_dir: str, manifest: str) -> int:
    os.makedirs(out_dir, exist_ok=True)
    # Remove stale links from a previous attempt so the directory is exactly
    # the current input set.
    for name in os.listdir(out_dir):
        p = os.path.join(out_dir, name)
        if name.endswith(".pod5") and (os.path.islink(p) or os.stat(p).st_nlink > 1):
            os.remove(p)
    n_hard = n_sym = 0
    with open(manifest, "w") as fh:
        for i, src in enumerate(files):
            src = os.path.realpath(src)
            if not os.path.isfile(src):
                print(f"missing input: {src}", file=sys.stderr)
                return 1
            dst = os.path.join(out_dir, f"{i:05d}_{os.path.basename(src)}")
            if os.path.lexists(dst):
                os.remove(dst)
            try:
                os.link(src, dst)
                n_hard += 1
            except OSError:
                os.symlink(src, dst)
                n_sym += 1
            fh.write(f"{dst}\t{src}\n")
    print(
        f"staged {len(files)} POD5 files into {out_dir} ({n_hard} hardlinks, {n_sym} symlinks)",
        file=sys.stderr,
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="directory to stage into")
    parser.add_argument(
        "--manifest", required=True, help="TSV of staged path -> real path"
    )
    parser.add_argument("files", nargs="+")
    args = parser.parse_args(argv)
    return stage(args.files, args.out, args.manifest)


if __name__ == "__main__":
    sys.exit(main())
