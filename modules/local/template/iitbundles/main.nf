// The IIT bundle masks (already thresholded at the IIT recommended values by ATLAS_IIT) placed on
// the study fODF template: the IIT mean b0 registered once to the template's mean b0 (ANTs SyN),
// each mask warped with nearest neighbour onto the template grid. Done once per study, on a sharp
// group average; the per-session fibre cross-section comes from the fODF registration, not from
// this step.
process TEMPLATE_IITBUNDLES {
    tag "IIT to template"
    label 'process_medium'

    container "scilus/scilus:2.2.2"

    input:
    tuple path(template_b0), path(iit_b0), path(bundle_masks, stageAs: "iit_masks/*")

    output:
    path "bundles",                       emit: masks
    path "iit_b0_in_template.nii.gz",     emit: iit_b0
    path "versions.yml",                  emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    """
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=${task.cpus}
    antsRegistrationSyNQuick.sh -d 3 -f ${template_b0} -m ${iit_b0} -o iit2tpl_ -t s -n ${task.cpus} > ants.log
    mv iit2tpl_Warped.nii.gz iit_b0_in_template.nii.gz
    mkdir bundles
    for m in iit_masks/*.nii.gz; do
        name=\$(basename "\$m" .nii.gz)
        antsApplyTransforms -d 3 -i "\$m" -r ${template_b0} -o bundles/\$name.nii.gz -n NearestNeighbor \\
            -t iit2tpl_1Warp.nii.gz -t iit2tpl_0GenericAffine.mat
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ants: \$(antsRegistration --version | sed -n 's/^ANTs Version: //p')
    END_VERSIONS
    """

    stub:
    """
    mkdir bundles
    for m in iit_masks/*; do touch bundles/\$(basename "\$m"); done
    touch iit_b0_in_template.nii.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ants: stub
    END_VERSIONS
    """
}
