# Common aliases

# Python
alias py='python3'
alias pip='pip3'
alias ipy='ipython'

# Git shortcuts
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'
alias gp='git pull --rebase'

# Machine setting
alias ms='cd ~/machine_setting'
alias mss='make -C ~/machine_setting status'
alias msu='make -C ~/machine_setting update'
alias msp='make -C ~/machine_setting push'

# GPU monitoring (cross-platform)
if [ "$(uname -s)" = "Darwin" ]; then
    # macOS: use powermetrics for Apple Silicon GPU (requires sudo)
    alias gpustat='echo "Apple Silicon GPU"; ioreg -l | grep -i "gpu-core" 2>/dev/null || echo "Use: sudo powermetrics --samplers gpu_power -i 1000 -n 1"'
else
    alias gpustat='nvidia-smi --query-gpu=gpu_name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu --format=csv,noheader 2>/dev/null || echo "No GPU"'
fi
