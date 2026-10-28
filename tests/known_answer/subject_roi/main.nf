// Test harness: diffusion metrics in a subject's own regions, as the pipeline computes them
// (label fractions, then fraction-weighted means), for several samples, collected into one file.
include { IMAGE_LABELFRACTION } from '../../../modules/local/image/labelfraction/main'
include { STATS_METRICSINROI  } from '../../../modules/nf-neuro/stats/metricsinroi/main'
include { collectStatsFiles   } from '../../../workflows/sf-tractomics.nf'

workflow SUBJECT_ROI_KNOWN_ANSWER {
    take:
    dir      // tests/known_answer/subject_roi
    data     // modules/local/image/labelfraction/tests/data
    outdir   // where the global file is written

    main:
    // Arrival order differs from the expected file order on purpose
    def metas = [[id: 'sub-02', session: 'ses-01', run: ''],
                 [id: 'sub-01', session: 'ses-02', run: 'run-2'],
                 [id: 'sub-01', session: 'ses-01', run: '']]
    def prefix = { m -> [m.id, m.session, m.run].findAll { x -> x }.join("_") }
    ch_metrics = channel.fromList(metas)
        .map { m -> [m, [file("${dir}/${prefix.call(m)}__fa.nii.gz"), file("${dir}/${prefix.call(m)}__md.nii.gz")]] }

    IMAGE_LABELFRACTION(channel.fromList(metas).map { m -> [m, file("${data}/labels.nii.gz"), file("${data}/acq_dwi.nii.gz"),
        file("${data}/target_fa.nii.gz"), file("${data}/identity.txt"), file("${data}/lut.json")] })
    STATS_METRICSINROI(ch_metrics.join(IMAGE_LABELFRACTION.out.fractions).map { m, metrics, masks -> [m, metrics, masks, []] })
    collectStatsFiles(STATS_METRICSINROI.out.stats_mean, "subject_roi.tsv", outdir, "GM_subject")
}
