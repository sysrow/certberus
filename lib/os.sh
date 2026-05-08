#!/bin/bash
# certberus/lib/os.sh - OS detection + package manager abstraction
[[ -n "${_CB_OS_LOADED:-}" ]] && return 0
_CB_OS_LOADED=1

# Outputs:
#   CB_OS_ID         debian|ubuntu|rocky|almalinux|centos|rhel|fedora|alpine|unknown
#   CB_OS_LIKE       debian|rhel|suse|alpine|...
#   CB_OS_VERSION    e.g. "12", "22.04"
#   CB_OS_CODENAME   e.g. "bookworm", "jammy"
#   CB_PKG_MGR       apt|dnf|yum|zypper|apk
#   CB_PKG_UPDATE    command to update package index
#   CB_PKG_INSTALL   command to install packages (append package names)

cb_detect_os() {
    CB_OS_ID="unknown"; CB_OS_LIKE=""; CB_OS_VERSION=""; CB_OS_CODENAME=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        CB_OS_ID="${ID:-unknown}"
        CB_OS_LIKE="${ID_LIKE:-}"
        CB_OS_VERSION="${VERSION_ID:-}"
        CB_OS_CODENAME="${VERSION_CODENAME:-}"
    fi

    # Package manager
    if command -v apt-get >/dev/null 2>&1; then
        CB_PKG_MGR="apt"
        CB_PKG_UPDATE="apt-get update -qq"
        CB_PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends"
    elif command -v dnf >/dev/null 2>&1; then
        CB_PKG_MGR="dnf"
        CB_PKG_UPDATE="dnf -q makecache"
        CB_PKG_INSTALL="dnf install -y -q"
    elif command -v yum >/dev/null 2>&1; then
        CB_PKG_MGR="yum"
        CB_PKG_UPDATE="yum -q makecache"
        CB_PKG_INSTALL="yum install -y -q"
    elif command -v zypper >/dev/null 2>&1; then
        CB_PKG_MGR="zypper"
        CB_PKG_UPDATE="zypper -q refresh"
        CB_PKG_INSTALL="zypper -q install -y --no-recommends"
    elif command -v apk >/dev/null 2>&1; then
        CB_PKG_MGR="apk"
        CB_PKG_UPDATE="apk update -q"
        CB_PKG_INSTALL="apk add -q"
    else
        CB_PKG_MGR=""
    fi

    export CB_OS_ID CB_OS_LIKE CB_OS_VERSION CB_OS_CODENAME CB_PKG_MGR CB_PKG_UPDATE CB_PKG_INSTALL
}

# Check if OS is in the allowed list.
# Usage: cb_require_os "debian" "ubuntu"
cb_require_os() {
    local allowed=("$@")
    local ok=0
    for o in "${allowed[@]}"; do
        [[ "$CB_OS_ID" == "$o" ]] && { ok=1; break; }
        [[ "$CB_OS_LIKE" == *"$o"* ]] && { ok=1; break; }
    done
    if (( ok == 0 )); then
        cb_die "OS $CB_OS_ID $CB_OS_VERSION is not supported. Supported: ${allowed[*]}"
    fi
}

cb_pkg_install() {
    [[ -z "$CB_PKG_MGR" ]] && { cb_error "Unknown package manager."; return 1; }
    cb_log "Installing packages: $*"
    if [[ "$CB_DRY_RUN" == "1" ]]; then
        cb_log "[DRY-RUN] $CB_PKG_INSTALL $*"
        return 0
    fi
    eval "$CB_PKG_UPDATE" >/dev/null 2>&1 || true
    eval "$CB_PKG_INSTALL $*"
}

cb_pkg_installed() {
    local p="$1"
    case "$CB_PKG_MGR" in
        apt)    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" ;;
        dnf|yum) rpm -q "$p" >/dev/null 2>&1 ;;
        zypper) rpm -q "$p" >/dev/null 2>&1 ;;
        apk)    apk info -e "$p" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# Initialize on source
cb_detect_os
