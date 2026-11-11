#!/usr/bin/env bash
# system-info.sh — Detailed machine spec report (Markdown), meant to be pasted to another person/agent.
#
# Usage:
#   ./scripts/system-info.sh              # print to stdout
#   ./scripts/system-info.sh -o spec.md   # write to a file
#   ./scripts/system-info.sh --packages   # also list every Python package in the AI venv
#
# Read-only, no sudo. Deliberately omits serial numbers, MAC/IP addresses, and secrets.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUT=""
ALL_PACKAGES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) OUT="$2"; shift 2 ;;
        --packages)  ALL_PACKAGES=true; shift ;;
        --help|-h)   sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

export PATH="$HOME/.local/bin:/usr/local/cuda/bin:$PATH"
[ -f "$REPO_DIR/config/default.conf" ] && source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"
VENV="${VENV_DEFAULT_PATH:-$HOME/ai-env}"

have() { command -v "$1" &>/dev/null; }
row()  { printf '| %s | %s |\n' "$1" "${2:-—}"; }
first() { head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
dmi()  { cat "/sys/class/dmi/id/$1" 2>/dev/null | first; }

report() {
    echo "# Machine Spec — $(hostname)"
    echo ""
    echo "Generated: $(date '+%Y-%m-%d %H:%M %Z') by \`scripts/system-info.sh\`"
    echo ""

    # ---------------- System ----------------
    echo "## System"
    echo ""
    echo "| Item | Value |"
    echo "|------|-------|"
    row "OS" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME (${VERSION_CODENAME:-})")"
    row "Kernel" "$(uname -r) ($(uname -m))"
    row "Board" "$(dmi board_vendor) $(dmi board_name)"
    row "Product" "$(dmi sys_vendor) $(dmi product_name)"
    row "BIOS" "$(dmi bios_vendor) $(dmi bios_version) ($(dmi bios_date))"
    row "Boot" "$([ -d /sys/firmware/efi ] && echo UEFI || echo Legacy BIOS), Secure Boot: $(mokutil --sb-state 2>/dev/null | first | sed 's/SecureBoot //' || echo unknown)"
    row "Virtualization" "$(v=$(systemd-detect-virt 2>/dev/null); echo "${v:-unknown}")"
    row "Uptime since" "$(uptime -s 2>/dev/null)"
    row "Timezone / locale" "$(timedatectl show -p Timezone --value 2>/dev/null) / ${LANG:-unset}"
    echo ""

    # ---------------- CPU / Memory ----------------
    echo "## CPU & Memory"
    echo ""
    echo "| Item | Value |"
    echo "|------|-------|"
    lscpu_v() { lscpu 2>/dev/null | grep -m1 "^$1:" | cut -d: -f2- | first; }
    row "CPU" "$(lscpu_v 'Model name')"
    row "Sockets / cores / threads" "$(lscpu_v 'Socket(s)') / $(lscpu_v 'Core(s) per socket') per socket / $(nproc) logical"
    row "Max frequency" "$(lscpu_v 'CPU max MHz' | cut -d. -f1) MHz"
    row "Caches" "L2 $(lscpu_v 'L2 cache'), L3 $(lscpu_v 'L3 cache')"
    row "CPU flags (AI-relevant)" "$(grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -xE 'avx|avx2|avx512f|avx512_vnni|avx_vnni|amx_tile|fma|sse4_2' | paste -sd' ' -)"
    row "NUMA nodes" "$(lscpu_v 'NUMA node(s)')"
    row "CPU governor" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    row "RAM" "$(free -h | awk '/^Mem:/{print $2" total, "$7" available"}')"
    row "Swap" "$(free -h | awk '/^Swap:/{print $2" total, "$3" used"}')"
    echo ""

    # ---------------- GPU ----------------
    echo "## GPU"
    echo ""
    if have nvidia-smi && nvidia-smi &>/dev/null; then
        echo "| # | Model | VRAM | Driver | Temp | Power (draw / limit) | PCIe link |"
        echo "|---|-------|------|--------|------|----------------------|-----------|"
        nvidia-smi --query-gpu=index,name,memory.total,driver_version,temperature.gpu,power.draw,power.limit,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current \
            --format=csv,noheader,nounits 2>/dev/null | while IFS=, read -r i n m d t pd pl g gm w; do
            printf '| %s | %s | %s MiB | %s | %s°C | %s W / %s W | Gen%s (max Gen%s) x%s |\n' \
                "$(echo $i)" "$(echo $n)" "$(echo $m)" "$(echo $d)" "$(echo $t)" "$(echo $pd)" "$(echo $pl)" "$(echo $g)" "$(echo $gm)" "$(echo $w)"
        done
        echo ""
        echo "| Item | Value |"
        echo "|------|-------|"
        row "Kernel module" "$(modinfo -F filename nvidia 2>/dev/null | grep -q open && echo 'open kernel modules' || echo 'proprietary') $(modinfo -F version nvidia 2>/dev/null), signer: $(modinfo -F signer nvidia 2>/dev/null || echo none)"
        row "Driver CUDA support (max)" "$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | first)"
        row "CUDA Toolkit" "$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p' | first) ($(readlink -f /usr/local/cuda 2>/dev/null))"
        row "cuDNN" "$(dpkg-query -W -f='${Package} ${Version}\n' 'cudnn9-cuda-*' 2>/dev/null | first)"
        row "NCCL" "$(dpkg-query -W -f='${Version}' libnccl2 2>/dev/null)"
        row "NVIDIA Container Toolkit" "$(nvidia-ctk --version 2>/dev/null | first | sed 's/.*version //')"
    else
        lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/^/- /'
        echo ""
        echo "_nvidia-smi not available (no NVIDIA driver loaded)._"
    fi
    echo ""
    echo "Other display adapters: $(lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -vi nvidia | cut -d: -f3- | first)"
    echo ""

    # ---------------- Storage ----------------
    echo "## Storage"
    echo ""
    echo '```'
    lsblk -e 7 -o NAME,SIZE,TYPE,ROTA,TRAN,MODEL,FSTYPE,MOUNTPOINTS 2>/dev/null
    echo ""
    df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null
    echo '```'
    echo ""
    echo "(ROTA 1 = HDD, 0 = SSD/NVMe)"
    echo ""

    # ---------------- Network ----------------
    echo "## Network"
    echo ""
    echo "| Interface | State | Speed | Driver |"
    echo "|-----------|-------|-------|--------|"
    for n in /sys/class/net/*; do
        local i; i=$(basename "$n")
        [ -e "$n/device" ] || continue   # physical NICs only
        printf '| %s | %s | %s | %s |\n' "$i" "$(cat "$n/operstate" 2>/dev/null)" \
            "$(s=$(cat "$n/speed" 2>/dev/null); [ -n "$s" ] && [ "$s" -gt 0 ] 2>/dev/null && echo "${s} Mb/s" || echo '—')" \
            "$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null)"
    done
    echo ""
    echo "Listening TCP ports: $(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | paste -sd' ' -)"
    echo ""

    # ---------------- Software ----------------
    echo "## Software"
    echo ""
    echo "| Tool | Version |"
    echo "|------|---------|"
    row "Python (system)" "$(python3 --version 2>&1 | cut -d' ' -f2)"
    row "uv" "$(uv --version 2>/dev/null | cut -d' ' -f2)"
    row "AI venv" "$VENV — Python $("$VENV/bin/python" --version 2>&1 | cut -d' ' -f2), $(uv pip list --python "$VENV/bin/python" 2>/dev/null | tail -n +3 | wc -l) packages"
    row "vLLM venv" "$(bash "$SCRIPT_DIR/install-vllm.sh" --check 2>/dev/null | sed 's/^ *//' || echo 'not installed')"
    row "Node.js" "$(ls "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1) (nvm)"
    row "Java" "$("$HOME/.sdkman/candidates/java/current/bin/java" -version 2>&1 | first) (SDKMAN)"
    row "Docker" "$(docker --version 2>/dev/null | sed 's/Docker version //; s/,.*//'), Compose $(docker compose version --short 2>/dev/null)"
    row "GCC / CMake" "$(gcc -dumpfullversion 2>/dev/null) / $(cmake --version 2>/dev/null | first | awk '{print $3}')"
    row "Git" "$(git --version 2>/dev/null | awk '{print $3}')"
    row "Shell" "$(basename "${SHELL:-}") ($BASH_VERSION)"
    echo ""

    if [ -x "$VENV/bin/python" ]; then
        echo "### AI environment (\`$VENV\`)"
        echo ""
        echo '```'
        "$VENV/bin/python" - <<'PYEOF' 2>/dev/null
import importlib.metadata as md, warnings
warnings.filterwarnings("ignore")
try:
    import torch
    print(f"torch {torch.__version__}  cuda_available={torch.cuda.is_available()}  built_for_cuda={torch.version.cuda}  cudnn={torch.backends.cudnn.version()}")
    for i in range(torch.cuda.device_count()):
        p = torch.cuda.get_device_properties(i)
        print(f"  cuda:{i} {p.name}  {p.total_memory/2**30:.1f} GiB  capability={p.major}.{p.minor}")
except Exception as e:
    print("torch: not usable:", e)
keys = ["torchvision","torchaudio","transformers","accelerate","peft","datasets","tokenizers","sentence-transformers",
        "bitsandbytes","deepspeed","triton","onnxruntime-gpu","numpy","pandas","scikit-learn","langchain","langgraph",
        "anthropic","openai","google-genai","fastapi","gradio","chromadb","faiss-cpu","opencv-python","pillow"]
for k in keys:
    try: print(f"{k} {md.version(k)}")
    except md.PackageNotFoundError: pass
PYEOF
        echo '```'
        echo ""
        if [ "$ALL_PACKAGES" = true ]; then
            echo "<details><summary>All Python packages</summary>"
            echo ""
            echo '```'
            uv pip freeze --python "$VENV/bin/python" 2>/dev/null
            echo '```'
            echo "</details>"
            echo ""
        fi
    fi

    # ---------------- Server configuration ----------------
    echo "## Server configuration"
    echo ""
    echo "| Item | Value |"
    echo "|------|-------|"
    row "Sleep / suspend" "$(v=$(systemctl is-enabled suspend.target 2>/dev/null); echo "${v:-unknown}")"
    row "Unattended upgrades" "$(v=$(systemctl is-enabled unattended-upgrades 2>/dev/null); echo "${v:-not installed}")$([ -f /etc/apt/apt.conf.d/52machine-setting-unattended ] && echo '; no auto-reboot, kernel + NVIDIA held (manual upgrade)')"
    row "SMART monitoring" "$(systemctl is-active smartmontools 2>/dev/null || echo inactive)"
    row "GPU persistence" "nvidia-persistenced: $(systemctl is-active nvidia-persistenced 2>/dev/null); kernel params: $(tr ' ' '\n' < /proc/cmdline | grep -E 'pcie_|nvidia\.' | paste -sd' ' - || true)"
    local mon=""
    curl -fs -m 2 http://127.0.0.1:9090/-/healthy &>/dev/null && mon="Prometheus :9090"
    curl -fs -m 2 http://127.0.0.1:3000/api/health &>/dev/null && mon="${mon:+$mon, }Grafana :3000"
    row "Monitoring" "${mon:-not running}"
    row "Display server" "$(systemctl is-active display-manager 2>/dev/null | grep -qx active && echo running || echo 'none (headless)')"
    row "Setup project" "$REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null))"
    echo ""
}

if [ -n "$OUT" ]; then
    report > "$OUT"
    echo "Wrote $OUT"
else
    report
fi
