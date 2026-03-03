#!/bin/bash
# MPI Allreduce sanity check using Intel MPI IMB-MPI1
# Runs IMB-MPI1 Allreduce across all allocated nodes to detect bad nodes
# or degraded IB fabric before running the real workload.
#
# Requires: mpi/impi module (Intel MPI) installed at /opt/intel/oneapi/mpi
#
# Usage: source this file, then call:
#   run_mpi_sanity_check <total_cores> <pass_dir>
#
# Returns 0 if healthy, 1 if failed.
# Writes results to <pass_dir>/sanity_check_<SLURM_JOB_ID>.log

# Intel MPI root — used only for the sanity check, does not affect
# the OpenFOAM solver which uses EESSI OpenMPI.
_IMPI_ROOT="/opt/intel/oneapi/mpi/2021.16"
_IMB_MPI1="${_IMPI_ROOT}/bin/IMB-MPI1"

_setup_impi_env() {
    # Temporarily set up Intel MPI environment for the sanity check.
    # We save/restore the caller's PATH and LD_LIBRARY_PATH so we
    # don't pollute the OpenMPI environment used by the solver.
    _SAVED_PATH="$PATH"
    _SAVED_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
    _SAVED_FI_PROVIDER_PATH="${FI_PROVIDER_PATH:-}"

    export I_MPI_ROOT="$_IMPI_ROOT"
    export PATH="${_IMPI_ROOT}/bin:${_IMPI_ROOT}/opt/mpi/libfabric/bin:$PATH"
    export LD_LIBRARY_PATH="${_IMPI_ROOT}/lib:${_IMPI_ROOT}/opt/mpi/libfabric/lib:${LD_LIBRARY_PATH:-}"
    export FI_PROVIDER_PATH="${_IMPI_ROOT}/opt/mpi/libfabric/lib/prov:/usr/lib/x86_64-linux-gnu/libfabric"
}

_restore_env() {
    export PATH="$_SAVED_PATH"
    export LD_LIBRARY_PATH="$_SAVED_LD_LIBRARY_PATH"
    if [[ -n "$_SAVED_FI_PROVIDER_PATH" ]]; then
        export FI_PROVIDER_PATH="$_SAVED_FI_PROVIDER_PATH"
    else
        unset FI_PROVIDER_PATH
    fi
    unset I_MPI_ROOT
}

_parse_imb_allreduce() {
    # Parse IMB-MPI1 Allreduce output and check for anomalies.
    # IMB output format (after header):
    #   #bytes  #repetitions  t_min[usec]  t_max[usec]  t_avg[usec]
    local log_file="$1"
    local max_spread_ratio="$2"  # fail if t_max/t_min > this ratio
    local passed=true

    log "INFO" "IMB-MPI1 Allreduce results:"

    local in_data=false
    while IFS= read -r line; do
        # Skip until we find the data lines (after the column headers)
        if [[ "$line" =~ ^[[:space:]]*#bytes ]]; then
            in_data=true
            log "INFO" "  $line"
            continue
        fi
        if [[ "$in_data" == false ]]; then
            continue
        fi
        # Skip empty lines and comments
        if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then
            continue
        fi
        # Parse data line: bytes reps t_min t_max t_avg
        read -r bytes reps t_min t_max t_avg <<< "$line"
        if [[ -z "$bytes" ]] || [[ "$bytes" == "#"* ]]; then
            continue
        fi

        # Compute spread ratio
        local spread_ratio
        if (( $(echo "$t_min > 0" | bc -l) )); then
            spread_ratio=$(echo "scale=2; $t_max / $t_min" | bc)
        else
            spread_ratio="1.00"
        fi

        log "INFO" "  $(printf '%8s bytes: min=%8.2f us  max=%8.2f us  avg=%8.2f us  spread=%.2fx' \
            "$bytes" "$t_min" "$t_max" "$t_avg" "$spread_ratio")"

        # Check if spread is too large (indicates a bad node or degraded link)
        if (( $(echo "$spread_ratio > $max_spread_ratio" | bc -l) )); then
            log "ERROR" "  ANOMALY at ${bytes} bytes: spread ${spread_ratio}x exceeds threshold ${max_spread_ratio}x"
            passed=false
        fi
    done < "$log_file"

    if [[ "$passed" == true ]]; then
        return 0
    else
        return 1
    fi
}

run_mpi_sanity_check() {
    local total_cores="$1"
    local pass_dir="$2"
    local job_id="${SLURM_JOB_ID:-unknown}"
    local log_file="${pass_dir}/sanity_check_${job_id}.log"
    # Spread threshold: fail if t_max/t_min > 5x at any message size
    local max_spread_ratio=5

    log "INFO" "Running MPI Allreduce sanity check ($total_cores ranks)..."

    # Verify IMB-MPI1 exists
    if [[ ! -x "$_IMB_MPI1" ]]; then
        log "ERROR" "IMB-MPI1 not found at $_IMB_MPI1 — skipping sanity check"
        return 0  # Don't block jobs if benchmark is missing
    fi

    # Use 1 rank per node — we're testing inter-node IB fabric health,
    # not intra-node shared memory. This also avoids Intel MPI shared
    # memory allocation failures under Slurm+OpenMPI environments.
    local test_np="$NNODES"
    local test_ppn=1

    log "INFO" "Sanity check: ${NNODES} nodes × ${test_ppn} ppn = ${test_np} ranks (inter-node fabric test)"
    log "INFO" "Using Intel MPI IMB-MPI1 from ${_IMPI_ROOT}"
    log "INFO" "Node list: ${SLURM_JOB_NODELIST}"

    # Set up Intel MPI environment (isolated from OpenMPI)
    _setup_impi_env

    # Run IMB-MPI1 Allreduce with message sizes from 1 byte to 4MB
    # Use srun (not Intel MPI's mpirun) because Hydra can't resolve the
    # cluster FQDN (ccw-hpc-X.ccw.hpc.local). srun uses Slurm's native
    # launch mechanism which already knows the allocation.
    # -npmin forces all ranks to participate (no scaling sweep)
    # -iter 100 gives enough samples for stable timing
    # -warmup 10 ensures caches and transports are primed
    srun \
        --ntasks="$test_np" \
        --ntasks-per-node="$test_ppn" \
        "$_IMB_MPI1" Allreduce \
        -msglog 0:22 \
        -npmin "$test_np" \
        -iter 100 \
        -warmup 10 \
        > "$log_file" 2>&1
    local rc=$?

    # Restore the original environment for OpenMPI
    _restore_env

    if [[ $rc -ne 0 ]]; then
        log "ERROR" "IMB-MPI1 Allreduce failed (rc=$rc) — see $log_file"
        tail -20 "$log_file"
        return 1
    fi

    # Parse and check results
    if _parse_imb_allreduce "$log_file" "$max_spread_ratio"; then
        log "INFO" "MPI sanity check PASSED — all nodes healthy"
        return 0
    else
        log "ERROR" "MPI sanity check FAILED — possible bad node or degraded IB fabric"
        log "ERROR" "Full results in: $log_file"
        return 1
    fi
}
