#!/usr/bin/env bash
# install-server.sh — Server-grade extras on top of the base setup (Linux, apt, sudo)
#
#   1. Docker Engine + Compose + NVIDIA Container Toolkit (GPU in containers)
#   2. Unattended-upgrades policy (no auto reboot; kernel + NVIDIA updated manually, together)
#   3. Disk health monitoring (smartmontools / smartd)
#   4. Monitoring stack (Prometheus + Grafana + node-exporter + DCGM exporter, via Docker)
#   5. Sleep/suspend/hibernate disabled
#   6. GPU persistence fixes (delegates to gpu-persist-fix.sh)
#
# Usage:
#   ./scripts/install-server.sh                  # everything enabled in config
#   ./scripts/install-server.sh --dry-run        # show what would be done
#   ./scripts/install-server.sh --only docker    # one step: docker|updates|disk|monitoring|sleep|gpu-persist
#   ./scripts/install-server.sh --no-monitoring  # skip a step (--no-<step>)
#   ./scripts/install-server.sh --check          # status only, no changes, no sudo
#   ./scripts/install-server.sh --uninstall      # revert: monitoring stack, update policy, sleep mask, GPU persist
#                                                # (Docker + smartmontools stay; add --purge-docker to remove Docker)
#
# Idempotent: safe to re-run. Called from: setup.sh --server, or automatically when INSTALL_SERVER=true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

[ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

DO_DOCKER="${SERVER_DOCKER:-true}"
DO_UPDATES="${SERVER_UPDATE_POLICY:-true}"
DO_DISK="${SERVER_DISK_HEALTH:-true}"
DO_MONITORING="${SERVER_MONITORING:-true}"
DO_SLEEP="${SERVER_DISABLE_SLEEP:-true}"
DO_GPU_PERSIST="${SERVER_GPU_PERSIST:-true}"
HOLD_KERNEL_NVIDIA="${SERVER_HOLD_KERNEL_NVIDIA:-true}"
MONITORING_BIND="${MONITORING_BIND:-127.0.0.1}"
DRY_RUN=false
CHECK=false
UNINSTALL=false
PURGE_DOCKER=false

_only() {
    DO_DOCKER=false; DO_UPDATES=false; DO_DISK=false; DO_MONITORING=false; DO_SLEEP=false; DO_GPU_PERSIST=false
    case "$1" in
        docker)      DO_DOCKER=true ;;
        updates)     DO_UPDATES=true ;;
        disk)        DO_DISK=true ;;
        monitoring)  DO_MONITORING=true ;;
        sleep)       DO_SLEEP=true ;;
        gpu-persist) DO_GPU_PERSIST=true ;;
        *) echo "Unknown step: $1 (docker|updates|disk|monitoring|sleep|gpu-persist)"; exit 1 ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=true; shift ;;
        --check)          CHECK=true; shift ;;
        --uninstall)      UNINSTALL=true; shift ;;
        --purge-docker)   PURGE_DOCKER=true; shift ;;
        --only)           _only "$2"; shift 2 ;;
        --no-docker)      DO_DOCKER=false; shift ;;
        --no-updates)     DO_UPDATES=false; shift ;;
        --no-disk)        DO_DISK=false; shift ;;
        --no-monitoring)  DO_MONITORING=false; shift ;;
        --no-sleep)       DO_SLEEP=false; shift ;;
        --no-gpu-persist) DO_GPU_PERSIST=false; shift ;;
        --monitoring-bind) MONITORING_BIND="$2"; shift 2 ;;
        --help|-h)        sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

log_info()  { echo "  [INFO]  $1"; }
log_warn()  { echo "  [WARN]  $1"; }
log_ok()    { echo "  [OK]    $1"; }
log_error() { echo "  [ERROR] $1"; }
log_skip()  { echo "  [SKIP]  $1"; }

run_sudo() {
    if [ "$DRY_RUN" = true ]; then echo "  [DRY]   sudo $*"; return 0; fi
    sudo "$@"
}

# Write a root-owned file from stdin
write_root_file() {
    local path="$1"
    if [ "$DRY_RUN" = true ]; then echo "  [DRY]   write $path"; cat >/dev/null; return 0; fi
    sudo tee "$path" >/dev/null
}

HAS_NVIDIA=false
if [ "${GPU_BACKEND:-none}" = "cuda" ] || command -v nvidia-smi &>/dev/null; then HAS_NVIDIA=true; fi

SLEEP_TARGETS="sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"
UPDATES_CONF="/etc/apt/apt.conf.d/52machine-setting-unattended"
MON_DIR="$REPO_DIR/monitoring"

# ============================================================
# --check: status only
# ============================================================
if [ "$CHECK" = true ]; then
    echo "=== Server Setup Status ==="
    if command -v docker &>/dev/null; then
        log_ok "Docker: $(docker --version 2>/dev/null | sed 's/Docker version //; s/,.*//')"
        docker compose version &>/dev/null && log_ok "Docker Compose: $(docker compose version --short 2>/dev/null)" || log_warn "Docker Compose plugin missing"
        # Group membership from the account database; the current login session may predate it
        if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
            id -nG | tr ' ' '\n' | grep -qx docker && log_ok "User in docker group" \
                || log_ok "User in docker group (active after next login)"
        else
            log_warn "User not in docker group"
        fi
        if [ "$HAS_NVIDIA" = true ]; then
            command -v nvidia-ctk &>/dev/null && grep -qs '"nvidia"' /etc/docker/daemon.json \
                && log_ok "NVIDIA Container Toolkit configured for Docker" || log_warn "NVIDIA Container Toolkit not configured"
        fi
    else
        log_warn "Docker: not installed"
    fi
    [ -f "$UPDATES_CONF" ] && log_ok "Update policy: $UPDATES_CONF present" || log_warn "Update policy: not configured"
    command -v smartctl &>/dev/null && systemctl is-active --quiet smartmontools 2>/dev/null \
        && log_ok "Disk health: smartd active" || log_warn "Disk health: smartd not active"
    # Probe the endpoints rather than `docker ps`, which needs docker-group rights in this session
    mon_bind=$(grep -s '^MONITORING_BIND=' "$MON_DIR/.env" | cut -d= -f2)
    mon_bind="${mon_bind:-127.0.0.1}"; [ "$mon_bind" = "0.0.0.0" ] && mon_bind="127.0.0.1"
    if curl -fs -m 3 "http://${mon_bind}:9090/-/healthy" >/dev/null && curl -fs -m 3 "http://${mon_bind}:3000/api/health" >/dev/null; then
        mon_up=$(curl -fs -m 3 "http://${mon_bind}:9090/api/v1/query?query=up" | grep -o '"job":"[a-z]*"[^]]*"1"\]' | grep -o '"job":"[a-z]*"' | cut -d'"' -f4 | paste -sd, - || true)
        log_ok "Monitoring: Prometheus + Grafana healthy (targets up: ${mon_up:-none})"
    else
        log_warn "Monitoring: stack not running"
    fi
    [ "$(systemctl is-enabled suspend.target 2>/dev/null || true)" = "masked" ] \
        && log_ok "Sleep: suspend/hibernate masked" || log_warn "Sleep: suspend not masked"
    exit 0
fi

# ============================================================
# Validation
# ============================================================
if [ "$(uname -s)" != "Linux" ] || ! command -v apt-get &>/dev/null; then
    echo "  [SKIP] Server setup supports Ubuntu/Debian only"
    exit 0
fi
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    echo "  [SKIP] Server setup is for hosts, not containers"
    exit 0
fi

# ============================================================
# --uninstall: revert what this script configured
# ============================================================
if [ "$UNINSTALL" = true ]; then
    echo "=== Server Setup — Revert ==="
    [ "$DRY_RUN" = false ] && { sudo -v || exit 1; }
    if command -v docker &>/dev/null && [ -f "$MON_DIR/.env" ]; then
        run_sudo docker compose -p machine-monitoring --env-file "$MON_DIR/.env" -f "$MON_DIR/docker-compose.yml" --profile gpu down
        log_ok "Monitoring stack stopped (metric volumes kept; delete with: sudo docker volume rm machine-monitoring_prometheus-data machine-monitoring_grafana-data)"
    fi
    if [ -f "$UPDATES_CONF" ]; then
        run_sudo rm -f "$UPDATES_CONF"
        log_ok "Update policy removed (Ubuntu defaults restored)"
    fi
    # shellcheck disable=SC2086
    run_sudo systemctl unmask $SLEEP_TARGETS 2>/dev/null && log_ok "Sleep targets unmasked"
    if [ "$HAS_NVIDIA" = true ] && [ "$DRY_RUN" = false ]; then
        sudo bash "$SCRIPT_DIR/gpu-persist-fix.sh" --revert || log_warn "gpu-persist-fix.sh --revert reported a problem"
    fi
    if [ "$PURGE_DOCKER" = true ]; then
        log_warn "Removing Docker Engine and ALL images, containers and volumes"
        run_sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
        run_sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
        log_ok "Docker removed"
    else
        log_info "Docker and smartmontools were left installed (remove Docker with: --uninstall --purge-docker)"
    fi
    exit 0
fi

echo "=== Server Setup ==="
if [ "$DRY_RUN" = false ]; then
    log_info "sudo is required for system packages and services"
    sudo -v || { log_error "sudo authentication failed"; exit 1; }
fi

. /etc/os-release
DISTRO_ID="${ID:-ubuntu}"
DISTRO_CODENAME="${VERSION_CODENAME:-}"

# ============================================================
# 1. Docker Engine + Compose + NVIDIA Container Toolkit
# ============================================================
install_docker() {
    echo ""
    echo "── Docker ──"
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_ok "Docker already installed ($(docker --version | sed 's/Docker version //; s/,.*//'))"
    else
        local base="https://download.docker.com/linux/${DISTRO_ID}"
        if ! curl -fsSL --max-time 15 -o /dev/null "${base}/dists/${DISTRO_CODENAME}/Release"; then
            log_error "Docker has no apt repo for ${DISTRO_ID} ${DISTRO_CODENAME} (${base})"
            return 1
        fi
        log_info "Adding Docker apt repository (${DISTRO_ID} ${DISTRO_CODENAME})..."
        run_sudo install -m 0755 -d /etc/apt/keyrings
        if [ "$DRY_RUN" = false ]; then
            curl -fsSL "${base}/gpg" | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
            sudo chmod a+r /etc/apt/keyrings/docker.asc
        fi
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${base} ${DISTRO_CODENAME} stable" \
            | write_root_file /etc/apt/sources.list.d/docker.list
        run_sudo apt-get update -qq
        log_info "Installing Docker Engine + Compose..."
        run_sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        run_sudo systemctl enable --now docker
        log_ok "Docker installed"
    fi

    # docker group (takes effect at next login)
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        run_sudo usermod -aG docker "$USER"
        log_ok "Added $USER to the docker group (log out and back in to use docker without sudo)"
    fi

    # Log rotation: the default json-file driver grows without bound on a long-running server
    if [ ! -f /etc/docker/daemon.json ]; then
        printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "50m", "max-file": "3" }\n}\n' \
            | write_root_file /etc/docker/daemon.json
        log_ok "Docker log rotation configured (50m x 3)"
        local restart_docker=true
    fi

    # NVIDIA Container Toolkit
    if [ "$HAS_NVIDIA" = true ]; then
        if ! command -v nvidia-ctk &>/dev/null; then
            log_info "Installing NVIDIA Container Toolkit..."
            # The CUDA repo added by install-nvidia.sh already ships it; otherwise add NVIDIA's own repo
            if ! apt-cache show nvidia-container-toolkit &>/dev/null; then
                local gpg="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
                if [ "$DRY_RUN" = false ]; then
                    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o "$gpg"
                    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                        | sed "s#deb https://#deb [signed-by=$gpg] https://#g" \
                        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
                fi
                run_sudo apt-get update -qq
            fi
            run_sudo apt-get install -y nvidia-container-toolkit
        fi
        if ! grep -qs '"nvidia"' /etc/docker/daemon.json; then
            run_sudo nvidia-ctk runtime configure --runtime=docker
            local restart_docker=true
        fi
        log_ok "NVIDIA Container Toolkit configured"
    fi

    if [ "${restart_docker:-false}" = true ]; then
        run_sudo systemctl restart docker
    fi

    # Smoke test: GPU visible inside a container
    if [ "$HAS_NVIDIA" = true ] && [ "$DRY_RUN" = false ]; then
        if nvidia-smi &>/dev/null; then
            local out
            if out=$(sudo docker run --rm --gpus all ubuntu:24.04 nvidia-smi --query-gpu=name --format=csv,noheader 2>&1); then
                log_ok "GPU in container: $(echo "$out" | tail -1)"
            else
                log_warn "GPU container test failed: $(echo "$out" | tail -1)"
            fi
        else
            log_warn "nvidia-smi not working yet (reboot pending?) — skipping GPU container test"
        fi
    fi
}

# ============================================================
# 2. Unattended-upgrades policy
# ============================================================
configure_updates() {
    echo ""
    echo "── Automatic update policy ──"
    run_sudo apt-get install -y unattended-upgrades >/dev/null
    {
        echo "// Managed by machine-setting (scripts/install-server.sh). Remove this file to revert."
        echo "// Security updates keep installing automatically; the machine never reboots on its own"
        echo "// (a reboot would kill long-running training jobs)."
        echo 'Unattended-Upgrade::Automatic-Reboot "false";'
        if [ "$HOLD_KERNEL_NVIDIA" = true ]; then
            echo ""
            echo "// Kernel and NVIDIA packages are excluded from *automatic* upgrades. Upgrading the NVIDIA"
            echo "// userspace under a loaded kernel module breaks CUDA (\"Driver/library version mismatch\")"
            echo "// until the next reboot, and the prebuilt linux-modules-nvidia packages are tied to an exact"
            echo "// kernel + driver pair — so update them together, on your schedule:"
            echo "//     sudo apt update && sudo apt full-upgrade && sudo reboot"
            echo "Unattended-Upgrade::Package-Blacklist {"
            echo '    "linux-image";'
            echo '    "linux-headers";'
            echo '    "linux-modules";'
            echo '    "linux-generic";'
            echo '    "linux-tools";'
            echo '    "nvidia-";'
            echo '    "libnvidia-";'
            echo '    "xserver-xorg-video-nvidia";'
            echo "};"
        fi
    } | write_root_file "$UPDATES_CONF"
    log_ok "Auto reboot disabled$([ "$HOLD_KERNEL_NVIDIA" = true ] && echo '; kernel + NVIDIA held for manual upgrade')"
    [ "$HOLD_KERNEL_NVIDIA" = true ] && log_info "Update kernel/driver manually: sudo apt update && sudo apt full-upgrade && sudo reboot"
    return 0
}

# ============================================================
# 3. Disk health (SMART)
# ============================================================
configure_disk_health() {
    echo ""
    echo "── Disk health ──"
    if ! command -v smartctl &>/dev/null; then
        run_sudo apt-get install -y smartmontools nvme-cli
    fi
    run_sudo systemctl enable --now smartmontools 2>/dev/null || run_sudo systemctl enable --now smartd 2>/dev/null || true
    log_ok "smartd enabled (background SMART monitoring of all disks)"

    [ "$DRY_RUN" = true ] && return 0
    local d health
    for d in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
        health=$(sudo smartctl -H "/dev/$d" 2>/dev/null | grep -iE 'overall-health|SMART Health Status' | sed 's/.*: *//' || true)
        case "$health" in
            *PASSED*|*OK*) log_ok "/dev/$d: SMART ${health}" ;;
            "")            log_skip "/dev/$d: no SMART data" ;;
            *)             log_warn "/dev/$d: SMART ${health} — run: sudo ./scripts/disk-check-smart.sh" ;;
        esac
    done
}

# ============================================================
# 4. Monitoring stack (Docker Compose)
# ============================================================
install_monitoring() {
    echo ""
    echo "── Monitoring (Prometheus + Grafana) ──"
    if ! command -v docker &>/dev/null; then
        log_warn "Docker not installed — skipping monitoring stack (run with docker enabled first)"
        return 0
    fi
    [ "$DRY_RUN" = true ] && { echo "  [DRY]   docker compose -f $MON_DIR/docker-compose.yml up -d"; return 0; }

    # Secrets / bind address live in monitoring/.env (gitignored)
    local env_file="$MON_DIR/.env"
    if [ ! -f "$env_file" ]; then
        umask 077
        {
            echo "MONITORING_BIND=${MONITORING_BIND}"
            echo "GRAFANA_ADMIN_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
        } > "$env_file"
        umask 022
        log_ok "Created $env_file (Grafana admin password inside)"
    fi

    # Community dashboards (not vendored): NVIDIA DCGM (12239), Node Exporter Full (1860)
    local dash_dir="$MON_DIR/grafana/dashboards" id
    mkdir -p "$dash_dir"
    for id in 12239 1860; do
        if [ ! -s "$dash_dir/$id.json" ]; then
            if curl -fsSL --max-time 30 -o "$dash_dir/$id.json.tmp" "https://grafana.com/api/dashboards/$id/revisions/latest/download"; then
                # File provisioning has no import dialog: bind the datasource placeholder to our datasource uid
                sed 's/\${DS_PROMETHEUS}/prometheus/g' "$dash_dir/$id.json.tmp" > "$dash_dir/$id.json"
            else
                log_warn "Could not download Grafana dashboard $id (import it later from grafana.com)"
            fi
            rm -f "$dash_dir/$id.json.tmp"
        fi
    done

    local profiles=()
    [ "$HAS_NVIDIA" = true ] && nvidia-smi &>/dev/null && profiles=(--profile gpu)

    sudo docker compose -p machine-monitoring --env-file "$env_file" -f "$MON_DIR/docker-compose.yml" "${profiles[@]}" up -d --remove-orphans
    local bind
    bind=$(grep '^MONITORING_BIND=' "$env_file" | cut -d= -f2)
    log_ok "Monitoring stack running"
    log_info "Grafana:    http://${bind}:3000  (user: admin, password: in $env_file)"
    log_info "Prometheus: http://${bind}:9090"
    if [ "$bind" = "127.0.0.1" ]; then
        log_info "Bound to localhost. From another machine: ssh -L 3000:localhost:3000 $USER@<this-host>"
    fi
}

# ============================================================
# 5. Disable sleep / suspend / hibernate
# ============================================================
disable_sleep() {
    echo ""
    echo "── Sleep / suspend ──"
    # shellcheck disable=SC2086
    if [ "$(systemctl is-enabled suspend.target 2>/dev/null || true)" = "masked" ] \
        && [ "$(systemctl is-enabled hibernate.target 2>/dev/null || true)" = "masked" ]; then
        log_ok "Sleep targets already masked"
    else
        run_sudo systemctl mask $SLEEP_TARGETS
        log_ok "Sleep, suspend and hibernate disabled (revert: sudo systemctl unmask $SLEEP_TARGETS)"
    fi
}

# ============================================================
# 6. GPU persistence fixes
# ============================================================
apply_gpu_persist() {
    echo ""
    echo "── GPU persistence ──"
    if [ "$HAS_NVIDIA" != true ]; then
        log_skip "No NVIDIA GPU"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY]   sudo $SCRIPT_DIR/gpu-persist-fix.sh"
        return 0
    fi
    sudo bash "$SCRIPT_DIR/gpu-persist-fix.sh" || log_warn "gpu-persist-fix.sh reported a problem"
}

# ============================================================
# Base tools (always; GPU hosts also get these from install-nvidia.sh system tools)
# ============================================================
install_tools() {
    [ "${INSTALL_BASE_TOOLS:-true}" = true ] || return 0
    if [ "$DRY_RUN" = true ]; then bash "$SCRIPT_DIR/install-base-tools.sh" --dry-run; return 0; fi
    bash "$SCRIPT_DIR/install-base-tools.sh"
}

# ============================================================
# Main
# ============================================================
FAILED=()
install_tools || FAILED+=("tools")
[ "$DO_SLEEP" = true ]       && { disable_sleep         || FAILED+=("sleep"); }
[ "$DO_UPDATES" = true ]     && { configure_updates     || FAILED+=("updates"); }
[ "$DO_DISK" = true ]        && { configure_disk_health || FAILED+=("disk"); }
[ "$DO_GPU_PERSIST" = true ] && { apply_gpu_persist     || FAILED+=("gpu-persist"); }
[ "$DO_DOCKER" = true ]      && { install_docker        || FAILED+=("docker"); }
[ "$DO_MONITORING" = true ]  && { install_monitoring    || FAILED+=("monitoring"); }

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    log_error "Server setup finished with failures: ${FAILED[*]}"
    exit 1
fi
log_ok "Server setup complete (status: ./scripts/install-server.sh --check)"
