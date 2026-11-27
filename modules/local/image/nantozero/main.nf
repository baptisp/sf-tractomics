// Every non-finite value (NaN, infinity) of a preprocessed DWI set to 0. A few NaN can survive DWI
// preprocessing outside the brain (ADNI b0144 ses-20230314: 224 values in 112 voxels, all outside the
// brain mask, in 2 of 55 volumes), and the AMICO free-water fit (RECONST_FREEWATER, and NODDI) then
// exits with status 64 and writes nothing, while the tensor fit is unaffected. Applied only to the runs
// listed in params.dwi_nan_fix, so every other run keeps its cached free-water and NODDI tasks. The fits
// are done inside the brain mask, so values outside it do not change them.
//
// Output: the DWI (float32) with its b-values and b-vectors unchanged, and nan_count.txt (the number of
// values replaced).
process IMAGE_NANTOZERO {
    tag "$meta.id"
    label 'process_single'

    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple val(meta), path(dwi), path(bval), path(bvec)

    output:
    tuple val(meta), path("*__dwi_finite.nii.gz"), path(bval), path(bvec), emit: dwi
    tuple val(meta), path("*_nan_count.txt"),                              emit: count
    path "versions.yml",                                                    emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    export MRTRIX_NTHREADS=${task.cpus}
    mrcalc -quiet ${dwi} -finite 0 1 -if - | mrstats -quiet - -output count -ignorezero > nonfinite.txt || echo 0 > nonfinite.txt
    tr -d ' ' < nonfinite.txt | awk '{ s += \$1 } END { print s + 0 }' > ${prefix}_nan_count.txt
    mrcalc -quiet ${dwi} -finite ${dwi} 0 -if -datatype float32 ${prefix}__dwi_finite.nii.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/^== mrconvert \\([0-9.]*\\).*/\\1/p')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}__dwi_finite.nii.gz
    echo 0 > ${prefix}_nan_count.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: stub
    END_VERSIONS
    """
}
