#!/bin/bash
# Entrypoint: size the Apache prefork pool from the container memory limit (K1), then run apache2
# as the only process (H1/H2). SIGTERM from Kubernetes is translated into SIGWINCH, Apache's
# graceful stop, so in-flight requests finish before the pod disappears.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Pass-through for "docker run <image> bash" or ad-hoc commands
if (( $# > 0 )); then
    exec "$@"
fi

# ---- DOCUMENT_ROOT without trailing slash: 000-default.conf appends sub paths to it
if [[ "${DOCUMENT_ROOT:-}" != "/" ]]; then
    export DOCUMENT_ROOT="${DOCUMENT_ROOT%/}"
fi

# ---- container memory limit in MiB (cgroup v2, then v1); empty when unlimited or unknown
cgroup_limit_mib() {
    local raw=""
    if [[ -r /sys/fs/cgroup/memory.max ]]; then
        raw=$(< /sys/fs/cgroup/memory.max)
    elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        raw=$(< /sys/fs/cgroup/memory/memory.limit_in_bytes)
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw < (1 << 50) )); then
        echo $(( raw / 1024 / 1024 ))
    fi
}

if [[ -z "${APACHE_MAX_REQUEST_WORKERS:-}" ]]; then
    limit_mib=$(cgroup_limit_mib)
    if [[ -n "$limit_mib" ]]; then
        workers=$(( (limit_mib - APACHE_BASELINE_MEMORY_MB) / APACHE_CHILD_MEMORY_MB ))
        (( workers < 2 )) && workers=2
        log "memory limit ${limit_mib} MiB, baseline ${APACHE_BASELINE_MEMORY_MB} MiB, ${APACHE_CHILD_MEMORY_MB} MiB per child -> MaxRequestWorkers=${workers}"
    else
        workers=10
        log "no container memory limit found -> MaxRequestWorkers=${workers} (fallback)"
    fi
    export APACHE_MAX_REQUEST_WORKERS=$workers
else
    log "MaxRequestWorkers=${APACHE_MAX_REQUEST_WORKERS} (set explicitly)"
fi

# Spare-server settings must fit into the pool, otherwise Apache only warns and clamps
if (( APACHE_MIN_SPARE_SERVERS > APACHE_MAX_REQUEST_WORKERS )); then
    export APACHE_MIN_SPARE_SERVERS=$APACHE_MAX_REQUEST_WORKERS
fi
if (( APACHE_MAX_SPARE_SERVERS <= APACHE_MIN_SPARE_SERVERS )); then
    export APACHE_MAX_SPARE_SERVERS=$(( APACHE_MIN_SPARE_SERVERS + 1 ))
fi

# ---- runtime directories (emptyDir mounts start empty) and a stale pid file from a previous container
mkdir -p "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR"
rm -f "$APACHE_PID_FILE"

# ---- run Apache in the foreground; SIGTERM/SIGINT become a graceful stop (bounded by GracefulShutdownTimeout)
apache2 -DFOREGROUND &
apache_pid=$!
trap 'kill -WINCH "$apache_pid" 2>/dev/null' TERM INT

# "wait" returns >128 when interrupted by the trapped signal; keep waiting while Apache drains
while :; do
    rc=0
    wait "$apache_pid" || rc=$?
    if (( rc > 128 )) && kill -0 "$apache_pid" 2>/dev/null; then
        continue
    fi
    break
done
exit "$rc"
