// Test harness: thickness of several samples, each from its own FreeSurfer folder, through
// STATS_THICKNESS and the pipeline's collection into one global CSV.
include { STATS_THICKNESS   } from '../../../modules/local/stats/thickness/main'
include { collectSampleCsvs } from '../../../workflows/sf-tractomics.nf'

workflow THICKNESS_KNOWN_ANSWER {
    take:
    dir      // directory holding the recon-all fixture folders
    outdir   // where the global file is written

    main:
    // Arrival order differs from the expected file order on purpose
    STATS_THICKNESS(channel.of(
        [[id: 'sub-02', session: 'ses-01', run: ''],      file("${dir}/coarse__recon_all")],
        [[id: 'sub-01', session: 'ses-02', run: 'run-2'], file("${dir}/bert__recon_all")],
        [[id: 'sub-01', session: 'ses-01', run: ''],      file("${dir}/bert__recon_all")],
        [[id: 'sub-01', session: 'ses-02', run: 'run-1'], file("${dir}/coarse__recon_all")]))
    collectSampleCsvs(STATS_THICKNESS.out.thickness, "thickness.csv", outdir)
}
