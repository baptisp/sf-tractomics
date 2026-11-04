// Final fibre cross-section template directory, given to every later run with --fc_template:
//   fod_template.mif, template_mask.mif, template_b0.nii.gz, iit_b0_in_template.nii.gz
//   fixels/                      template fixels; fixels/bundle-<name>.mif = 1 on the fixels of
//                                the voxels inside the bundle mask (every fixel of those voxels:
//                                a crossing voxel gives its fixels to each bundle passing there)
//   bundles.tsv                  bundle, n_fixels
//   sessions.tsv                 sessions that built the template
//   manifest.json                parameters, sessions and the SHA-256 of every file above; the
//                                per-session CSVs carry the first 12 characters of its own hash
process TEMPLATE_FCBUNDLEFIXELS {
    tag "fc_template"
    label 'process_single'

    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple path(fod_template), path(template_mask), path(template_b0), path(fixels, stageAs: "in_fixels"), path(sessions), path(bundle_masks), path(iit_b0)

    output:
    path "fc_template",  emit: template
    path "versions.yml", emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def params_json = groovy.json.JsonOutput.toJson(task.ext.manifest_params ?: [:])
    """
    mkdir fc_template
    cp -L ${fod_template} ${template_mask} ${template_b0} ${sessions} fc_template/
    cp -L ${iit_b0} fc_template/iit_b0_in_template.nii.gz
    cp -rL ${fixels} fc_template/fixels
    printf "bundle\\tn_fixels\\n" > fc_template/bundles.tsv
    for m in ${bundle_masks}/*.nii.gz; do
        name=\$(basename "\$m" .nii.gz)
        voxel2fixel -quiet "\$m" fc_template/fixels fc_template/fixels bundle-\$name.mif
        n=\$(mrstats -quiet fc_template/fixels/bundle-\$name.mif -ignorezero -output count | tr -d " ")
        printf "%s\\t%s\\n" "\$name" "\$n" >> fc_template/bundles.tsv
    done

    cd fc_template
    {
        printf '{\\n  "parameters": %s,\\n  "sessions": [' '${params_json}'
        tail -n +2 sessions.tsv | awk 'BEGIN{ORS=""} {printf "%s\\"%s\\"", (NR > 1 ? ", " : ""), \$1}'
        printf '],\\n  "files": {\\n'
        find . -type f ! -name manifest.json | sort | while read -r f; do
            printf '    "%s": "%s",\\n' "\${f#./}" "\$(sha256sum "\$f" | cut -d " " -f 1)"
        done | sed '\$ s/,\$//'
        printf '  }\\n}\\n'
    } > manifest.json
    cd ..

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/^== mrconvert \\([0-9.]*\\).*/\\1/p')
    END_VERSIONS
    """

    stub:
    """
    mkdir -p fc_template/fixels
    touch fc_template/fod_template.mif fc_template/template_mask.mif fc_template/fixels/index.mif fc_template/fixels/directions.mif
    cp -L ${sessions} fc_template/
    printf "bundle\\tn_fixels\\n" > fc_template/bundles.tsv
    for m in ${bundle_masks}/*; do
        name=\$(basename "\$m" .nii.gz)
        touch fc_template/fixels/bundle-\$name.mif
        printf "%s\\t0\\n" "\$name" >> fc_template/bundles.tsv
    done
    printf '{"parameters": {}, "sessions": [], "files": {}}\\n' > fc_template/manifest.json

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: stub
    END_VERSIONS
    """
}
