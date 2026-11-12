# Non-secret environment variables
# Secrets go in ~/.bashrc.local (gitignored)

export EDITOR="${EDITOR:-vim}"
export LANG="${LANG:-en_US.UTF-8}"
# Only force LC_ALL when that locale is actually generated; a fresh Ubuntu install may ship
# just C.UTF-8, and pointing LC_ALL at a missing locale makes every shell print setlocale warnings.
if [ -z "${LC_ALL:-}" ] && locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
    export LC_ALL="en_US.UTF-8"
fi

# Python
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

# HuggingFace cache
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

# Torch
export TORCH_HOME="${TORCH_HOME:-$HOME/.cache/torch}"

# Reduce telemetry
export WANDB_SILENT=true
export DO_NOT_TRACK=1
