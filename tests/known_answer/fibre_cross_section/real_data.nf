// Fibre cross-section on real sessions already processed by the pipeline, with a known effect.
// Not part of nf-test (it needs real data); run by tests/known_answer/fibre_cross_section/run_real_data.sh.
//
// --sessions: TSV with columns label, fodf, mask, b0, dwi, bval, bvec (TractoFlow outputs).
// The template is built from all of them. Each session listed in --scaled_sessions is also copied
// with its voxel size multiplied by s = --scales (header only: the brain is s times larger in
// every direction, nothing is resampled and no orientation changes). Its FC must exceed the
// original's by 2 ln s on every bundle: a check of the registration, the fixel steps and the FC
// sign on real anatomy.
include { RECONST_FODTOMRTRIX      } from '../../../modules/local/reconst/fodmrtrix/main'
include { TEMPLATE_FODPOPULATION   } from '../../../modules/local/template/fodpopulation/main'
include { TEMPLATE_IITBUNDLES      } from '../../../modules/local/template/iitbundles/main'
include { TEMPLATE_FCBUNDLEFIXELS  } from '../../../modules/local/template/fcbundlefixels/main'
include { REGISTRATION_FODTEMPLATE } from '../../../modules/local/registration/fodtemplate/main'
include { STATS_FIBRECROSSSECTION  } from '../../../modules/local/stats/fibrecrosssection/main'
include { ATLAS_IIT                } from '../../../subworkflows/nf-neuro/atlas_iit/main'

params.sessions        = null
params.scaled_sessions = ""
params.scales          = "1.05,0.95"
params.outdir          = "fc_real_data"

process SCALE_SESSION {
    tag "${meta.id}"
    container "community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976"

    input:
    tuple val(meta), path(fodf), path(mask), path(b0), path(dwi), path(bval), path(bvec), val(scale)

    output:
    tuple val(meta), path("s_fodf.nii.gz"), path("s_mask.nii.gz"), path("s_b0.nii.gz"), path("s_dwi.nii.gz"), path(bval), path(bvec)

    script:
    """
    python3 << 'PYEOF'
import nibabel as nib
for src, dst in (("${fodf}", "s_fodf.nii.gz"), ("${mask}", "s_mask.nii.gz"), ("${b0}", "s_b0.nii.gz"), ("${dwi}", "s_dwi.nii.gz")):
    img = nib.load(src)
    affine = img.affine.copy()
    affine[:3, :3] *= ${scale}
    out = img.__class__(img.dataobj, affine, img.header)
    out.set_qform(affine, code=1); out.set_sform(affine, code=1)
    nib.save(out, dst)
PYEOF
    """
}

workflow {
    ch_rows = channel.fromPath(params.sessions, checkIfExists: true)
        .splitCsv(header: true, sep: "\t")
        .map { r -> [[id: r.label, session: "", run: ""], file(r.fodf), file(r.mask), file(r.b0), file(r.dwi), file(r.bval), file(r.bvec)] }

    def scaled = params.scaled_sessions.tokenize(",")
    def scales = params.scales.tokenize(",")
    SCALE_SESSION(
        ch_rows
            .filter { row -> row[0].id in scaled }
            .flatMap { row -> scales.collect { s -> row + [s] } }
            .map { row -> [[id: "${row[0].id}x${row[7]}", session: "", run: ""]] + row[1..7] }
    )
    ch_all = ch_rows.mix(SCALE_SESSION.out)

    RECONST_FODTOMRTRIX(ch_all.map { row -> [row[0], row[1]] })
    ch_fod = RECONST_FODTOMRTRIX.out.fod
    ch_mask = ch_all.map { row -> [row[0], row[2]] }

    TEMPLATE_FODPOPULATION(
        ch_fod.join(ch_mask).join(ch_rows.map { row -> [row[0], row[3]] })
            .toSortedList { a, b -> a[0].id <=> b[0].id }
            .map { items -> [items.collect { i -> i[0].id }, items.collect { i -> i[1] }, items.collect { i -> i[2] }, items.collect { i -> i[3] }] }
    )
    ATLAS_IIT([threshold_bundles: true, fetch_gm_desikan: false])
    TEMPLATE_IITBUNDLES(
        TEMPLATE_FODPOPULATION.out.template.map { t -> t[2] }
            .combine(ATLAS_IIT.out.b0)
            .combine(ATLAS_IIT.out.bundles.map { masks -> [masks] })
    )
    TEMPLATE_FCBUNDLEFIXELS(
        TEMPLATE_FODPOPULATION.out.template.combine(TEMPLATE_IITBUNDLES.out.masks).combine(TEMPLATE_IITBUNDLES.out.iit_b0)
    )
    ch_template = TEMPLATE_FCBUNDLEFIXELS.out.template

    REGISTRATION_FODTEMPLATE(
        ch_fod.join(ch_mask).join(ch_all.map { row -> [row[0], row[4], row[5], row[6]] }).combine(ch_template)
    )
    STATS_FIBRECROSSSECTION(
        ch_fod.join(ch_mask).join(REGISTRATION_FODTEMPLATE.out.warp).join(REGISTRATION_FODTEMPLATE.out.qc)
            .map { meta, fod, mask, warp, qc -> [meta, fod, mask, warp, qc, meta.id.contains("x") ? 0 : 1] }
            .combine(ch_template)
    )
    STATS_FIBRECROSSSECTION.out.stats
        .map { _meta, csv -> csv }
        .collectFile(name: "fc_stats.csv", storeDir: params.outdir, skip: 1, keepHeader: true, sort: { f -> f.name })
}
