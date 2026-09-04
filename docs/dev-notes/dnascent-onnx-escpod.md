# Could DNAscent's model run through escpod as ONNX?

Status: **feasibility notes, not started.** Written 2026-09-04 from the
DNAscent 4.x sources and escpod 0.20.0.

## What DNAscent's model is

- `dnn_models/detect_model_BrdUEdU_DNAr10_4_1/` is a **TensorFlow SavedModel**
  (`saved_model.pb`, 12 MB, plus `variables/`), loaded through the TensorFlow
  C API (`libtensorflow-gpu 2.4.1`) in `src/tensor.cpp`
  (`model_load_cpu_twoInputs` / `model_load_gpu_twoInputs`).
- Three inputs (`src/config.h`): `serving_default_input_1`,
  `serving_default_input_2`, `serving_default_input_3`. From
  `src/detect.cpp` they are a **core sequence tensor** and a **residual
  sequence tensor**, each `[1, sequence_length]`, and a **signal tensor**
  `[1, signal_height, signal_width, channels]` built per read by
  `makeCoreSequenceTensor / makeResidualSequenceTensor / makeSignalTensor`.
- The output is a per-thymidine pair (EdU p, BrdU p) that
  `writeModBamTag` writes as `N+e?` / `N+b?` with `ML = uint8(p * 255)`.
- The signal windows are produced by DNAscent's **own event detection and
  HMM event alignment** against its 9-mer pore model
  (`pore_models/r10.4.1_400bps.nucleotide.9mer.model`, plus analogue
  Gaussian models) with `windowLength_align = 50`. It does not use dorado's
  move table.
- License: GPL-3.0. Weights redistributed inside another tool inherit that.

## Converting the graph

The graph itself converts routinely:

```bash
pip install tf2onnx tensorflow==2.4.1   # in a scratch env, not the pipeline's
saved_model_cli show --dir dnn_models/detect_model_BrdUEdU_DNAr10_4_1 --all   # confirm input/output names + shapes
python -m tf2onnx.convert --saved-model dnn_models/detect_model_BrdUEdU_DNAr10_4_1 \
    --opset 17 --output detect_BrdUEdU_r10.4.1.onnx
```

Verify with onnxruntime against a few reads run through DNAscent detect
(compare the `ML` bytes). Expect to have to name the dynamic
`sequence_length` axis.

## What escpod would need

`escpod classify` today is the tRNA charging classifier: a bundle
(`metadata.json` + ONNX/GBM) whose **feature recipe is fixed by the runtime**
(mean + z-scored k-mer residual over a window anchored at the CCA|adapter
junction, mapped through dorado's move table). Its schema is closed on
purpose: an unknown key is refused at load. So a DNAscent bundle is not a
matter of dropping an ONNX file into a directory. It is a **new model kind**
that escpod would have to implement end to end:

1. **Featurisation**: DNAscent's event detection + HMM alignment to its pore
   model, or a re-derivation of the same windows from dorado's move table
   (which DNAscent does not use). Matching DNAscent's features exactly is the
   hard part; the ONNX graph is the easy part. A move-table featurisation
   would be a different model needing retraining, not a port.
2. **Per-position output**: one call per thymidine written as modBAM
   `N+b`/`N+e` tags (escpod classify writes one per-read `cl` tag).
3. **Bundle metadata**: pore model + analogue models pinned by sha256,
   window geometry, input tensor layout, the `T`-position selection rule,
   operating point.

Reasonable path if this is pursued:

- Phase 0 (cheap, informative): convert to ONNX, run it from Python with
  features dumped by an instrumented DNAscent build, confirm parity. This
  proves the graph and pins the tensor contract.
- Phase 1: prototype featurisation in Python from POD5 + BAM (escapepod's
  Python bindings for signal access, `ext/` DNAscent for the HMM), measure
  parity on the fork-stalling pilot.
- Phase 2: only then decide whether a Rust port into escpod is worth it, or
  whether DNAscent stays an external tool behind the pipeline's existing
  `dnascent.*` rules (which is what ships now).

The pipeline's `custom` steps can host Phase 0/1 without any rule changes
(`requires: [dnascent_bam]` gives a step both the final BAM and DNAscent's
output to compare against).
