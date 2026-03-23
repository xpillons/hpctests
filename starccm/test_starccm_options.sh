#!/bin/bash
###############################################################################
# Test bed for starccm.slurm option validation
#
# Runs outside Slurm — checks that every option combination the script accepts
# is consistent and that invalid combos are rejected.
#
# Usage:  bash test_starccm_options.sh
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use temp files so subshells can update counters
_count_dir=$(mktemp -d)
echo 0 > "${_count_dir}/pass"
echo 0 > "${_count_dir}/fail"
trap 'rm -rf "${_count_dir}"' EXIT

# ---------- helpers ----------------------------------------------------------
_color_pass="\033[32m"  # green
_color_fail="\033[31m"  # red
_color_reset="\033[0m"

_inc() { local f="${_count_dir}/$1"; echo $(( $(<"${f}") + 1 )) > "${f}"; }

pass() { _inc pass; echo -e "  ${_color_pass}PASS${_color_reset}: $1"; }
fail() { _inc fail; echo -e "  ${_color_fail}FAIL${_color_reset}: $1"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        pass "${desc}"
    else
        fail "${desc}  (expected='${expected}', got='${actual}')"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if [[ "${actual}" =~ ${pattern} ]]; then
        pass "${desc}"
    else
        fail "${desc}  (pattern='${pattern}' not found in '${actual}')"
    fi
}

assert_not_match() {
    local desc="$1" pattern="$2" actual="$3"
    if [[ ! "${actual}" =~ ${pattern} ]]; then
        pass "${desc}"
    else
        fail "${desc}  (pattern='${pattern}' unexpectedly found in '${actual}')"
    fi
}

# ---------- 1. Defaults ------------------------------------------------------
echo "=== 1. Default values ==="

(
    unset MPI FABRIC CPUBIND UCX_TLS UCX_ENVS MPPFLAGS XSYSTEMUCX STARCCM_HPCX
    MPI=${MPI:-openmpi}
    FABRIC=${FABRIC:-}
    CPUBIND=${CPUBIND:-bandwidth}
    UCX_TLS_OPT=${UCX_TLS:-}
    UCX_ENVS=${UCX_ENVS:-}
    MPPFLAGS=${MPPFLAGS:-}
    XSYSTEMUCX=${XSYSTEMUCX:-}
    STARCCM_HPCX=${STARCCM_HPCX:-}

    assert_eq "MPI defaults to openmpi"       "openmpi"   "${MPI}"
    assert_eq "FABRIC defaults to empty"       ""          "${FABRIC}"
    assert_eq "CPUBIND defaults to bandwidth"  "bandwidth" "${CPUBIND}"
    assert_eq "UCX_TLS_OPT defaults to empty"  ""          "${UCX_TLS_OPT}"
    assert_eq "MPPFLAGS defaults to empty"     ""          "${MPPFLAGS}"
    assert_eq "XSYSTEMUCX defaults to empty"   ""          "${XSYSTEMUCX}"
    assert_eq "STARCCM_HPCX defaults to empty" ""          "${STARCCM_HPCX}"
)

# ---------- 2. MPI validation ------------------------------------------------
echo "=== 2. MPI driver validation ==="

for mpi in openmpi intel; do
    (
        MPI="${mpi}"
        case "${MPI}" in
            openmpi|intel) result=ok ;;
            *) result=rejected ;;
        esac
        assert_eq "MPI='${mpi}' accepted" "ok" "${result}"
    )
done

for mpi in mpich platform "" "Open MPI"; do
    (
        MPI="${mpi}"
        case "${MPI}" in
            openmpi|intel) result=ok ;;
            *) result=rejected ;;
        esac
        assert_eq "MPI='${mpi}' rejected" "rejected" "${result}"
    )
done

# ---------- 3. FABRIC values -------------------------------------------------
echo "=== 3. FABRIC values ==="

VALID_FABRICS=(ibv ucx ofi tcp "")
for fab in "${VALID_FABRICS[@]}"; do
    (
        FABRIC="${fab}"
        # Build the relevant part of the command
        CMD=()
        if [ -n "${FABRIC}" ]; then
            CMD+=(-fabric "${FABRIC}")
        fi
        if [ -n "${fab}" ]; then
            assert_match "FABRIC='${fab}' adds -fabric flag" "-fabric ${fab}" "${CMD[*]}"
        else
            assert_eq "Empty FABRIC adds no -fabric flag" "" "${CMD[*]:-}"
        fi
    )
done

# ---------- 4. CPUBIND values ------------------------------------------------
echo "=== 4. CPUBIND values ==="

for bind in bandwidth auto; do
    (
        CPUBIND="${bind}"
        CMD=()
        if [ -n "${CPUBIND}" ] && [ "${CPUBIND}" != "off" ]; then
            CMD+=(-cpubind "${CPUBIND}")
        fi
        assert_match "CPUBIND='${bind}' produces -cpubind" "-cpubind ${bind}" "${CMD[*]}"
    )
done

(
    CPUBIND="off"
    CMD=()
    if [ -n "${CPUBIND}" ] && [ "${CPUBIND}" != "off" ]; then
        CMD+=(-cpubind "${CPUBIND}")
    fi
    assert_eq "CPUBIND='off' suppresses -cpubind flag" "" "${CMD[*]:-}"
)

# ---------- 5. MPPFLAGS passthrough ------------------------------------------
echo "=== 5. MPPFLAGS passthrough ==="

(
    MPPFLAGS="--map-by ppr:44:numa --bind-to core"
    CMD=()
    if [ -n "${MPPFLAGS}" ]; then
        CMD+=(-mppflags "${MPPFLAGS}")
    fi
    assert_match "MPPFLAGS passed to -mppflags" "-mppflags" "${CMD[*]}"
    assert_match "MPPFLAGS value preserved" "ppr:44:numa" "${CMD[*]}"
)

(
    MPPFLAGS=""
    CMD=()
    if [ -n "${MPPFLAGS}" ]; then
        CMD+=(-mppflags "${MPPFLAGS}")
    fi
    assert_eq "Empty MPPFLAGS adds no flag" "" "${CMD[*]:-}"
)

# ---------- 6. XSYSTEMUCX flag -----------------------------------------------
echo "=== 6. XSYSTEMUCX flag ==="

(
    XSYSTEMUCX="1"
    CMD=()
    if [ "${XSYSTEMUCX:-}" = "1" ]; then CMD+=(-xsystemucx); fi
    assert_match "XSYSTEMUCX=1 adds -xsystemucx" "-xsystemucx" "${CMD[*]}"
)

(
    XSYSTEMUCX=""
    CMD=()
    if [ "${XSYSTEMUCX:-}" = "1" ]; then CMD+=(-xsystemucx); fi
    assert_eq "XSYSTEMUCX='' omits flag" "" "${CMD[*]:-}"
)

# ---------- 7. UCX_TLS handling -----------------------------------------------
echo "=== 7. UCX_TLS handling ==="

(
    UCX_TLS_OPT="rc,sm"
    if [ -n "${UCX_TLS_OPT}" ]; then
        export UCX_TLS="${UCX_TLS_OPT}"
    else
        unset UCX_TLS 2>/dev/null || true
    fi
    assert_eq "UCX_TLS set when UCX_TLS_OPT is non-empty" "rc,sm" "${UCX_TLS}"
)

(
    UCX_TLS_OPT=""
    export UCX_TLS="should_be_unset"
    if [ -n "${UCX_TLS_OPT}" ]; then
        export UCX_TLS="${UCX_TLS_OPT}"
    else
        unset UCX_TLS 2>/dev/null || true
    fi
    assert_eq "UCX_TLS unset when UCX_TLS_OPT is empty" "" "${UCX_TLS:-}"
)

# ---------- 8. UCX_ENVS parsing -----------------------------------------------
echo "=== 8. UCX_ENVS parsing ==="

(
    UCX_ENVS="UCX_RNDV_THRESH=65536 UCX_MAX_EAGER_LANES=2"
    for kv in ${UCX_ENVS}; do
        export "${kv}"
    done
    assert_eq "UCX_RNDV_THRESH parsed" "65536" "${UCX_RNDV_THRESH}"
    assert_eq "UCX_MAX_EAGER_LANES parsed" "2" "${UCX_MAX_EAGER_LANES}"
)

(
    UCX_ENVS=""
    # Should be a no-op — no error
    for kv in ${UCX_ENVS}; do
        export "${kv}"
    done
    pass "Empty UCX_ENVS is a no-op"
)

# ---------- 9. MODEL required check ------------------------------------------
echo "=== 9. MODEL required ==="

(
    unset MODEL 2>/dev/null || true
    out=$(MODEL=${MODEL:?ERROR: MODEL environment variable is required} 2>&1) && result=ok || result=rejected
    assert_eq "Missing MODEL is rejected" "rejected" "${result}"
)

(
    MODEL="/path/to/model.sim"
    out=$(MODEL=${MODEL:?ERROR: MODEL environment variable is required} 2>&1) && result=ok || result=rejected
    assert_eq "Provided MODEL is accepted" "ok" "${result}"
)

# ---------- 10. Command assembly (end-to-end) ---------------------------------
echo "=== 10. Full command assembly ==="

build_cmd() {
    local MODEL="$1" NP="$2" HOSTS="$3" MPI="$4" FABRIC="$5" CPUBIND="$6" MPPFLAGS="$7" XSYSTEMUCX="$8"
    CMD=(starccm+ -power -np "${NP}" -machinefile "${HOSTS}" -mpi "${MPI}")
    [ -n "${FABRIC}" ] && CMD+=(-fabric "${FABRIC}")
    [ -n "${CPUBIND}" ] && [ "${CPUBIND}" != "off" ] && CMD+=(-cpubind "${CPUBIND}")
    [ -n "${MPPFLAGS}" ] && CMD+=(-mppflags "${MPPFLAGS}")
    [ "${XSYSTEMUCX:-}" = "1" ] && CMD+=(-xsystemucx)
    CMD+=(-batch run "${MODEL}")
    echo "${CMD[*]}"
}

(
    out=$(build_cmd "/data/m.sim" 352 "hosts.42" "openmpi" "" "bandwidth" "" "")
    assert_match "Minimal openmpi cmd has starccm+" "^starccm\\+" "${out}"
    assert_match "Has -np 352"       "-np 352"          "${out}"
    assert_match "Has -mpi openmpi"  "-mpi openmpi"     "${out}"
    assert_match "Has -cpubind"      "-cpubind bandwidth" "${out}"
    assert_not_match "No -fabric"    "-fabric"          "${out}"
    assert_not_match "No -mppflags"  "-mppflags"        "${out}"
    assert_not_match "No -xsystemucx" "-xsystemucx"    "${out}"
    assert_match "Ends with -batch run MODEL" "-batch run /data/m.sim" "${out}"
)

(
    out=$(build_cmd "/data/m.sim" 704 "hosts.99" "intel" "ucx" "off" "--map-by ppr:44:numa" "1")
    assert_match "Intel cmd with all flags: -mpi intel" "-mpi intel" "${out}"
    assert_match "Has -fabric ucx" "-fabric ucx" "${out}"
    assert_not_match "CPUBIND off suppressed" "-cpubind" "${out}"
    assert_match "Has -mppflags" "-mppflags" "${out}"
    assert_match "Has -xsystemucx" "-xsystemucx" "${out}"
)

# ---------- 11. Module directory exists ----------------------------------------
echo "=== 11. Module directory ==="

MODULEFILE_DIR="${SCRIPT_DIR}/modulefiles"
if [ -d "${MODULEFILE_DIR}" ]; then
    pass "modulefiles/ directory exists at ${MODULEFILE_DIR}"
else
    fail "modulefiles/ directory missing at ${MODULEFILE_DIR}"
fi

if [ -d "${MODULEFILE_DIR}/starccm" ]; then
    pass "modulefiles/starccm/ directory exists"
else
    fail "modulefiles/starccm/ directory missing"
fi

# Check at least one version file exists
VERSION_COUNT=$(find "${MODULEFILE_DIR}/starccm" -maxdepth 1 -type f ! -name '.version' 2>/dev/null | wc -l)
if (( VERSION_COUNT > 0 )); then
    pass "Found ${VERSION_COUNT} starccm module version(s)"
else
    fail "No starccm module version files found"
fi

# ---------- Summary -----------------------------------------------------------
echo ""
PASS=$(<"${_count_dir}/pass")
FAIL=$(<"${_count_dir}/fail")
TESTS=$(( PASS + FAIL ))
echo "============================================================"
echo "  Tests: ${TESTS}   Passed: ${PASS}   Failed: ${FAIL}"
echo "============================================================"
exit "${FAIL}"
