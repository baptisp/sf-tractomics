// Test harness: runs the pipeline's CSV collectors on the hand-made files of this directory.
include { collectStatsFilesWithVolumes; collectVolumeFiles; collectUnifiedFiles } from '../../../workflows/sf-tractomics.nf'

workflow COLLECTORS_KNOWN_ANSWER {
    take:
    dir      // directory holding the fixtures
    outdir   // where the collected files are written

    main:
    def f = { name -> file("${dir}/${name}") }
    // Stats carry the covariates; volume metas do not, as in the pipeline.
    ch_gm_stats = channel.of(
        [[id: 'sub-02', session: 'ses-01', run: '',      age: 55], f.call('s02_r1_gm.tsv')],
        [[id: 'sub-01', session: 'ses-01', run: 'run-2', age: 70], f.call('s01_r2_gm.tsv')],
        [[id: 'sub-01', session: 'ses-01', run: 'run-1', age: 70], f.call('s01_r1_gm.tsv')])
    // A: one volume CSV per run (SynthSeg), arriving in yet another order
    ch_vols_runs = channel.of(
        [[id: 'sub-01', session: 'ses-01', run: 'run-1'], f.call('v01_r1_gm.csv')],
        [[id: 'sub-02', session: 'ses-01', run: ''],      f.call('v02_r1_gm.csv')],
        [[id: 'sub-01', session: 'ses-01', run: 'run-2'], f.call('v01_r2_gm.csv')])
    a = collectStatsFilesWithVolumes(ch_gm_stats, ch_vols_runs, "A_runs.tsv", outdir, "GM_region", "synthseg")
    // B: one volume CSV per session (SAMSEG) with a region the stats lack; sub-02 has no volumes
    ch_vols_session = channel.of([[id: 'sub-01', session: 'ses-01', run: ''], f.call('v01_samseg_gm.csv')])
    b = collectStatsFilesWithVolumes(ch_gm_stats, ch_vols_session, "B_session.tsv", outdir, "GM_region", "samseg_long")
    // C: atlas volume CSVs (no volume_source/icv columns, one with the legacy 'region' header)
    c = collectVolumeFiles(channel.of(
        [[id: 'sub-02', session: 'ses-01'], f.call('v02_atlas_csf.csv')],
        [[id: 'sub-01', session: 'ses-01'], f.call('v01_atlas_csf_legacy.csv')]), "C_volumes.csv", outdir, "atlas")
    // E: ICV drift across sessions of one subject (median 1 510 000; ses-03 is 6% off)
    e = collectVolumeFiles(channel.of(
        [[id: 'sub-03', session: 'ses-03'], f.call('v03_s3.csv')],
        [[id: 'sub-03', session: 'ses-01'], f.call('v03_s1.csv')],
        [[id: 'sub-03', session: 'ses-02'], f.call('v03_s2.csv')]), "E_drift.csv", outdir, "synthseg", 0.03, "test-rev")
    // D: combined TSV from WM stats, GM stats+volumes (A) and CSF volumes only (C)
    d = collectUnifiedFiles(
        channel.of("STATS_WM_bundle:::${f.call('wm_all.tsv')}")
            .mix(a.map { p -> "STATS_GM_region:::${p}" })
            .mix(c.map { p -> "VOLS_CSF_region:::${p}" }),
        "D_combined.tsv", outdir, ["age"],
        channel.of([id: 'sub-01', session: 'ses-01', run: 'run-1', age: 70], [id: 'sub-02', session: 'ses-01', run: '', age: 55]))

    emit:
    a = a
    b = b
    c = c
    d = d
    e = e
}
