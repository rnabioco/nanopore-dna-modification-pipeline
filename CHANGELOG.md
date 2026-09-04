# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial pipeline: pixi-managed environment, dorado 2.1.2 install with a
  config-resolved model stack (ONT simplex + modified-base models, plus
  local custom models), per-sample / per-barcoded-run basecalling with
  resume, MinKNOW-basecalled input, dorado or minimap2 alignment, modkit
  pileup / summary / extract / bigWig / DMR, samtools + mosdepth QC, a
  per-project summary table, optional DNAscent (index, detect, per-read
  BrdU/EdU table, forkSense), config-driven custom steps, Bodhi and Alpine
  Slurm profiles, unit tests and CI.

[Unreleased]: https://github.com/rnabioco/nanopore-dna-modification-pipeline/commits/main
