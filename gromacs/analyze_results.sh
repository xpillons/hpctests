#!/bin/bash
###############################################################################
# GROMACS Benchmark Suite - Results Analyzer
#
# Parses benchmark_results.csv and generates a summary report identifying
# the optimal parameter combination for maximum ns/day performance.
#
# Usage:
#   ./analyze_results.sh [results_file]
#
# Default: analyzes the latest results pass under ./results/latest/
#
# Usage:
#   ./analyze_results.sh                           # analyze latest pass
#   ./analyze_results.sh results/20260210_quick/    # analyze specific pass
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Accept a directory or CSV file as argument
if [[ $# -gt 0 ]]; then
    if [[ -d "$1" ]]; then
        RESULTS_DIR="$1"
    elif [[ -f "$1" ]]; then
        RESULTS_DIR="$(dirname "$1")"
    else
        echo "ERROR: $1 is not a valid directory or file"
        exit 1
    fi
else
    RESULTS_DIR="${SCRIPT_DIR}/results/latest"
fi

CSV_FILE="${RESULTS_DIR}/benchmark_results.csv"
REPORT_FILE="${RESULTS_DIR}/benchmark_report.txt"

if [[ ! -f "${CSV_FILE}" ]]; then
    echo "ERROR: Results file not found: ${CSV_FILE}"
    echo "Run benchmarks first with: ./run_benchmarks.sh"
    exit 1
fi

# Count completed runs (excluding header and FAILED entries)
TOTAL_RUNS=$(tail -n +2 "${CSV_FILE}" | wc -l)
SUCCESSFUL_RUNS=$(tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | wc -l)
FAILED_RUNS=$(tail -n +2 "${CSV_FILE}" | grep -c "FAILED" || true)

if [[ ${SUCCESSFUL_RUNS} -eq 0 ]]; then
    echo "No successful benchmark results found yet."
    echo "Check if jobs are still running: squeue -u \$USER"
    exit 1
fi

# Generate report
{
    echo "=============================================================================="
    echo "                    GROMACS BENCHMARK RESULTS REPORT"
    echo "=============================================================================="
    echo "Generated: $(date)"
    echo "Results file: ${CSV_FILE}"
    echo ""
    echo "Total runs: ${TOTAL_RUNS}  |  Successful: ${SUCCESSFUL_RUNS}  |  Failed: ${FAILED_RUNS}"
    echo ""

    echo "=============================================================================="
    echo "  ALL RESULTS (sorted by ns/day, descending)"
    echo "=============================================================================="
    echo ""
    printf "%-6s  %-6s  %-5s  %-9s  %-9s  %-10s  %-12s  %s\n" \
        "NP" "NTOMP" "NPME" "GPU_COMM" "GPU_PME_D" "NS/DAY" "WALL_TIME" "RUN_ID"
    printf "%-6s  %-6s  %-5s  %-9s  %-9s  %-10s  %-12s  %s\n" \
        "------" "------" "-----" "---------" "---------" "----------" "------------" "------"

    # Sort by ns/day (column 8), descending, skip FAILED entries
    tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | \
        sort -t',' -k8 -rn | \
        while IFS=',' read -r run_id np ntomp npme gpu_comm gpu_pme_decomp nsteps ns_day wall_time; do
            printf "%-6s  %-6s  %-5s  %-9s  %-9s  %-10s  %-12s  %s\n" \
                "${np}" "${ntomp}" "${npme}" "${gpu_comm}" "${gpu_pme_decomp}" "${ns_day}" "${wall_time}s" "${run_id}"
        done

    echo ""

    # Find optimal configuration
    echo "=============================================================================="
    echo "  OPTIMAL CONFIGURATION"
    echo "=============================================================================="
    echo ""

    BEST_LINE=$(tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | sort -t',' -k8 -rn | head -1)
    IFS=',' read -r best_id best_np best_ntomp best_npme best_gpu_comm best_gpu_pme_decomp best_nsteps best_nsday best_wall <<< "${BEST_LINE}"

    echo "  Best ns/day:              ${best_nsday}"
    echo "  Run ID:                   ${best_id}"
    echo "  MPI ranks (np):           ${best_np}"
    echo "  OpenMP threads (ntomp):   ${best_ntomp}"
    echo "  PME ranks (npme):         ${best_npme} $([ "${best_npme}" = "0" ] && echo "(auto)" || echo "")"
    echo "  GPU direct communication: ${best_gpu_comm}"
    echo "  GPU PME decomposition:    ${best_gpu_pme_decomp}"
    echo "  Simulation steps:         ${best_nsteps}"
    echo "  Wall time:                ${best_wall} seconds"
    echo ""

    # Recommendations
    echo "=============================================================================="
    echo "  RECOMMENDATIONS"
    echo "=============================================================================="
    echo ""
    echo "  Optimal gmx_mpi mdrun command:"
    echo ""

    CMD="    srun -n ${best_np} gmx_mpi mdrun -s benchPEP.tpr -ntomp ${best_ntomp}"
    if [[ "${best_npme}" != "0" ]]; then
        CMD="${CMD} -npme ${best_npme}"
    fi
    if [[ "${best_gpu_comm}" == "yes" ]]; then
        CMD="${CMD} -bonded gpu -nb gpu -pme gpu -update gpu"
    else
        CMD="${CMD} -nb gpu -pme gpu"
    fi
    if [[ "${best_gpu_pme_decomp}" == "yes" ]]; then
        CMD="${CMD} -pmefft gpu"
    fi
    echo "${CMD}"
    echo ""

    if [[ "${best_gpu_comm}" == "yes" ]]; then
        echo "  Environment variables required:"
        echo "    export GMX_ENABLE_DIRECT_GPU_COMM=1"
        echo "    export GMX_FORCE_GPU_AWARE_MPI=1"
    fi
    if [[ "${best_gpu_pme_decomp}" == "yes" ]]; then
        echo "    export GMX_GPU_PME_DECOMPOSITION=1"
    fi

    echo ""

    # Top 5 analysis
    echo "=============================================================================="
    echo "  TOP 5 CONFIGURATIONS"
    echo "=============================================================================="
    echo ""
    RANK=1
    tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | sort -t',' -k8 -rn | head -5 | \
        while IFS=',' read -r run_id np ntomp npme gpu_comm gpu_pme_decomp nsteps ns_day wall_time; do
            echo "  #${RANK}: ${ns_day} ns/day  (np=${np}, ntomp=${ntomp}, npme=${npme}, gpu_comm=${gpu_comm}, gpu_pme_decomp=${gpu_pme_decomp})"
            ((RANK++))
        done

    echo ""

    # Performance by parameter analysis
    echo "=============================================================================="
    echo "  PARAMETER IMPACT ANALYSIS"
    echo "=============================================================================="
    echo ""

    # Effect of GPU direct communication
    echo "  GPU Direct Communication Impact:"
    AVG_NO=$(tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | awk -F',' '$5=="no" {sum+=$8; n++} END {if(n>0) printf "%.3f", sum/n; else print "N/A"}')
    AVG_YES=$(tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | awk -F',' '$5=="yes" {sum+=$8; n++} END {if(n>0) printf "%.3f", sum/n; else print "N/A"}')
    echo "    Without: avg ${AVG_NO} ns/day"
    echo "    With:    avg ${AVG_YES} ns/day"
    echo ""

    # Effect of GPU PME decomposition
    echo "  GPU PME Decomposition Impact:"
    AVG_NO=$(tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | awk -F',' '$6=="no" {sum+=$8; n++} END {if(n>0) printf "%.3f", sum/n; else print "N/A"}')
    AVG_YES=$(tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | awk -F',' '$6=="yes" {sum+=$8; n++} END {if(n>0) printf "%.3f", sum/n; else print "N/A"}')
    echo "    Without: avg ${AVG_NO} ns/day"
    echo "    With:    avg ${AVG_YES} ns/day"
    echo ""

    # Performance by np value
    echo "  Performance by MPI Ranks (np):"
    tail -n +2 "${CSV_FILE}" | grep -v "FAILED" | \
        awk -F',' '{np[$2]+=$8; n[$2]++} END {for(k in np) printf "    np=%-3s: avg %.3f ns/day (%d runs)\n", k, np[k]/n[k], n[k]}' | sort -t= -k2 -n
    echo ""

    # Failed runs
    if [[ ${FAILED_RUNS} -gt 0 ]]; then
        echo "=============================================================================="
        echo "  FAILED RUNS"
        echo "=============================================================================="
        echo ""
        tail -n +2 "${CSV_FILE}" | grep "FAILED" | \
            while IFS=',' read -r run_id np ntomp npme gpu_comm gpu_pme_decomp nsteps ns_day wall_time; do
                echo "  ${run_id} (np=${np}, ntomp=${ntomp}, npme=${npme})"
            done
        echo ""
    fi

    echo "=============================================================================="

} | tee "${REPORT_FILE}"

echo ""
echo "Report saved to: ${REPORT_FILE}"
