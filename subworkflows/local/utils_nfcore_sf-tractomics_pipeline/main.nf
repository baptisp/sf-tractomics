//
// Subworkflow with functionality specific to the scilus/sf-tractomics pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFSCHEMA_PLUGIN     } from '../../nf-core/utils_nfschema_plugin'
include { paramsSummaryMap          } from 'plugin/nf-schema'
include { samplesheetToList         } from 'plugin/nf-schema'
include { completionEmail           } from '../../nf-core/utils_nfcore_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'
include { IO_BIDS                   } from '../../nf-neuro/io_bids/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW TO INITIALISE PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    _monochrome_logs  // boolean: Do not use coloured log outputs
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    input            //  string: Path to input samplesheet
    bids_config      //  string: Path to BIDS JSON configuration file
    help              // boolean: Display help message and exit
    help_full         // boolean: Show the full help message
    show_hidden       // boolean: Show hidden parameters in the help message

    main:

    ch_versions = channel.empty()
    ch_samplesheet = channel.empty()

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        false   // Reinstate when/if we use conda/mamba :
                // workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //
    command = "nextflow run ${workflow.manifest.name} -profile <docker/singularity/.../institute> --input samplesheet.csv --outdir <OUTDIR>"
    before_text = """
-\033[2m----------------------------------------------------------------------------------\033[0m-
   \033[0;32m      _---~~(~~-_.\033[0m
  \033[0;32m    _{        )   )\033[0m
  \033[0;32m  ,   ) -~~- ( ,-' )_\033[0m
  \033[0;32m (  `-,_..`., )-- '_,)\033[0m
  \033[0;32m( ` _)  (  -~( -_ `,  }\033[0m
  \033[0;32m(_-  _  ~_-~~~~`,  ,' )\033[0m
  \033[0;32m  `~ -^(    __;-,((()))\033[0m
  \033[0;32m        ~~~~ {_ -_(())\033[0m
  \033[0;32m               `\\  }\033[0m
  \033[0;32m                 { }\033[0m

 \033[0;34m  __  ___       ___  __   __   __  ___  __   __       __   __   \033[0m
 \033[0;34m (__  |__  ___   |  |__) |__| |     |  |  | |\\/| |   /    (__   \033[0m
 \033[0;34m ___) |          |  |  \\ |  | |__   |  |__| |  | |   \\__  ___)  \033[0m

 \033[0;35m  scilus/sf-tractomics ${workflow.manifest.version}\033[0m
-\033[2m----------------------------------------------------------------------------------\033[0m-
    """
    after_text = """${workflow.manifest.doi ? "\n* The pipeline\n" : ""}${workflow.manifest.doi.tokenize(",").collect { doi -> "    https://doi.org/${doi.trim().replace('https://doi.org/','')}"}.join("\n")}${workflow.manifest.doi ? "\n" : ""}
    * The nf-neuro project
        https://scilus.github.io/nf-neuro

    * The nf-core framework
        https://doi.org/10.1038/s41587-020-0439-x

    * Software dependencies
        https://github.com/scilus/sf-tractomics/blob/master/CITATIONS.md
    """

    UTILS_NFSCHEMA_PLUGIN (
        workflow,
        validate_params,
        null,
        help,
        help_full,
        show_hidden,
        before_text,
        after_text,
        command,
        null
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE (
        nextflow_cli_args
    )

    //
    // Create channel from input file provided through params.bids_config or params.input
    //
    if (bids_config) {
        ch_samplesheet = channel
            .fromList(parseBidsConfig(bids_config))
            .map {
                meta, dwi, bval, bvec, sbref, rev_dwi, rev_bval, rev_bvec, rev_sbref, t1, wmparc, aparc_aseg, lesion ->
                    return [
                        meta,
                        dwi,
                        bval,
                        bvec,
                        sbref ?: [],
                        rev_dwi ?: [],
                        rev_bval ?: [],
                        rev_bvec ?: [],
                        rev_sbref ?: [],
                        t1,
                        wmparc ?: [],
                        aparc_aseg ?: [],
                        lesion ?: []
                    ]
            }
            .map { samplesheet ->
                validateInputSamplesheet(samplesheet)
            }.multiMap { meta, dwi, bval, bvec, sbref, rev_dwi, rev_bval, rev_bvec, rev_sbref, t1, wmparc, aparc_aseg, lesion ->
                t1: [meta, t1]
                wmparc: [meta, wmparc]
                aparc_aseg: [meta, aparc_aseg]
                dwi_bval_bvec: [meta, dwi, bval, bvec]
                b0: [meta, sbref]
                rev_dwi_bval_bvec: [meta, rev_dwi, rev_bval, rev_bvec]
                rev_b0: [meta, rev_sbref]
                lesion: [meta, lesion]
            }

        if (params.participants_tsv) {
            participants_tsv_path = params.participants_tsv
        }
        else {
            participants_tsv_path = null
            log.warn("No participants.tsv provided, covariates will not be used.")
        }
    }
    else if (input) {
        //
        // params.input is either a BIDS compliant directory or a samplesheet
        //   - if directory, we assume it is BIDS
        //   - everything else is a samplesheet
        //
        if (file(input).isDirectory()) {
            IO_BIDS(
                channel.fromPath(input),
                channel.value(params.fsbids ?: []),
                channel.value(params.bidsignore ?: [])
            )
            ch_samplesheet = [
                t1: IO_BIDS.out.ch_t1,
                wmparc: IO_BIDS.out.ch_wmparc,
                aparc_aseg: IO_BIDS.out.ch_aparc_aseg,
                dwi_bval_bvec: IO_BIDS.out.ch_dwi_bval_bvec,
                b0: IO_BIDS.out.ch_b0,
                rev_dwi_bval_bvec: IO_BIDS.out.ch_rev_dwi_bval_bvec,
                rev_b0: IO_BIDS.out.ch_rev_b0,
                lesion: channel.empty()
            ]

            if (params.participants_tsv) {
                participants_tsv_path = "${params.participants_tsv}"
            }
            else if (file("${input}/participants.tsv").exists()) {
                participants_tsv_path = "${input}/participants.tsv"
            }
            else {
                participants_tsv_path = null
                log.warn("No participants.tsv provided, covariates will not be used.")
            }
        }
        else {
            ch_samplesheet = channel
                .fromList(samplesheetToList(input, "${projectDir}/assets/schema_input.json"))
                .map{
                    meta, dwi, bval, bvec, sbref, rev_dwi, rev_bval, rev_bvec, rev_sbref, t1, wmparc, aparc_aseg, lesion ->
                        return [
                            meta,
                            dwi,
                            bval,
                            bvec,
                            sbref ?: [],
                            rev_dwi ?: [],
                            rev_bval ?: [],
                            rev_bvec ?: [],
                            rev_sbref ?: [],
                            t1,
                            wmparc ?: [],
                            aparc_aseg ?: [],
                            lesion ?: []
                        ]
                }
                .map{ samplesheet ->
                    validateInputSamplesheet(samplesheet)
                }.multiMap{ meta, dwi, bval, bvec, sbref, rev_dwi, rev_bval, rev_bvec, rev_sbref, t1, wmparc, aparc_aseg, lesion ->
                    t1: [meta, t1]
                    wmparc: [meta, wmparc]
                    aparc_aseg: [meta, aparc_aseg]
                    dwi_bval_bvec: [meta, dwi, bval, bvec]
                    b0: [meta, sbref]
                    rev_dwi_bval_bvec: [meta, rev_dwi, rev_bval, rev_bvec]
                    rev_b0: [meta, rev_sbref]
                    lesion: [meta, lesion]
                }

            if (params.participants_tsv) {
                participants_tsv_path = params.participants_tsv
            } else {
                participants_tsv_path = null
                log.warn("No participants.tsv provided, covariates will not be used.")
            }
        }
    }
    else {
        error "Please provide one input source: --input or --bids_config"
    }

    // We avoid merging the covariates (i.e. the extra meta fields)
    // directly into the samplesheet's multimap meta fields, as those covariates are not used
    // in most of the pipeline steps. This means, that if the participants.tsv changes for whatever
    // reason, the entire cache of the pipeline would be invalidated, thus causing the
    // pipeline to reprocess everything from scratch. Instead, we provide the mergeCovariatesIntoMeta
    // function, which can be used to merge the covariates into the samplesheet's multimap
    // on the fly, when needed (which should be done only when the inputs requires those fields).
    ch_covariates = parseParticipantsTsv(participants_tsv_path, ch_samplesheet.t1)

    def participants_to_include = []
    def participants_to_exclude = []

    if (params.participant_label) {
        participants_to_include = params.participant_label.split(",").collect { item -> item.trim() }
        log.info "Including participants: ${participants_to_include.join(", ")}"
    }

    if (params.exclude_participant_label) {
        participants_to_exclude = params.exclude_participant_label.split(",").collect { item -> item.trim() }
        log.info "Excluding participants: ${participants_to_exclude.join(", ")}"
    }

    if (participants_to_include || participants_to_exclude) {
        ch_samplesheet = ch_samplesheet.collectEntries { key, value ->
            def filtered = value.filter { item ->
                def meta = item[0]

                // The user can provide a list of subjects to include or to exclude, separated by commas
                // in the same format as the prefix (i.e. sub-XX_ses-XX_run-XX). The implementation
                // allows the user to provide a list of subjects of different scopes to run.
                // For example, if the user provides:
                // sub-01, then all sessions and runs of sub-01 will be processed.
                // sub-01_ses-01, then all runs of sub-01_ses-01 will be processed.
                // sub-01_ses-01_run-01, then only sub-01_ses-01_run-01 will be processed.

                def sid = [meta.id].findAll { x -> x }.join("_")
                def sid_ses = [meta.id, meta.session].findAll { x -> x }.join("_")
                def sid_run = [meta.id, meta.session, meta.run].findAll { x -> x }.join("_")

                def is_included = sid in participants_to_include ||
                    sid_ses in participants_to_include ||
                    sid_run in participants_to_include

                def is_excluded = sid in participants_to_exclude ||
                    sid_ses in participants_to_exclude ||
                    sid_run in participants_to_exclude

                // If inclusion list is provided, only keep the participant if in that list
                // and not in the exclusion list.
                if (participants_to_include) {
                    return is_included && !is_excluded
                }
                // If we only have an exclusion list, filter out participants in that list
                return !is_excluded
            }

            return [key, filtered]
        }
    }

    emit:
    t1 = ch_samplesheet.t1
    wmparc = ch_samplesheet.wmparc
    aparc_aseg = ch_samplesheet.aparc_aseg
    dwi_bval_bvec = ch_samplesheet.dwi_bval_bvec
    b0 = ch_samplesheet.b0
    rev_dwi_bval_bvec = ch_samplesheet.rev_dwi_bval_bvec
    rev_b0 = ch_samplesheet.rev_b0
    lesion = ch_samplesheet.lesion
    covariates  = ch_covariates

    versions    = ch_versions
}


// BIDS omits the 'run' entity from a file's name when a subject/session has
// only a single run — that acquisition is implicitly run 1. A
// participants.tsv row for the same acquisition may still record run=1
// explicitly. So an absent run is canonicalized to "run-1" on both the tsv
// side and the BIDS meta side in parseParticipantsTsv() below — this never
// changes the key for any run explicitly numbered 2 or higher, so distinct
// runs (with or without an explicit run entity, or a mix of both within the
// same session) are never collapsed into one another.
def canonicalTsvRun(r) {
    return r ? "run-${r}" : "run-1"
}

// Different cohorts format the participants.tsv 'session' column differently:
// some store the bare label (e.g. "20170621"), others already include the
// BIDS 'ses-' prefix (e.g. "ses-d0757", seen in OASIS3). Unconditionally
// prepending "ses-" double-prefixes the latter ("ses-ses-d0757"), which then
// never matches the BIDS meta's "ses-d0757" — silently dropping every
// covariate for that cohort. Both forms are normalized to the same "ses-..."
// key used by the BIDS-parsed metadata.
def canonicalTsvSession(s) {
    if (!s) return ""
    return s.startsWith("ses-") ? s : "ses-${s}"
}

def parseParticipantsTsv(participants_path, ch_with_proper_meta) {

    if (participants_path == null) {
        return channel.empty()
    }

    // Define the schema for participants.tsv
    def tsv_file = file(participants_path)
    def all_tsv_headers = tsv_file.readLines()[0].split('\t')
        .collect { item -> item.trim() }
        .toList()

    // Plain, synchronous (non-channel) lookup of every explicit run recorded per
    // (id, session) in participants.tsv, regardless of whether it matches any BIDS
    // file. Read directly here rather than reusing the reactive participants_rows
    // channel below, since this needs to be an ordinary Groovy value usable inside
    // the ch_original_meta .map() closure further down -- a channel's contents
    // aren't available synchronously at that point.
    def id_col = all_tsv_headers.indexOf('participant_id')
    def ses_col = all_tsv_headers.indexOf('session')
    def run_col = all_tsv_headers.indexOf('run')
    def tsv_runs_by_idses = [:]
    tsv_file.readLines().drop(1).findAll { line -> line.trim() }.each { line ->
        def cols = line.split('\t', -1)
        def idses = [cols[id_col].trim(), canonicalTsvSession(cols[ses_col].trim())]
        def run = canonicalTsvRun(run_col < cols.size() ? cols[run_col].trim() : "")
        tsv_runs_by_idses.computeIfAbsent(idses, { [] as Set }) << run
    }

    // Create joining keys
    def primary_keys = ['participant_id', 'session', 'run']
    def content_keys = all_tsv_headers - primary_keys
    def default_content = content_keys.collectEntries { key -> [key, ""] }

    // Parse "${params.inputs}/participants.tsv"
    def ch_participants = channel.fromPath(tsv_file)
    def participants_rows = ch_participants
        .splitCsv(header: true, sep: '\t')
        .map { row ->
            def id = row.participant_id
            def ses = canonicalTsvSession(row.session)
            def run = canonicalTsvRun(row.run)

            def key = [id: id, session: ses, run: run]
            def content = default_content.clone()
            content_keys.each { ckey -> content[ckey] = row[ckey] }
            content = content.collectEntries { k, v -> [k.toLowerCase(), v] }
            return [key, content, row]
        }
    def participants_content = participants_rows.map { key, content, _row -> [key, content] }

    // Prepare keys — an absent 'run' entity in the BIDS metadata (single-run
    // subject/session) is treated the same as tsv run=1, see canonicalTsvRun above.
    def ch_original_meta = ch_with_proper_meta
        .map { meta, _content ->
            def key = [id: meta.id, session: meta.session ?: "", run: meta.run ?: "run-1"]
            return [key, meta]
        }

    // Verify every participants.tsv entry is associated with exactly one file.
    // A row is not "unique" when its key matches zero files (no data for that
    // entry), more than one file (ambiguous — e.g. duplicate acquisitions
    // resolving to the same run), or when another participants.tsv row shares
    // its key (the tsv itself can't tell the files apart). Any of these means
    // covariates may silently end up associated with the wrong file, so all
    // offending entries are reported together in a single warning.
    // (tagged and mixed into one channel, then split back apart in the
    // subscriber — combine()/join()/collect() would instead flatten the
    // already-list-shaped [tag, key, row] items into extra tuple slots, so
    // toList() is used here to keep each entry intact as a nested list)
    participants_rows
        .map { key, _content, row -> ["tsv", key, row] }
        .mix(ch_original_meta.map { key, meta -> ["bids", key, meta.run] })
        .toList()
        .subscribe { entries ->
            def tsv_entries = entries.findAll { tag, _key, _row -> tag == "tsv" }
                .collect { _tag, key, row -> [key, row] }
            def bids_counts = entries.findAll { tag, _key, _row -> tag == "bids" }
                .collect { _tag, key, _row -> key }
                .countBy { it }
            def tsv_counts  = tsv_entries.collect { key, _row -> key }.countBy { it }

            def offenders = tsv_entries.findAll { key, _row ->
                (bids_counts[key] ?: 0) != 1 || (tsv_counts[key] ?: 0) != 1
            }

            // Split into two distinct problems:
            //  - ambiguous: the entry DOES match at least one file, but the
            //    association isn't 1:1 (duplicate tsv rows for the same run,
            //    and/or more than one file resolving to that run). This is
            //    always worth a full, itemized warning — it's rare and means
            //    covariates may be silently assigned to the wrong file.
            //  - unmatched: the entry matches zero files. This is routine
            //    when participants.tsv is a superset cohort table and the
            //    current run only stages a subset of subjects, so it gets a
            //    one-line summary count first, followed by the full list
            //    (useful for auditing, but not the headline).
            def ambiguous = offenders.findAll { key, _row -> (bids_counts[key] ?: 0) > 0 }
            def unmatched = offenders.findAll { key, _row -> (bids_counts[key] ?: 0) == 0 }

            if (ambiguous) {
                def details = ambiguous.collect { key, row ->
                    def reasons = []
                    if ((bids_counts[key] ?: 0) > 1) {
                        reasons << "matches ${bids_counts[key]} files"
                    }
                    if ((tsv_counts[key] ?: 0) > 1) {
                        reasons << "shares its (id, session, run) with ${tsv_counts[key] - 1} " +
                            "other participants.tsv row(s)"
                    }
                    "  - participant_id=${row.participant_id} session=${row.session ?: ''} " +
                        "run=${row.run ?: ''} (${reasons.join('; ')})"
                }
                log.warn("parseParticipantsTsv: the following participants.tsv entries are " +
                    "ambiguously associated with files:\n" + details.join("\n"))
            }

            if (unmatched) {
                log.warn("parseParticipantsTsv: ${unmatched.size()} participants.tsv entries " +
                    "have no matching file in this run (expected if participants.tsv is a " +
                    "superset covering more subjects than this run's BIDS input).")

                // log.debug (not log.warn): still fully captured in
                // .nextflow.log for auditing, but this list can be in the
                // thousands (see the summary count above) and would flood
                // the terminal if printed at warn level.
                def details = unmatched.collect { _key, row ->
                    "  - participant_id=${row.participant_id} session=${row.session ?: ''} " +
                        "run=${row.run ?: ''}"
                }
                log.debug("parseParticipantsTsv: full list of participants.tsv entries with no " +
                    "matching file:\n" + details.join("\n"))
            }

            // Extra safeguard: a BIDS file with no run entity in its name defaults to
            // "run-1" (see canonicalTsvRun above) purely because that's the only sensible
            // guess when there's nothing to go on. But if participants.tsv actually records
            // an explicit, different run for this same (id, session), guessing "run-1"
            // could silently mislabel it. Flag every such case loudly rather than let the
            // default apply unnoticed -- this does NOT change what value is used for the
            // join key here (still "run-1", so existing join/covariate behavior is
            // unchanged), it only surfaces the ambiguity so it can be checked by hand.
            def bids_entries = entries.findAll { tag, _key, _run -> tag == "bids" }
                .collect { _tag, key, orig_run -> [key, orig_run] }
            def run_conflicts = bids_entries.findAll { key, orig_run ->
                def tsv_runs = tsv_runs_by_idses[[key.id, key.session]]
                !orig_run && tsv_runs && tsv_runs != (["run-1"] as Set)
            }
            if (run_conflicts) {
                def details = run_conflicts.collect { key, _orig_run ->
                    def tsv_runs = tsv_runs_by_idses[[key.id, key.session]]
                    "  - participant_id=${key.id} session=${key.session}: BIDS file has no run " +
                        "entity (defaults to run-1), but participants.tsv records run(s) " +
                        "${tsv_runs.sort()} for this subject/session -- verify by hand which run " +
                        "this file actually corresponds to."
                }
                log.warn("parseParticipantsTsv: possible run-number conflicts between BIDS " +
                    "metadata and participants.tsv (still defaulting to run-1 despite this " +
                    "mismatch):\n" + details.join("\n"))
            }
        }

    // Join with participants.tsv content
    def ch_covariates = ch_original_meta
        .join(participants_content, by: 0, remainder: true)
        .filter { _key, original_meta, _tsv_meta -> original_meta != null } // Remove unmatched entries from the participants.tsv
        .map { _key, original_meta, tsv_meta ->
            def extra_meta = tsv_meta ?: default_content.collectEntries { k, v -> [k.toLowerCase(), v] }
            return [original_meta, extra_meta]
        }

    return ch_covariates
}

def mergeCovariatesIntoMeta(ch_src, ch_covariates) {
    if (params.participants_tsv == null && !file(params.input).isDirectory()) {
        // The input is a samplesheet and no participants.tsv was provided.
        // So there are no covariates to parse.
        return ch_src
    }

    // Be careful on modifying the following lines, since there are 4 cases to handle.
    // 1- If there's no covariates to add to the meta field.
    // 2- Some subjects in the ch_src might not have a match in the participants.tsv,
    //    so they won't have covariates to merge.
    // 3- Some subjects in the participants.tsv might not have a match in the ch_src,
    //    so they won't be merged at all (and that's fine since they don't have any
    //    data to process in the pipeline).
    // 4- For the subjects that have a match in the participants.tsv, we want to merge
    //    the covariates into the meta field without overwriting any existing fields
    //    in the meta (in case of any naming conflict, the original meta field takes
    //    precedence over the participants.tsv content).
    def ch = ch_src.join(ch_covariates, by: 0, remainder: true)
        .map { item ->
            def original_meta = item[0]
            def content = item[1..-2]
            def covariates = item[-1]

            if ( !covariates ) {
                // No covariates to merge
                return [original_meta] + content
            }
            // Merge original meta with covariates without overwriting existing fields
            def merged_meta = original_meta.clone()
            covariates.each { k, v ->
                if (merged_meta[k] == null || merged_meta[k] == "") {
                    merged_meta[k] = v
                }
            }
            return [merged_meta] + content
        }
        // We need to filter out the entries from the
        // participants.tsv that don't have a match in the ch_src.
        // Required since the remainder join will keep all unmatched
        // entries from the participants.tsv.
        .filter { item -> item[0] != null && item[1] != null }
    return ch
}
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW FOR PIPELINE COMPLETION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_COMPLETION {

    take:
    email           //  string: email address
    email_on_fail   //  string: email address sent on pipeline failure
    plaintext_email // boolean: Send plain-text email instead of HTML
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    hook_url        //  string: hook URL for notifications
    multiqc_report  //  string: Path to MultiQC report

    main:
    summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def multiqc_reports = multiqc_report.toList()

    //
    // Completion email and summary
    //
    workflow.onComplete {
        if (email || email_on_fail) {
            completionEmail(
                summary_params,
                email,
                email_on_fail,
                plaintext_email,
                outdir,
                monochrome_logs,
                multiqc_reports.getVal(),
            )
        }

        completionSummary(monochrome_logs)
    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to troubleshooting docs: https://nf-co.re/docs/usage/troubleshooting"
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Validate channels from input samplesheet
//
def validateInputSamplesheet(input) {
    return input
}

//
// Parse subjects from a BIDS JSON configuration file.
//
def parseBidsConfig(config_path) {
    def config_file = file(config_path)

    if (!config_file.exists()) {
        error "BIDS config file does not exist: ${config_path}"
    }

    def config = new groovy.json.JsonSlurper().parseText(config_file.text)

    if (!(config instanceof List)) {
        error "BIDS config must be a JSON array of subject objects"
    }

    return config.collect { sample ->
        if (!sample.subject) {
            error "Each entry in bids_config must define 'subject'"
        }
        if (!sample.dwi || !sample.bval || !sample.bvec || !sample.t1) {
            error "Each entry in bids_config must define required fields: dwi, bval, bvec, t1"
        }

        def subject_raw = sample.subject.toString()
        def session_raw = sample.session != null ? sample.session.toString() : ""
        def run_raw = (sample.containsKey('run') && sample.run != null) ? sample.run.toString() : ""

        def subject_id = subject_raw.startsWith("sub-") ? subject_raw : "sub-${subject_raw}"
        def session_id = session_raw ? (session_raw.startsWith("ses-") ? session_raw : "ses-${session_raw}") : ""

        // Match IO_BIDS behavior: run "0" in TractoFlow configs is treated as unset.
        def run_id = ""
        if (run_raw && run_raw != "0" && run_raw != "run-0") {
            run_id = run_raw.startsWith("run-") ? run_raw : "run-${run_raw}"
        }

        // Keep a minimal, normalized metadata shape consistent with IO_BIDS.
        def meta = [
            id          : subject_id,
            session     : session_id,
            run         : run_id,
            dwi_tr      : sample.TotalReadoutTime,
            dwi_phase   : sample.DWIPhaseEncodingDir,
            dwi_revphase: sample.rev_DWIPhaseEncodingDir
        ]

        return [
            meta,
            sample.dwi,
            sample.bval,
            sample.bvec,
            sample.topup ?: null,
            sample.rev_dwi ?: null,
            sample.rev_bval ?: null,
            sample.rev_bvec ?: null,
            sample.rev_topup ?: null,
            sample.t1,
            sample.wmparc ?: null,
            sample.aparc_aseg ?: null,
            sample.lesion ?: null
        ]
    }
}

//
// Generate methods description for MultiQC
//
def toolCitationText() {
    // TODO nf-core: Optionally add in-text citation tools to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "Tool (Foo et al. 2023)" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def citation_text = [
            "Tools used in the workflow included:",
            "MultiQC (Ewels et al. 2016)",
            "."
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    // TODO nf-core: Optionally add bibliographic entries to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "<li>Author (2023) Pub name, Journal, DOI</li>" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def reference_text = [
            "<li>Ewels, P., Magnusson, M., Lundin, S., & Käller, M. (2016). MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics , 32(19), 3047–3048. doi: /10.1093/bioinformatics/btw354</li>"
        ].join(' ').trim()

    return reference_text
}

def methodsDescriptionText(mqc_methods_yaml) {
    // Convert  to a named map so can be used as with familiar NXF ${workflow} variable syntax in the MultiQC YML file
    def meta = [:]
    meta.workflow = workflow.toMap()
    meta["manifest_map"] = workflow.manifest.toMap()

    // Pipeline DOI
    if (meta.manifest_map.doi) {
        // Using a loop to handle multiple DOIs
        // Removing `https://doi.org/` to handle pipelines using DOIs vs DOI resolvers
        // Removing ` ` since the manifest.doi is a string and not a proper list
        def temp_doi_ref = ""
        def manifest_doi = meta.manifest_map.doi.tokenize(",")
        manifest_doi.each { doi_ref ->
            temp_doi_ref += "(doi: <a href=\'https://doi.org/${doi_ref.replace("https://doi.org/", "").replace(" ", "")}\'>${doi_ref.replace("https://doi.org/", "").replace(" ", "")}</a>), "
        }
        meta["doi_text"] = temp_doi_ref.substring(0, temp_doi_ref.length() - 2)
    } else meta["doi_text"] = ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "" : "<li>If available, make sure to update the text to include the Zenodo DOI of version of the pipeline used. </li>"

    // Tool references
    meta["tool_citations"] = ""
    meta["tool_bibliography"] = ""

    // TODO nf-core: Only uncomment below if logic in toolCitationText/toolBibliographyText has been filled!
    // meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    // meta["tool_bibliography"] = toolBibliographyText()


    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}
