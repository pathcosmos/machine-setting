#!/usr/bin/env bash
# dry-run.sh — Comprehensive dry-run diagnostic for ALL installation stages
# Deep analysis: current state, compatibility, conflicts, risks, disk, versions
#
# Usage:
#   ./scripts/dry-run.sh                    # Full diagnostic (all 7 stages)
#   ./scripts/dry-run.sh --stage nvidia     # NVIDIA stage only (delegates to install-nvidia.sh --dry-run)
#   ./scripts/dry-run.sh --stage python     # Python stage only
#   ./scripts/dry-run.sh --stage venv       # Venv + packages only
#   ./scripts/dry-run.sh --stage node       # Node.js only
#   ./scripts/dry-run.sh --stage java       # Java only
#   ./scripts/dry-run.sh --stage shell      # Shell integration only
#   ./scripts/dry-run.sh --json             # JSON output for scripting
#   ./scripts/dry-run.sh --profile <name>   # Force profile
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="$REPO_DIR/packages"

# --- Load config ---
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

# ============================================================
# Parse arguments
# ============================================================
STAGE_FILTER=""          # empty = all stages
JSON_OUTPUT=false
FORCE_PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage)       STAGE_FILTER="$2"; shift 2 ;;
        --json)        JSON_OUTPUT=true; shift ;;
        --profile)     FORCE_PROFILE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./scripts/dry-run.sh [options]"
            echo ""
            echo "  (no args)          Full diagnostic (all 7 stages)"
            echo "  --stage <name>     Single stage: hardware|nvidia|python|venv|node|java|shell"
            echo "  --json             JSON output for scripting"
            echo "  --profile <name>   Force specific profile"
            echo ""
            echo "Exit codes:"
            echo "  0  No blocking issues"
            echo "  1  Blocking issues found"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================================
# Color & Output Helpers
# ============================================================
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_RED="\033[0;31m"
C_CYAN="\033[0;36m"
C_MAGENTA="\033[0;35m"

tag_ok()       { printf "  ${C_GREEN}[OK]${C_RESET}       %s\n" "$1"; }
tag_install()  { printf "  ${C_CYAN}[INSTALL]${C_RESET}  %s\n" "$1"; }
tag_upgrade()  { printf "  ${C_CYAN}[UPGRADE]${C_RESET}  %s\n" "$1"; }
tag_skip()     { printf "  ${C_DIM}[SKIP]${C_RESET}     %s\n" "$1"; }
tag_warn()     { printf "  ${C_YELLOW}[WARN]${C_RESET}     %s\n" "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
tag_fail()     { printf "  ${C_RED}[FAIL]${C_RESET}     %s\n" "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
tag_conflict() { printf "  ${C_RED}[CONFLICT]${C_RESET} %s\n" "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
tag_info()     { printf "  ${C_DIM}[INFO]${C_RESET}     %s\n" "$1"; }
section()      { printf "\n${C_BOLD}── %s ──${C_RESET}\n" "$1"; }
subsection()   { printf "\n  ${C_MAGENTA}▸ %s${C_RESET}\n" "$1"; }

# Counters
OK_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0; INSTALL_COUNT=0

# ============================================================
# System Detection
# ============================================================
detect_system_info() {
    OS_TYPE="$(uname -s)"
    ARCH="$(uname -m)"
    OS_NAME="unknown"
    RAM_GB="?"
    CPU_MODEL="unknown"
    CPU_CORES="?"
    DISK_FREE_GB="?"
    DISK_FREE_VENV_GB="?"

    case "$OS_TYPE" in
        Linux)
            OS_NAME=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")
            OS_ID=$(. /etc/os-release 2>/dev/null && echo "${ID:-linux}")
            OS_VER=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-0}")
            RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "?")
            CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "unknown")
            CPU_CORES=$(nproc 2>/dev/null || echo "?")
            ;;
        Darwin)
            OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
            OS_ID="darwin"
            OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "0")
            local ram_bytes; ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
            RAM_GB=$(( ram_bytes / 1073741824 ))
            CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
            CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "?")
            ;;
    esac

    DISK_FREE_GB=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1048576}')
    local venv_parent; venv_parent=$(dirname "${VENV_DEFAULT_PATH:-$HOME/ai-env}")
    DISK_FREE_VENV_GB=$(df -k "$venv_parent" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1048576}')

    # GPU detection
    HAS_GPU=false; GPU_NAME=""; GPU_BACKEND="none"; CUDA_VERSION=""; CUDA_SUFFIX="cpu"; GPU_COUNT=0

    case "$OS_TYPE" in
        Linux)
            local gpu_info=""
            command -v lspci &>/dev/null && gpu_info=$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' | grep -i nvidia || true)
            if [ -n "$gpu_info" ]; then
                HAS_GPU=true; GPU_BACKEND="cuda"
                GPU_COUNT=$(echo "$gpu_info" | wc -l | tr -d ' ')
                if command -v nvidia-smi &>/dev/null; then
                    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
                    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
                else
                    GPU_NAME=$(echo "$gpu_info" | head -1 | sed 's/.*: //')
                fi
                if command -v nvcc &>/dev/null; then
                    CUDA_VERSION=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
                elif command -v nvidia-smi &>/dev/null; then
                    CUDA_VERSION=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9]*\.[0-9]*\).*/\1/p' || true)
                fi
                [ -n "$CUDA_VERSION" ] && CUDA_SUFFIX="cu$(echo "$CUDA_VERSION" | tr -d '.')"
            fi
            ;;
        Darwin)
            if [[ "$ARCH" == "arm64" ]]; then
                HAS_GPU=true; GPU_BACKEND="mps"; CUDA_SUFFIX="mps"
                GPU_NAME=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model" | sed 's/.*: //' | head -1 || echo "Apple Silicon")
            fi
            ;;
    esac

    # Profile selection
    if [ -n "$FORCE_PROFILE" ]; then
        PROFILE="$FORCE_PROFILE"
    elif [ "$GPU_BACKEND" = "mps" ]; then
        PROFILE="mac-apple-silicon"
    elif [ "$GPU_BACKEND" = "cuda" ]; then
        PROFILE="gpu-workstation"
    elif [ "$RAM_GB" != "?" ] && [ "$RAM_GB" -ge 32 ] 2>/dev/null; then
        PROFILE="cpu-server"
    elif [ "$RAM_GB" != "?" ] && [ "$RAM_GB" -ge 8 ] 2>/dev/null; then
        PROFILE="laptop"
    else
        PROFILE="minimal"
    fi

    local profile_file="$REPO_DIR/profiles/${PROFILE}.conf"
    [ -f "$profile_file" ] && source "$profile_file"
}

# ============================================================
# Stage 1: Hardware Profile Diagnostic
# ============================================================
diag_hardware() {
    section "Stage 1/7: Hardware Detection"

    # System info
    tag_info "OS: $OS_NAME ($OS_TYPE $ARCH)"
    tag_info "CPU: $CPU_MODEL ($CPU_CORES cores)"
    tag_info "RAM: ${RAM_GB}GB"
    tag_info "Disk free (home): ${DISK_FREE_GB}GB"

    # GPU
    if [ "$HAS_GPU" = true ]; then
        tag_ok "GPU: $GPU_NAME (${GPU_BACKEND}, ${GPU_COUNT} GPU(s))"
        [ -n "$CUDA_VERSION" ] && tag_ok "CUDA: $CUDA_VERSION ($CUDA_SUFFIX)"
    else
        tag_info "GPU: None detected (CPU only)"
    fi

    # Profile
    tag_info "Auto-selected profile: $PROFILE"
    if [ -f "$REPO_DIR/profiles/${PROFILE}.conf" ]; then
        tag_ok "Profile file exists: profiles/${PROFILE}.conf"
    else
        tag_fail "Profile file missing: profiles/${PROFILE}.conf"
    fi

    # Hardware profile file
    local hw_profile="$HOME/.machine_setting_profile"
    if [ -f "$hw_profile" ]; then
        local gen_date
        gen_date=$(grep "^# Auto-generated" "$hw_profile" 2>/dev/null | sed 's/.*on //' || echo "unknown")
        tag_ok "Hardware profile exists (generated: $gen_date)"

        # Check if stale (older than 30 days)
        local profile_age_days
        profile_age_days=$(( ($(date +%s) - $(stat -c %Y "$hw_profile" 2>/dev/null || echo 0)) / 86400 ))
        if [ "$profile_age_days" -gt 30 ]; then
            tag_warn "Hardware profile is ${profile_age_days} days old — consider regenerating"
        fi
    else
        tag_install "Hardware profile will be generated"
        INSTALL_COUNT=$((INSTALL_COUNT + 1))
    fi

    # Disk space check
    if [ "$DISK_FREE_GB" != "?" ] && [ "$DISK_FREE_GB" -lt 5 ]; then
        tag_fail "CRITICAL: Only ${DISK_FREE_GB}GB free disk space (need ≥15GB for full install)"
    elif [ "$DISK_FREE_GB" != "?" ] && [ "$DISK_FREE_GB" -lt 15 ]; then
        tag_warn "Low disk space: ${DISK_FREE_GB}GB free (15GB+ recommended for full install)"
    else
        tag_ok "Disk space: ${DISK_FREE_GB}GB free"
        OK_COUNT=$((OK_COUNT + 1))
    fi
}

# ============================================================
# Stage 2: NVIDIA GPU Stack Diagnostic
# ============================================================
diag_nvidia() {
    section "Stage 2/7: NVIDIA GPU Stack"

    # Skip conditions
    if [ "$OS_TYPE" != "Linux" ]; then
        tag_skip "Not Linux — NVIDIA stage skipped"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi
    if [ "$GPU_BACKEND" != "cuda" ]; then
        tag_skip "No NVIDIA GPU detected — stage skipped"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi
    if [ "${INSTALL_NVIDIA:-true}" = "false" ]; then
        tag_skip "INSTALL_NVIDIA=false — stage disabled"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    # Delegate detailed NVIDIA diagnostics
    if [ -x "$SCRIPT_DIR/install-nvidia.sh" ]; then
        tag_info "Running detailed NVIDIA diagnostic..."
        echo ""
        # Run NVIDIA dry-run (it has its own comprehensive diagnostic)
        bash "$SCRIPT_DIR/install-nvidia.sh" --dry-run 2>&1 | sed 's/^/    /'
        echo ""
        tag_info "End of NVIDIA diagnostic"
    else
        tag_fail "install-nvidia.sh not found — cannot perform NVIDIA diagnostic"
    fi

    # Additional cross-stage checks
    subsection "NVIDIA ↔ Python Package Compatibility"

    if [ -n "$CUDA_VERSION" ]; then
        # Check if CUDA suffix is in gpu-index-urls.conf
        local url_conf="$REPO_DIR/config/gpu-index-urls.conf"
        if [ -f "$url_conf" ]; then
            if grep -q "^${CUDA_SUFFIX}=" "$url_conf"; then
                tag_ok "PyTorch index URL available for $CUDA_SUFFIX"
                OK_COUNT=$((OK_COUNT + 1))
            else
                local available_suffixes
                available_suffixes=$(grep -oP '^cu\d+' "$url_conf" | tr '\n' ', ' | sed 's/,$//')
                tag_warn "No exact match for $CUDA_SUFFIX in gpu-index-urls.conf"
                tag_info "Available: $available_suffixes (will fallback to nearest lower)"
            fi
        fi
    fi
}

# ============================================================
# Stage 3: Python Diagnostic
# ============================================================
diag_python() {
    section "Stage 3/7: Python Setup"

    local target_ver="${PYTHON_VERSION:-3.12}"

    # uv check
    subsection "uv Package Manager"
    if command -v uv &>/dev/null; then
        local uv_ver; uv_ver=$(uv --version 2>/dev/null | head -1 || echo "unknown")
        tag_ok "uv installed: $uv_ver"
        OK_COUNT=$((OK_COUNT + 1))

        # Check uv update available
        local uv_path; uv_path=$(which uv 2>/dev/null)
        tag_info "uv path: $uv_path"
    else
        tag_install "uv will be installed (curl -LsSf https://astral.sh/uv/install.sh)"
        INSTALL_COUNT=$((INSTALL_COUNT + 1))

        # Check curl availability
        if ! command -v curl &>/dev/null; then
            tag_fail "curl not found — required for uv installation"
        fi
    fi

    # Python check
    subsection "Python $target_ver"
    local python_bin="" actual_ver=""

    if command -v uv &>/dev/null; then
        python_bin=$(uv python find "$target_ver" 2>/dev/null || true)
        if [ -n "$python_bin" ] && [ -x "$python_bin" ]; then
            actual_ver=$("$python_bin" --version 2>/dev/null | sed 's/Python //')
        fi
    fi
    # Fallback to direct python check
    if [ -z "$actual_ver" ] && command -v "python${target_ver}" &>/dev/null; then
        actual_ver=$("python${target_ver}" --version 2>/dev/null | sed 's/Python //')
        python_bin=$(which "python${target_ver}" 2>/dev/null)
    fi

    if [ -n "$actual_ver" ]; then
        tag_ok "Python $actual_ver found at: $python_bin"
        OK_COUNT=$((OK_COUNT + 1))

        # Check for multiple Python versions
        local other_pythons
        other_pythons=$(compgen -c python3. 2>/dev/null | sort -u | head -5 || true)
        if [ -n "$other_pythons" ]; then
            tag_info "Other Python versions: $(echo "$other_pythons" | tr '\n' ' ')"
        fi
    else
        tag_install "Python $target_ver will be installed via uv"
        INSTALL_COUNT=$((INSTALL_COUNT + 1))
    fi

    # System Python conflict check
    subsection "System Python Conflict Check"
    if command -v python3 &>/dev/null; then
        local sys_python_ver
        sys_python_ver=$(python3 --version 2>/dev/null | sed 's/Python //')
        local sys_python_path
        sys_python_path=$(which python3 2>/dev/null)
        tag_info "System Python: $sys_python_ver at $sys_python_path"

        if [[ "$sys_python_path" == /usr/* ]]; then
            tag_ok "uv Python is separate from system Python — no conflict"
            OK_COUNT=$((OK_COUNT + 1))
        fi
    fi

    # PEP 668 check (externally-managed-environment)
    if [ -f "/usr/lib/python3/EXTERNALLY-MANAGED" ] || [ -f "/usr/lib/python${target_ver}/EXTERNALLY-MANAGED" ]; then
        tag_info "PEP 668 detected (externally-managed) — uv bypasses this correctly"
    fi
}

# ============================================================
# Stage 4: AI Environment (venv + packages) Diagnostic
# ============================================================
diag_venv() {
    section "Stage 4/7: AI Environment (venv + packages)"

    local venv_path="${VENV_DEFAULT_PATH:-$HOME/ai-env}"

    subsection "Virtual Environment: $venv_path"

    if [ -d "$venv_path" ]; then
        if [ -x "$venv_path/bin/python" ]; then
            local venv_python_ver
            venv_python_ver=$("$venv_path/bin/python" --version 2>/dev/null | sed 's/Python //')
            tag_ok "venv exists with Python $venv_python_ver"
            OK_COUNT=$((OK_COUNT + 1))

            # venv size
            local venv_size
            venv_size=$(du -sh "$venv_path" 2>/dev/null | cut -f1 | tr -d ' ')
            tag_info "venv size: $venv_size"

            # Check activation script
            if [ -f "$venv_path/bin/activate" ]; then
                tag_ok "Activation script exists"
                OK_COUNT=$((OK_COUNT + 1))
            else
                tag_fail "Missing bin/activate — venv may be corrupted"
            fi
        else
            tag_fail "venv directory exists but bin/python missing — BROKEN"
            tag_info "Recovery: rm -rf $venv_path && ./setup.sh --from 4"
        fi
    else
        tag_install "venv will be created at: $venv_path"
        INSTALL_COUNT=$((INSTALL_COUNT + 1))
    fi

    # Disk space for venv
    if [ "$DISK_FREE_VENV_GB" != "?" ]; then
        local needed=15
        [ "$GPU_BACKEND" = "none" ] && needed=8
        if [ "$DISK_FREE_VENV_GB" -lt "$needed" ]; then
            tag_warn "Only ${DISK_FREE_VENV_GB}GB free at venv location (need ~${needed}GB)"
        else
            tag_ok "Disk space at venv location: ${DISK_FREE_VENV_GB}GB free (need ~${needed}GB)"
            OK_COUNT=$((OK_COUNT + 1))
        fi
    fi

    # Package analysis
    subsection "Package Groups"

    local groups="${PACKAGE_GROUPS:-core}"
    tag_info "Configured groups: $groups"

    # Compute backend
    case "$GPU_BACKEND" in
        cuda)  tag_info "GPU packages: requirements-gpu.txt (CUDA $CUDA_SUFFIX)" ;;
        mps)   tag_info "GPU packages: requirements-mps.txt (Apple MPS)" ;;
        *)     tag_info "GPU packages: requirements-cpu.txt (CPU fallback)" ;;
    esac

    # Package file existence check
    local total_pkg_count=0
    for group in $groups; do
        local req_file="$PKG_DIR/requirements-${group}.txt"
        if [ -f "$req_file" ]; then
            local count; count=$(grep -v '^#' "$req_file" | grep -v '^$' | grep -v '^\-' | wc -l | tr -d ' ')
            total_pkg_count=$((total_pkg_count + count))
            tag_ok "requirements-${group}.txt: $count packages"
            OK_COUNT=$((OK_COUNT + 1))
        else
            tag_fail "requirements-${group}.txt NOT FOUND"
        fi
    done

    # GPU-specific requirements
    local gpu_req=""
    case "$GPU_BACKEND" in
        cuda) gpu_req="$PKG_DIR/requirements-gpu.txt" ;;
        mps)  gpu_req="$PKG_DIR/requirements-mps.txt" ;;
        *)    gpu_req="$PKG_DIR/requirements-cpu.txt" ;;
    esac
    if [ -n "$gpu_req" ] && [ -f "$gpu_req" ]; then
        local gpu_count; gpu_count=$(grep -v '^#' "$gpu_req" | grep -v '^$' | grep -v '^\-' | wc -l | tr -d ' ')
        total_pkg_count=$((total_pkg_count + gpu_count))
        tag_ok "$(basename "$gpu_req"): $gpu_count packages"
        OK_COUNT=$((OK_COUNT + 1))
    fi

    tag_info "Total packages to install: ~$total_pkg_count"

    # If venv exists, check installed vs required
    if [ -x "${venv_path}/bin/pip" ]; then
        subsection "Package Verification (installed vs required)"

        local installed_count
        installed_count=$("$venv_path/bin/pip" list 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
        tag_info "Currently installed: $installed_count packages"

        local installed_tmp required_tmp
        installed_tmp=$(mktemp); required_tmp=$(mktemp)

        "$venv_path/bin/pip" freeze 2>/dev/null | sed 's/==.*//; s/\+.*//' | awk '{print tolower($0)}' | sort -u > "$installed_tmp"

        for group in $groups; do
            local req_file="$PKG_DIR/requirements-${group}.txt"
            [ -f "$req_file" ] || continue
            grep -v '^#' "$req_file" | grep -v '^$' | grep -v '^\-' | \
                sed 's/[>=<!\[].*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' >> "$required_tmp"
        done
        if [ -n "$gpu_req" ] && [ -f "$gpu_req" ]; then
            grep -v '^#' "$gpu_req" | grep -v '^$' | grep -v '^\-' | \
                sed 's/[>=<!\[].*//; s/\+.*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' >> "$required_tmp"
        fi
        sort -u "$required_tmp" -o "$required_tmp"

        local missing_pkgs missing_count
        missing_pkgs=$(comm -23 "$required_tmp" "$installed_tmp" 2>/dev/null || true)
        missing_count=0
        [ -n "$missing_pkgs" ] && missing_count=$(echo "$missing_pkgs" | wc -l | tr -d ' ')

        if [ "$missing_count" -eq 0 ]; then
            tag_ok "All required packages installed"
            OK_COUNT=$((OK_COUNT + 1))
        else
            tag_warn "$missing_count packages missing"
            echo "$missing_pkgs" | head -10 | while read -r pkg; do
                tag_info "  missing: $pkg"
            done
            [ "$missing_count" -gt 10 ] && tag_info "  ... and $((missing_count - 10)) more"
        fi

        rm -f "$installed_tmp" "$required_tmp"

        # Key package import test
        subsection "Key Package Import Test"
        local key_packages=("torch" "transformers" "numpy")
        for pkg in "${key_packages[@]}"; do
            if "$venv_path/bin/python" -c "import $pkg; print(f'${pkg} {${pkg}.__version__}')" 2>/dev/null; then
                local pkg_ver; pkg_ver=$("$venv_path/bin/python" -c "import $pkg; print(${pkg}.__version__)" 2>/dev/null)
                tag_ok "$pkg $pkg_ver — importable"
                OK_COUNT=$((OK_COUNT + 1))
            else
                tag_warn "$pkg — import failed"
            fi
        done

        # torch GPU check
        if [ "$GPU_BACKEND" = "cuda" ]; then
            local torch_cuda
            torch_cuda=$("$venv_path/bin/python" -c "import torch; print(f'CUDA available: {torch.cuda.is_available()}, devices: {torch.cuda.device_count()}')" 2>/dev/null || echo "N/A")
            tag_info "torch: $torch_cuda"
        fi
    fi
}

# ============================================================
# Stage 5: Node.js Diagnostic
# ============================================================
diag_node() {
    section "Stage 5/7: Node.js"

    if [ "${INSTALL_NODE:-true}" = "false" ]; then
        tag_skip "INSTALL_NODE=false in profile"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"

    subsection "NVM (Node Version Manager)"
    if [ -d "$nvm_dir" ] && [ -s "$nvm_dir/nvm.sh" ]; then
        tag_ok "NVM installed at: $nvm_dir"
        OK_COUNT=$((OK_COUNT + 1))

        local nvm_size; nvm_size=$(du -sh "$nvm_dir" 2>/dev/null | cut -f1 | tr -d ' ')
        tag_info "NVM directory size: $nvm_size"

        # Load NVM
        source "$nvm_dir/nvm.sh" 2>/dev/null || true

        subsection "Node.js"
        if command -v node &>/dev/null; then
            local node_ver; node_ver=$(node --version 2>/dev/null || echo "unknown")
            local npm_ver; npm_ver=$(npm --version 2>/dev/null || echo "unknown")
            tag_ok "Node.js: $node_ver"
            tag_ok "npm: $npm_ver"
            OK_COUNT=$((OK_COUNT + 2))

            # Check if LTS
            local current_lts
            current_lts=$(nvm ls-remote --lts 2>/dev/null | tail -1 | grep -oP 'v[\d.]+' || echo "unknown")
            if [ "$current_lts" != "unknown" ] && [ "$node_ver" != "$current_lts" ]; then
                tag_info "Latest LTS: $current_lts (current: $node_ver)"
            fi

            # Global packages
            local global_count
            global_count=$(npm ls -g --depth=0 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
            tag_info "Global npm packages: $global_count"
        else
            tag_install "Node.js will be installed via NVM"
            INSTALL_COUNT=$((INSTALL_COUNT + 1))
        fi

        # Multiple Node versions
        local installed_versions
        installed_versions=$(nvm ls 2>/dev/null | grep -oP 'v[\d.]+' | sort -V || true)
        local ver_count; ver_count=$(echo "$installed_versions" | grep -c . 2>/dev/null || echo 0)
        if [ "$ver_count" -gt 1 ]; then
            tag_info "Multiple Node versions installed ($ver_count):"
            echo "$installed_versions" | while read -r v; do
                tag_info "  $v"
            done
        fi
    else
        tag_install "NVM + Node.js will be installed"
        INSTALL_COUNT=$((INSTALL_COUNT + 1))

        # curl check
        if ! command -v curl &>/dev/null; then
            tag_fail "curl not found — required for NVM installation"
        else
            tag_ok "curl available for NVM installation"
            OK_COUNT=$((OK_COUNT + 1))
        fi
    fi

    # Shell integration check (lazy loader)
    subsection "Shell Integration (Lazy Loader)"
    local lazy_loader="$REPO_DIR/shell/bashrc.d/30-nvm.sh"
    if [ -f "$lazy_loader" ]; then
        tag_ok "NVM lazy loader script exists"
        OK_COUNT=$((OK_COUNT + 1))
    else
        tag_warn "NVM lazy loader script missing: shell/bashrc.d/30-nvm.sh"
    fi
}

# ============================================================
# Stage 6: Java Diagnostic
# ============================================================
diag_java() {
    section "Stage 6/7: Java"

    if [ "${INSTALL_JAVA:-true}" = "false" ]; then
        tag_skip "INSTALL_JAVA=false in profile"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    local sdk_dir="${SDKMAN_DIR:-$HOME/.sdkman}"
    local target_ver="${JAVA_VERSION:-21}"

    subsection "SDKMAN"
    if [ -d "$sdk_dir" ] && [ -s "$sdk_dir/bin/sdkman-init.sh" ]; then
        tag_ok "SDKMAN installed at: $sdk_dir"
        OK_COUNT=$((OK_COUNT + 1))

        local sdk_size; sdk_size=$(du -sh "$sdk_dir" 2>/dev/null | cut -f1 | tr -d ' ')
        tag_info "SDKMAN directory size: $sdk_size"

        # Load SDKMAN
        set +u
        source "$sdk_dir/bin/sdkman-init.sh" 2>/dev/null || true
        set -u

        subsection "Java $target_ver"
        if command -v java &>/dev/null; then
            local java_ver
            java_ver=$(java -version 2>&1 | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
            tag_ok "Java: $java_ver"
            OK_COUNT=$((OK_COUNT + 1))

            local java_home_path
            java_home_path=$(java -XshowSettings:property 2>&1 | grep 'java.home' | sed 's/.*= //' || echo "unknown")
            tag_info "JAVA_HOME: $java_home_path"

            # Check if correct major version
            local java_major; java_major=$(echo "$java_ver" | cut -d. -f1)
            if [ "$java_major" != "$target_ver" ]; then
                tag_warn "Installed Java $java_major but target is $target_ver"
            fi
        else
            tag_install "Java $target_ver will be installed via SDKMAN"
            INSTALL_COUNT=$((INSTALL_COUNT + 1))
        fi

        # Multiple Java versions
        local java_candidates
        java_candidates=$(find "$sdk_dir/candidates/java" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        if [ "$java_candidates" -gt 1 ]; then
            tag_info "Multiple Java versions installed: $java_candidates"
        fi
    else
        tag_install "SDKMAN + Java $target_ver will be installed"
        INSTALL_COUNT=$((INSTALL_COUNT + 1))

        if ! command -v curl &>/dev/null; then
            tag_fail "curl not found — required for SDKMAN installation"
        else
            tag_ok "curl available for SDKMAN installation"
            OK_COUNT=$((OK_COUNT + 1))
        fi
    fi

    # Lazy loader check
    subsection "Shell Integration (Lazy Loader)"
    local lazy_loader="$REPO_DIR/shell/bashrc.d/40-sdkman.sh"
    if [ -f "$lazy_loader" ]; then
        tag_ok "SDKMAN lazy loader script exists"
        OK_COUNT=$((OK_COUNT + 1))
    else
        tag_warn "SDKMAN lazy loader script missing: shell/bashrc.d/40-sdkman.sh"
    fi
}

# ============================================================
# Stage 7: Shell Integration Diagnostic
# ============================================================
diag_shell() {
    section "Stage 7/7: Shell Integration"

    local marker="# >>> machine_setting >>>"
    local marker_end="# <<< machine_setting <<<"

    subsection "Shell RC Files"
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        local rc_name; rc_name=$(basename "$rc_file")
        if [ -f "$rc_file" ]; then
            if grep -qF "$marker" "$rc_file" 2>/dev/null; then
                # Count lines in block
                local block_lines
                block_lines=$(awk "/$marker/{start=1} start{lines++} /$marker_end/{start=0}" "$rc_file" && echo "$lines" || echo "?")
                tag_ok "$rc_name: machine_setting block present"
                OK_COUNT=$((OK_COUNT + 1))

                # Check for duplicate blocks
                local block_count
                block_count=$(grep -cF "$marker" "$rc_file" 2>/dev/null || echo 0)
                if [ "$block_count" -gt 1 ]; then
                    tag_warn "$rc_name: $block_count duplicate machine_setting blocks found!"
                    tag_info "  Fix: remove duplicates, keep only one block"
                fi
            else
                tag_install "$rc_name: machine_setting block will be added"
                INSTALL_COUNT=$((INSTALL_COUNT + 1))
            fi
        else
            local shell_name="${rc_file##*.}"
            if command -v "$shell_name" &>/dev/null || [ "$SHELL" = "/bin/$shell_name" ] || [ "$SHELL" = "/usr/bin/$shell_name" ]; then
                tag_info "$rc_name: file doesn't exist (will be created)"
            else
                tag_skip "$rc_name: shell not available"
                SKIP_COUNT=$((SKIP_COUNT + 1))
            fi
        fi
    done

    # Shell modules
    subsection "Shell Modules"
    local module_dir="$REPO_DIR/shell/bashrc.d"
    local expected_modules=("00-path.sh" "10-aliases.sh" "20-env.sh" "30-nvm.sh" "40-sdkman.sh" "50-ai-env.sh")
    for mod in "${expected_modules[@]}"; do
        if [ -f "$module_dir/$mod" ]; then
            tag_ok "$mod"
            OK_COUNT=$((OK_COUNT + 1))
        else
            tag_fail "Missing: $mod"
        fi
    done

    # Secrets files
    subsection "Secrets Files"
    if [ -f "$HOME/.bashrc.local" ]; then
        tag_ok "~/.bashrc.local exists"
        OK_COUNT=$((OK_COUNT + 1))

        # Check if empty or just template
        local line_count; line_count=$(grep -v '^#' "$HOME/.bashrc.local" | grep -v '^$' | wc -l | tr -d ' ')
        if [ "$line_count" -eq 0 ]; then
            tag_info "  (template only, no active exports)"
        else
            tag_info "  ($line_count active export lines)"
        fi
    else
        tag_info "~/.bashrc.local will be created (template)"
    fi
    if [ -f "$HOME/.zshrc.local" ]; then
        if [ -L "$HOME/.zshrc.local" ]; then
            tag_ok "~/.zshrc.local exists (symlink to .bashrc.local)"
            OK_COUNT=$((OK_COUNT + 1))
        else
            tag_ok "~/.zshrc.local exists (standalone)"
            OK_COUNT=$((OK_COUNT + 1))
        fi
    fi
}

# ============================================================
# Cross-Stage Compatibility & Conflict Checks
# ============================================================
diag_cross_stage() {
    section "Cross-Stage Compatibility & Conflicts"

    subsection "Checkpoint System"
    local state_dir="$HOME/.machine_setting"
    local state_file="$state_dir/install.state"
    if [ -f "$state_file" ]; then
        tag_ok "Checkpoint state file exists"
        OK_COUNT=$((OK_COUNT + 1))

        # Check for incomplete stages
        local failed_stages
        failed_stages=$(grep '=failed' "$state_file" 2>/dev/null || true)
        if [ -n "$failed_stages" ]; then
            tag_warn "Failed stages detected in checkpoint:"
            echo "$failed_stages" | while read -r line; do
                tag_info "  $line"
            done
            tag_info "  Use: ./setup.sh --resume to continue"
        fi

        local in_progress
        in_progress=$(grep '=in_progress' "$state_file" 2>/dev/null || true)
        if [ -n "$in_progress" ]; then
            tag_warn "Stage(s) stuck in_progress — may need --resume or --reset"
            echo "$in_progress" | while read -r line; do
                tag_info "  $line"
            done
        fi
    else
        tag_info "No checkpoint state file (fresh install)"
    fi

    # Backup files
    if [ -d "$state_dir/backups" ]; then
        local backup_count
        backup_count=$(find "$state_dir/backups" -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' ')
        tag_info "Shell RC backups: $backup_count"
    fi

    subsection "Version Compatibility Matrix"

    # Python ↔ venv
    local venv_path="${VENV_DEFAULT_PATH:-$HOME/ai-env}"
    if [ -x "$venv_path/bin/python" ]; then
        local venv_py_ver; venv_py_ver=$("$venv_path/bin/python" --version 2>/dev/null | sed 's/Python //')
        local target_py_ver="${PYTHON_VERSION:-3.12}"
        local venv_py_major; venv_py_major=$(echo "$venv_py_ver" | cut -d. -f1,2)

        if [ "$venv_py_major" = "$target_py_ver" ]; then
            tag_ok "Python $target_py_ver ↔ venv Python $venv_py_ver: compatible"
            OK_COUNT=$((OK_COUNT + 1))
        else
            tag_warn "Python target $target_py_ver but venv has $venv_py_ver — may need venv rebuild"
        fi
    fi

    # CUDA ↔ PyTorch
    if [ "$GPU_BACKEND" = "cuda" ] && [ -x "$venv_path/bin/python" ]; then
        local torch_cuda_ver
        torch_cuda_ver=$("$venv_path/bin/python" -c "import torch; print(torch.version.cuda or 'None')" 2>/dev/null || echo "N/A")
        if [ "$torch_cuda_ver" != "N/A" ] && [ "$torch_cuda_ver" != "None" ]; then
            local sys_cuda_major; sys_cuda_major=$(echo "$CUDA_VERSION" | cut -d. -f1)
            local torch_cuda_major; torch_cuda_major=$(echo "$torch_cuda_ver" | cut -d. -f1)
            if [ "$sys_cuda_major" = "$torch_cuda_major" ]; then
                tag_ok "System CUDA $CUDA_VERSION ↔ torch CUDA $torch_cuda_ver: compatible"
                OK_COUNT=$((OK_COUNT + 1))
            else
                tag_warn "System CUDA $CUDA_VERSION but torch compiled with CUDA $torch_cuda_ver"
                tag_info "  This may cause runtime errors. Consider rebuilding venv."
            fi
        fi
    fi

    subsection "Potential Conflicts"

    # Check for conda (common conflict)
    if command -v conda &>/dev/null; then
        tag_warn "conda detected — may conflict with uv/venv package management"
        tag_info "  Recommendation: deactivate conda before using aienv"
    fi

    # Check for pyenv (may shadow uv Python)
    if command -v pyenv &>/dev/null; then
        tag_info "pyenv detected — uv Python takes priority, but check PATH order"
    fi

    # Check for system-installed torch
    if python3 -c "import torch" 2>/dev/null; then
        local sys_torch_path
        sys_torch_path=$(python3 -c "import torch; print(torch.__file__)" 2>/dev/null)
        if [[ "$sys_torch_path" != *"$venv_path"* ]]; then
            tag_warn "System-wide torch installation detected: $sys_torch_path"
            tag_info "  May shadow venv torch when venv not activated"
        fi
    fi

    # NGC container check
    if [ -d "/opt/nvidia" ] || [ -f "/etc/nvidia/entrypoint.d/10-banner.sh" ]; then
        tag_info "NGC container environment detected"
        if [ "${INSTALL_NVIDIA:-true}" = "true" ]; then
            tag_warn "INSTALL_NVIDIA=true but NGC already has NVIDIA stack"
            tag_info "  Recommend: use profile ngc-container (INSTALL_NVIDIA=false)"
        fi
    fi
}

# ============================================================
# Summary Report
# ============================================================
print_summary() {
    echo ""
    printf "${C_BOLD}══════════════════════════════════════════════════════════${C_RESET}\n"
    printf "${C_BOLD}  Summary${C_RESET}\n"
    printf "${C_BOLD}══════════════════════════════════════════════════════════${C_RESET}\n"
    echo ""

    printf "  ${C_GREEN}OK:${C_RESET}       %d\n" "$OK_COUNT"
    [ "$INSTALL_COUNT" -gt 0 ] && printf "  ${C_CYAN}INSTALL:${C_RESET}  %d\n" "$INSTALL_COUNT"
    [ "$SKIP_COUNT" -gt 0 ]    && printf "  ${C_DIM}SKIP:${C_RESET}     %d\n" "$SKIP_COUNT"
    [ "$WARN_COUNT" -gt 0 ]    && printf "  ${C_YELLOW}WARN:${C_RESET}     %d\n" "$WARN_COUNT"
    [ "$FAIL_COUNT" -gt 0 ]    && printf "  ${C_RED}FAIL:${C_RESET}     %d\n" "$FAIL_COUNT"
    echo ""

    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf "  ${C_RED}${C_BOLD}⛔ BLOCKING ISSUES FOUND${C_RESET} — resolve FAIL items before installation\n"
    elif [ "$WARN_COUNT" -gt 0 ]; then
        printf "  ${C_YELLOW}${C_BOLD}⚠  WARNINGS FOUND${C_RESET} — installation can proceed but review warnings\n"
    elif [ "$INSTALL_COUNT" -gt 0 ]; then
        printf "  ${C_GREEN}${C_BOLD}✓  READY TO INSTALL${C_RESET} — $INSTALL_COUNT component(s) will be installed\n"
    else
        printf "  ${C_GREEN}${C_BOLD}✓  ALL UP TO DATE${C_RESET} — no actions needed\n"
    fi
    echo ""

    # Estimated time
    local est_minutes=0
    [ "$INSTALL_COUNT" -gt 0 ] && est_minutes=$((est_minutes + INSTALL_COUNT * 3))
    # NVIDIA takes longer
    if [ "$GPU_BACKEND" = "cuda" ] && [ "${INSTALL_NVIDIA:-true}" = "true" ]; then
        est_minutes=$((est_minutes + 10))
    fi
    if [ "$est_minutes" -gt 0 ]; then
        tag_info "Estimated installation time: ~${est_minutes} minutes"
    fi

    # Next steps
    if [ "$INSTALL_COUNT" -gt 0 ] || [ "$FAIL_COUNT" -gt 0 ]; then
        echo ""
        printf "  ${C_BOLD}Next steps:${C_RESET}\n"
        if [ "$FAIL_COUNT" -gt 0 ]; then
            echo "    1. Resolve all [FAIL] items above"
            echo "    2. Re-run: ./scripts/dry-run.sh"
            echo "    3. Then: ./setup.sh"
        else
            echo "    Run: ./setup.sh"
            echo "    Or:  ./setup.sh --profile $PROFILE"
        fi
    fi

    echo ""
}

# ============================================================
# Main
# ============================================================

echo ""
printf "${C_BOLD}══════════════════════════════════════════════════════════${C_RESET}\n"
printf "${C_BOLD}  Machine Setting — Comprehensive Dry-Run Diagnostic${C_RESET}\n"
printf "${C_BOLD}  $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}\n"
printf "${C_BOLD}══════════════════════════════════════════════════════════${C_RESET}\n"

detect_system_info

if [ -n "$STAGE_FILTER" ]; then
    case "$STAGE_FILTER" in
        hardware|1) diag_hardware ;;
        nvidia|2)   diag_hardware; diag_nvidia ;;
        python|3)   diag_python ;;
        venv|4)     diag_venv ;;
        node|5)     diag_node ;;
        java|6)     diag_java ;;
        shell|7)    diag_shell ;;
        *)
            echo "Unknown stage: $STAGE_FILTER"
            echo "Available: hardware, nvidia, python, venv, node, java, shell"
            exit 1 ;;
    esac
else
    diag_hardware
    diag_nvidia
    diag_python
    diag_venv
    diag_node
    diag_java
    diag_shell
    diag_cross_stage
fi

print_summary

# Exit code
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
else
    exit 0
fi
