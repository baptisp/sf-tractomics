// Checks of the diffusion acquisitions before any processing, per session:
//   1. split series: Siemens stores some protocols as several series "<name>_1_of_3", "_2_of_3",
//      ... (or "<name>1of3") (SeriesDescription of the BIDS sidecar), each holding some of the shells (OASIS-3
//      Vida: 3 parts, 66 volumes from b = 100 to 2000). Processed one by one, each part is an
//      incomplete protocol. With merge_split_dwi, the parts are concatenated in order into one
//      sample (the meta of part 1); when a part is missing or present more than once (the same
//      series exported twice), all the parts are skipped: there is no safe way to choose.
//   2. DTI: the largest shell of the DTI range (dti_shells, or b0_thr_extract_b0 < b <=
//      max_dti_shell_value) must hold at least dwi_min_shell_directions volumes (6, the minimum
//      for a tensor; 0 disables the check). Acquisitions with one direction per b-value
//      (b-series, as in OASIS-3 TrioTim "ep2d_dif_25dir") fail it: eddy cannot correct them.
//   3. fODF: a warning when the fODF shells hold fewer volumes than the (sh_order + 1)
//      (sh_order + 2) / 2 coefficients of the spherical harmonic fit.
// Skipped samples are removed from every input channel (their T1 too). Every decision is
// written to <report_dir>/dwi_input_report.tsv. Two kept samples with the same meta stop the run.
include { PREPROC_DWICONCATENATE } from '../../../modules/local/preproc/dwiconcatenate/main'

// SeriesDescription of the BIDS sidecar of a DWI (same name, .json), "" without one
def dwiSeriesDescription(dwi) {
    def sidecar = file(dwi.toString().replaceFirst(/\.nii(\.gz)?$/, ".json"))
    if (!sidecar.exists()) return ""
    try {
        return (new groovy.json.JsonSlurper().parseText(sidecar.text).SeriesDescription ?: "").toString()
    } catch (Exception _e) {
        return ""
    }
}

// Non-b0 shells of a list of b-values: [b (mean of the shell), volumes], grouping values within
// the tolerance of the previous one, in increasing b
def dwiShells(bvals, b0_thr, tolerance) {
    def shells = []
    bvals.findAll { b -> b > b0_thr }.sort().each { b ->
        if (shells && b - shells[-1].last <= tolerance) {
            shells[-1].values << b
            shells[-1].last = b
        } else {
            shells << [values: [b], last: b]
        }
    }
    return shells.collect { s -> [s.values.sum() / s.values.size(), s.values.size()] }
}

def inShellList(b, list, tolerance) {
    return list.any { x -> Math.abs(b - (x as double)) <= tolerance }
}

def shellList(value) {
    if (value == null || value == "") return null
    return value.toString().tokenize(", ").collect { x -> x as double }
}

// Decisions for the DWIs of one session. entries: [meta, dwi, bval, bvec, series description].
// Returns maps: decision (kept, merged, skipped), meta, dwis, bvals, bvecs, row (report columns).
def planDwiSession(entries, opts) {
    def plans = []
    def split = [:]
    def singles = []
    entries.each { e ->
        def m = opts.merge_split ? (e[4] =~ /^(.*?)_?(\d+)_?of_?(\d+)(.*)$/) : null
        if (m && m.matches()) {
            def key = "${m.group(1)}_of_${m.group(3)}${m.group(4)}"
            split.computeIfAbsent(key, { [n: m.group(3) as int, parts: []] }).parts << [m.group(2) as int, e]
        } else {
            singles << [[e], ""]
        }
    }
    split.each { key, g ->
        def counts = (1..g.n).collect { k -> g.parts.count { p -> p[0] == k } }
        def runs = g.parts.sort { p -> p[0] }.collect { p -> p[1][0].run ?: "run-1" }.join("+")
        if (counts.every { c -> c == 1 } && g.parts.size() == g.n) {
            singles << [g.parts.sort { p -> p[0] }.collect { p -> p[1] }, "merged ${g.n} parts of ${key.replace('_of_', '_k_of_')} (${runs})"]
        } else {
            def detail = (1..g.n).collect { k -> "part ${k}: ${counts[k - 1]}" }.join(", ")
            g.parts.each { p ->
                plans << [decision: "skipped", meta: p[1][0], row: [series: p[1][4], reason: "split series ${key.replace('_of_', '_k_of_')} incomplete or duplicated (${detail})"]]
            }
        }
    }
    singles.each { s ->
        def parts = s[0]
        def meta = parts[0][0]
        def bvals = parts.collectMany { p -> file(p[2].toString()).text.tokenize().collect { x -> x as double } }
        def shells = dwiShells(bvals, opts.b0_thr, opts.tolerance)
        def dti_list = shellList(opts.dti_shells)
        def dti = shells.findAll { sh -> dti_list ? inShellList(sh[0], dti_list, opts.tolerance) : sh[0] <= opts.max_dti }
        def largest_dti = dti ? dti.collect { sh -> sh[1] }.max() : 0
        def fodf_list = shellList(opts.fodf_shells)
        def fodf_volumes = shells.findAll { sh -> fodf_list ? inShellList(sh[0], fodf_list, opts.tolerance) : sh[0] >= opts.min_fodf }.collect { sh -> sh[1] }.sum() ?: 0
        def needed = ((opts.sh_order + 1) * (opts.sh_order + 2)).intdiv(2)
        def row = [
            series: parts.collect { p -> p[4] }.join("+"),
            volumes: bvals.size(),
            shells: shells.collect { sh -> "${Math.round(sh[0])}:${sh[1]}" }.join(" "),
            largest_dti_shell: largest_dti,
            fodf_volumes: fodf_volumes,
            sh_coefficients: needed,
            reason: s[1]
        ]
        if (opts.min_directions > 0 && largest_dti < opts.min_directions) {
            row.reason = ([s[1]] + ["largest DTI shell has ${largest_dti} volumes (< ${opts.min_directions})"]).findAll { x -> x }.join("; ")
            parts.each { p -> plans << [decision: "skipped", meta: p[0], row: row] }
        } else {
            if (fodf_volumes < needed) {
                row.warning = "fODF shells hold ${fodf_volumes} volumes for the ${needed} coefficients of sh_order ${opts.sh_order}"
            }
            plans << [decision: parts.size() > 1 ? "merged" : "kept", meta: meta, row: row,
                      dwis: parts.collect { p -> p[1] }, bvals: parts.collect { p -> p[2] }, bvecs: parts.collect { p -> p[3] }]
        }
    }
    return plans
}

def keepSamples(ch, ch_keep) {
    return ch.join(ch_keep.map { m -> [m, true] }).map { t -> t[0..-2] }
}

workflow DWI_INPUT_CHECK {
    take:
    ch_t1
    ch_wmparc
    ch_aparc_aseg
    ch_dwi_bval_bvec
    ch_b0
    ch_rev_dwi_bval_bvec
    ch_rev_b0
    ch_lesion
    report_dir          // string: where dwi_input_report.tsv is written

    main:
    def opts = [
        merge_split   : params.merge_split_dwi == true,
        b0_thr        : params.b0_thr_extract_b0 as double,
        tolerance     : params.dwi_shell_tolerance as double,
        max_dti       : params.max_dti_shell_value as double,
        dti_shells    : params.dti_shells,
        min_fodf      : params.min_fodf_shell_value as double,
        fodf_shells   : params.fodf_shells,
        sh_order      : params.sh_order as int,
        min_directions: params.dwi_min_shell_directions as int
    ]

    ch_plans = ch_dwi_bval_bvec
        .map { meta, dwi, bval, bvec -> [[meta.id, meta.session ?: ""], [meta, dwi, bval, bvec, dwiSeriesDescription(dwi)]] }
        .groupTuple()
        .flatMap { _key, entries -> planDwiSession(entries, opts) }

    PREPROC_DWICONCATENATE(
        ch_plans.filter { p -> p.decision == "merged" }.map { p -> [p.meta, p.dwis, p.bvals, p.bvecs] }
    )

    ch_dwi_out = ch_plans
        .filter { p -> p.decision == "kept" }
        .map { p -> [p.meta, p.dwis[0], p.bvals[0], p.bvecs[0]] }
        .mix(PREPROC_DWICONCATENATE.out.dwi_bval_bvec)

    ch_keep = ch_plans.filter { p -> p.decision != "skipped" }.map { p -> p.meta }

    // Report, warnings, and a stop on two kept samples with one meta (their outputs would mix)
    ch_plans
        .map { p ->
            def m = p.meta
            [m.id, m.session ?: "", (m.run ?: "run-1").replaceFirst(/^run-/, ""), p.decision] +
                ["series", "volumes", "shells", "largest_dti_shell", "fodf_volumes", "sh_coefficients", "reason", "warning"]
                    .collect { k -> p.row[k] == null ? "" : p.row[k] }
        }
        .collect(flat: false)
        .subscribe { rows ->
            def sorted = rows.sort { a, b -> a[0] <=> b[0] ?: a[1] <=> b[1] ?: a[2] <=> b[2] }
            def header = ["sid", "session", "run", "decision", "series", "volumes", "shells", "largest_dti_shell",
                          "fodf_volumes", "sh_coefficients", "reason", "warning"]
            def out = file("${report_dir}/dwi_input_report.tsv")
            out.parent.mkdirs()
            out.text = ([header] + sorted).collect { r -> r.collect { x -> x.toString().replace("\t", " ") }.join("\t") }.join("\n") + "\n"
            def skipped = sorted.findAll { r -> r[3] == "skipped" }
            def merged = sorted.findAll { r -> r[3] == "merged" }
            def low_fodf = sorted.findAll { r -> r[11] }
            if (merged) log.warn("${merged.size()} DWI sample(s) built from the parts of a split series (e.g. ${merged[0][0]} ${merged[0][1]}): see ${out}")
            if (skipped) log.warn("${skipped.size()} DWI run(s) skipped, with their T1, e.g. ${skipped[0][0]} ${skipped[0][1]} run ${skipped[0][2]}: ${skipped[0][10]}. See ${out}")
            if (low_fodf) log.warn("${low_fodf.size()} DWI sample(s) have fewer fODF volumes than sh_order ${opts.sh_order} needs (e.g. ${low_fodf[0][0]} ${low_fodf[0][1]}: ${low_fodf[0][11]}); their fODF fit is unstable: see ${out}")
        }
    ch_keep
        .map { m -> [m.id, m.session ?: "", m.run ?: ""] }
        .collect(flat: false)
        .subscribe { keys ->
            def dupes = keys.countBy { k -> k }.findAll { _k, c -> c > 1 }.keySet()
            if (dupes) error("Several DWI samples share the same subject, session and run: ${dupes.collect { k -> k.findAll { x -> x }.join('_') }.join(', ')}. Give each DWI run its own run number in the input.")
        }

    emit:
    t1                = keepSamples(ch_t1, ch_keep)
    wmparc            = keepSamples(ch_wmparc, ch_keep)
    aparc_aseg        = keepSamples(ch_aparc_aseg, ch_keep)
    dwi_bval_bvec     = ch_dwi_out
    b0                = keepSamples(ch_b0, ch_keep)
    rev_dwi_bval_bvec = keepSamples(ch_rev_dwi_bval_bvec, ch_keep)
    rev_b0            = keepSamples(ch_rev_b0, ch_keep)
    lesion            = keepSamples(ch_lesion, ch_keep)
    versions          = PREPROC_DWICONCATENATE.out.versions
}
