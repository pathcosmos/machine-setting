# Reminder after a setup that needed a reboot (or whose verification failed).
# setup.sh leaves ~/.machine_setting/verify-pending; ./setup.sh --verify removes it once tests pass.
if [ -f "$HOME/.machine_setting/verify-pending" ]; then
    case "$-" in
        *i*)
            _ms_repo="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")/../.." 2>/dev/null && pwd)"
            printf '\n  machine-setting: installation is not verified yet. Run: %s/setup.sh --verify\n\n' "${_ms_repo:-<repo>}"
            unset _ms_repo
            ;;
    esac
fi
