# Changes to vendored nf-neuro code

sf-tractomics vendors nf-neuro modules and subworkflows under `modules/nf-neuro/` and
`subworkflows/nf-neuro/`, at the versions recorded in `modules.json`. Some of these files were
changed in this pipeline. An `nf-core modules update` or `subworkflows update` would overwrite
them, silently undoing fixes that the results depend on.

This folder holds one diff per changed file, against the upstream version in `modules.json`,
written by `make_patches.py`. Rerun it after touching vendored code (it needs a clone of
`github.com/nf-neuro/modules`, here `../modules`), and before any update: reapply each diff, or
check that upstream now includes the change.

```bash
python3 docs/nf-neuro-patches/make_patches.py ../modules
```

`nf-core modules patch` cannot be used for now: it stops on the components missing from
`modules.json` (below), and moves them to `modules/local/` on its own.

## Changed files

| File | Change | Why | Upstream |
|---|---|---|---|
| `segmentation/synthseg/main.nf` | Pass `--parc`; use `FS_LICENSE` instead of copying the licence into `$FREESURFER_HOME` | `--parc` was defined but never passed, so every cortex region was empty. The licence copy fails when the container runs as the host user, as with the Docker profile. | To propose |
| `stats/metricsinroi/main.nf` | `sid`, `session`, `run` columns (bare run number, absent run = 1); region-centric transposition in label mode; `desc-*__` metric names; first ROI name read with `awk 'NR == 1'` instead of `head -n 1` | One TSV layout for WM bundles and GM/CSF regions, with the covariates and run convention the collectors use; `head` closing the pipe early made `printf` fail with SIGPIPE (exit 141 under `pipefail`) at random, seen on OASIS-3 | Partly in the reviewed upstream version; to compare |
| `atlas_iit/main.nf`, `meta.yml` | IIT GM Desikan atlas download (`fetch_gm_desikan`) | GM region metrics | Vendored from the reviewed upstream pull request |
| `atlas_iit/nextflow.config` | Comment only | | |
| `atlas_roimetrics/main.nf`, `meta.yml`, `tests/main.nf.test` | `use_registered_atlas` input, source and output axes | Follows the reviewed upstream pull request | Vendored from the reviewed upstream pull request |
| `atlas_roimetrics/nextflow.config` | GM atlas warp with `GenericLabel` | `MultiLabel` changes label volumes even under an identity transform (known-answer test in `tests/known_answer/applytransforms.nf.test`) | To propose |
| `preproc_t1/main.nf` | Fall back to the image before brain extraction when `BETCROP_ANTSBET` fails | Nextflow 26 emits `null` outputs for ignored failures, which then crashed the registration | To propose |
| `reconst_fw_noddi/main.nf` | `format_input` moved from a closure to a function | Nextflow 26 strict syntax | To propose |
| `tractoflow/meta.yml` | The defaults key `preproc_t1_run_resample` renamed `preproc_t1_run_resampling` | The code reads `preproc_t1_run_resampling`, so T1 resampling never ran whatever the option (test: `tests/options.nf.test`) | To propose |
| `tractoflow/modules.config` | `aparc+aseg` and `wmparc` warps with `GenericLabel` | Same as `atlas_roimetrics` | To propose |
| `tractoflow/nextflow.config` | Default parameter list (SH fit, topup, eddy, T1 and DWI preprocessing, tracking) | Local defaults of the pipeline | Local only |

## Components missing from `modules.json`

| Component | Origin |
|---|---|
| `modules/nf-neuro/stats/roivolumes` | Open nf-neuro pull request (`feat/stats-roivolumes` on `baptisp/modules`). Install it with `nf-core modules install` once merged. |
| `subworkflows/nf-neuro/atlas_csf_roimetrics` | Written for sf-tractomics; not in nf-neuro. Move it to `subworkflows/local/` or propose it upstream. |
