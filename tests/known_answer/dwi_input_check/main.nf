// Test harness: DWI_INPUT_CHECK on synthetic sessions (dwi_input_check/data):
//   sub-01 ses-01         Axial_DTI, b0 + 6 x b1000                      kept (fODF warning)
//   sub-02 ses-01         ep2d_dif_25dir, one volume per b-value         skipped (b-series)
//   sub-03 ses-01 run 1-3 MDDW_1/2/3_of_3_sms, b 1000 / 500 / 2000       merged into run 1
//   sub-04 ses-01 run 1-4 MDDW parts 1, 1, 2, 3 (part 1 exported twice) all skipped
//   sub-05 ses-01         MDDW_1_of_2 alone                              skipped
// duplicate = true adds a second sub-01 ses-01 sample with the same meta (the run must stop).
include { DWI_INPUT_CHECK } from '../../../subworkflows/local/dwi_input_check/main'

def emptyLike(ch) {
    return ch.map { e -> [e[0], []] }
}

workflow DWI_INPUT_CHECK_KNOWN_ANSWER {
    take:
    data        // tests/known_answer/dwi_input_check/data
    outdir      // where dwi_input_report.tsv is written
    duplicate   // boolean

    main:
    def samples = [["sub-01", ""], ["sub-02", ""], ["sub-03", "run-1"], ["sub-03", "run-2"], ["sub-03", "run-3"],
                   ["sub-04", "run-1"], ["sub-04", "run-2"], ["sub-04", "run-3"], ["sub-04", "run-4"], ["sub-05", ""]]
    if (duplicate) samples << ["sub-01", ""]
    def entries = samples.collect { s ->
        def meta = [id: s[0], session: "ses-01", run: s[1]]
        def base = "${data}/" + [s[0], "ses-01", s[1]].findAll { x -> x }.join("_") + "_dwi"
        [meta, file("${base}.nii.gz"), file("${base}.bval"), file("${base}.bvec"), file("${data}/t1.nii.gz")]
    }
    ch = channel.fromList(entries)
    DWI_INPUT_CHECK(ch.map { e -> [e[0], e[4]] }, emptyLike(ch), emptyLike(ch), ch.map { e -> e[0..3] }, emptyLike(ch),
                    ch.map { e -> [e[0], [], [], []] }, emptyLike(ch), emptyLike(ch), outdir)

    emit:
    dwi_bval_bvec = DWI_INPUT_CHECK.out.dwi_bval_bvec
    t1            = DWI_INPUT_CHECK.out.t1
    rev_dwi       = DWI_INPUT_CHECK.out.rev_dwi_bval_bvec
}
