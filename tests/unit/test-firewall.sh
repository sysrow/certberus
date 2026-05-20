#!/bin/bash
# tests/unit/test-firewall.sh
# Comprehensive tests for lib/firewall.sh.
# All firewall backends (nft, iptables, firewall-cmd, ufw) are mocked
# via fake scripts in sandbox PATH - nothing requires root or real tools.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

SANDBOX="$(t_mktempdir fw-test)"
trap 't_cleanup' EXIT
t_isolate_cb_dirs "$SANDBOX"
t_stub_log_helpers

# Helper variables for mocks
MOCK="$SANDBOX/mock-bin"
MOCK_LOG="$SANDBOX/mock-calls.log"
ORIG_PATH="$PATH"

# Helper: clean mock directory and log before each test
reset_mocks() {
    rm -rf "$MOCK"
    mkdir -p "$MOCK"
    : > "$MOCK_LOG"
    # Reset detection state from previous source
    unset _CB_FW_LOADED 2>/dev/null || true
    export CB_DRY_RUN=0
    # Strip sbin paths so real /usr/sbin/{nft,iptables,ufw,firewall-cmd}
    # cannot leak in when the test wants the tool to be absent. /usr/bin and
    # /bin stay so basic shell utilities (cat, rm, mkdir, ...) still work.
    local clean_path=""
    local d
    while IFS= read -r d; do
        case "$d" in
            */sbin|/sbin|/usr/sbin|/usr/local/sbin) continue ;;
            "") continue ;;
        esac
        clean_path="${clean_path:+$clean_path:}$d"
    done < <(echo "$ORIG_PATH" | tr ':' '\n')
    export PATH="$MOCK:$clean_path"
    # Default-deny systemctl - any test that wants a service to look 'active'
    # provides its own systemctl mock and overwrites this file.
    cat > "$MOCK/systemctl" <<'MOCKEOF'
#!/bin/bash
exit 1
MOCKEOF
    chmod +x "$MOCK/systemctl"
}

# Helper: mock command with logging and optional output/return value
# Usage: make_mock <name> [output [exit-code]]
make_mock() {
    local name="$1"
    local output="${2:-}"
    local rc="${3:-0}"
    cat > "$MOCK/$name" <<MOCKEOF
#!/bin/bash
echo "$name \$*" >> "$MOCK_LOG"
$([ -n "$output" ] && echo "echo '$output'")
exit $rc
MOCKEOF
    chmod +x "$MOCK/$name"
}

# Load firewall.sh - we must bypass auto-initialization at the end of the file.
# First source performs cb_firewall_detect() with empty PATH,
# then we call functions directly with configured environment.
_CB_FW_LOADED=""
# Source with empty mock - detection falls back to "none"/"docker", that is OK
PATH="$ORIG_PATH"
source "$CB_REPO_ROOT/lib/firewall.sh"

# ============================================================================
# 1) cb_firewall_detect - various scenarios
# ============================================================================
t_info "=== cb_firewall_detect ==="

# --- 1a) Docker: /.dockerenv in sandbox ---
reset_mocks
# Create a fake /.dockerenv inside unshare, if available;
# otherwise simulate via /proc/1/cgroup grep.
# We test the cgroup branch -- safer than writing to /.dockerenv.
# Mock: grep on /proc/1/cgroup returns 'docker' -- but grep reads real files.
# Instead we verify: if nothing else is in PATH, and /.dockerenv does not exist,
# backend == none.
CB_FW_BACKEND=""
cb_firewall_detect
if [[ -f /.dockerenv ]]; then
    assert_eq "docker" "$CB_FW_BACKEND" "detect: docker (/.dockerenv exists)"
else
    # Not docker - expect none (no tools in PATH)
    assert_eq "none" "$CB_FW_BACKEND" "detect: no tools -> none"
fi

# --- 1b) firewalld backend ---
reset_mocks
make_mock "firewall-cmd" "running"
cat > "$MOCK/systemctl" <<MOCKEOF
#!/bin/bash
echo "systemctl \$*" >> "$MOCK_LOG"
# is-active --quiet firewalld -> success
if [[ "\$1" == "is-active" && "\$3" == "firewalld" ]]; then
    exit 0
fi
exit 1
MOCKEOF
chmod +x "$MOCK/systemctl"
CB_FW_BACKEND=""
cb_firewall_detect
assert_eq "firewalld" "$CB_FW_BACKEND" "detect: firewalld (firewall-cmd + systemctl)"

# --- 1c) ufw backend ---
reset_mocks
cat > "$MOCK/ufw" <<MOCKEOF
#!/bin/bash
echo "ufw \$*" >> "$MOCK_LOG"
if [[ "\$1" == "status" ]]; then
    echo "Status: active"
fi
exit 0
MOCKEOF
chmod +x "$MOCK/ufw"
CB_FW_BACKEND=""
cb_firewall_detect
assert_eq "ufw" "$CB_FW_BACKEND" "detect: ufw (Status: active)"

# --- 1d) nftables backend ---
reset_mocks
make_mock "nft" "table inet filter { chain input { } }"
cat > "$MOCK/systemctl" <<MOCKEOF
#!/bin/bash
echo "systemctl \$*" >> "$MOCK_LOG"
if [[ "\$1" == "is-active" && "\$3" == "nftables" ]]; then
    exit 0
fi
exit 1
MOCKEOF
chmod +x "$MOCK/systemctl"
CB_FW_BACKEND=""
cb_firewall_detect
assert_eq "nftables" "$CB_FW_BACKEND" "detect: nftables (nft + systemctl)"

# --- 1e) iptables-nft backend ---
reset_mocks
cat > "$MOCK/iptables" <<MOCKEOF
#!/bin/bash
echo "iptables \$*" >> "$MOCK_LOG"
if [[ "\$1" == "-V" ]]; then
    echo "iptables v1.8.7 (nf_tables)"
fi
exit 0
MOCKEOF
chmod +x "$MOCK/iptables"
CB_FW_BACKEND=""
cb_firewall_detect
assert_eq "iptables-nft" "$CB_FW_BACKEND" "detect: iptables-nft (nf_tables in output)"

# --- 1f) iptables-legacy backend ---
reset_mocks
cat > "$MOCK/iptables" <<MOCKEOF
#!/bin/bash
echo "iptables \$*" >> "$MOCK_LOG"
if [[ "\$1" == "-V" ]]; then
    echo "iptables v1.6.1 (legacy)"
fi
exit 0
MOCKEOF
chmod +x "$MOCK/iptables"
CB_FW_BACKEND=""
cb_firewall_detect
assert_eq "iptables-legacy" "$CB_FW_BACKEND" "detect: iptables-legacy (without nf_tables)"

# --- 1g) priorita: firewalld > ufw > nftables ---
reset_mocks
make_mock "firewall-cmd" "running"
cat > "$MOCK/ufw" <<MOCKEOF
#!/bin/bash
echo "ufw \$*" >> "$MOCK_LOG"
echo "Status: active"
exit 0
MOCKEOF
chmod +x "$MOCK/ufw"
make_mock "nft" ""
cat > "$MOCK/systemctl" <<MOCKEOF
#!/bin/bash
echo "systemctl \$*" >> "$MOCK_LOG"
if [[ "\$1" == "is-active" && "\$3" == "firewalld" ]]; then exit 0; fi
if [[ "\$1" == "is-active" && "\$3" == "nftables" ]]; then exit 0; fi
exit 1
MOCKEOF
chmod +x "$MOCK/systemctl"
CB_FW_BACKEND=""
cb_firewall_detect
assert_eq "firewalld" "$CB_FW_BACKEND" "detect: priority firewalld > ufw > nftables"

# --- 1h) priorita: ufw > nftables ---
reset_mocks
cat > "$MOCK/ufw" <<MOCKEOF
#!/bin/bash
echo "ufw \$*" >> "$MOCK_LOG"
echo "Status: active"
exit 0
MOCKEOF
chmod +x "$MOCK/ufw"
make_mock "nft" ""
cat > "$MOCK/systemctl" <<MOCKEOF
#!/bin/bash
echo "systemctl \$*" >> "$MOCK_LOG"
if [[ "\$1" == "is-active" && "\$3" == "nftables" ]]; then exit 0; fi
exit 1
MOCKEOF
chmod +x "$MOCK/systemctl"
CB_FW_BACKEND=""
cb_firewall_detect
assert_eq "ufw" "$CB_FW_BACKEND" "detect: priority ufw > nftables"

# ============================================================================
# 2) cb_firewall_backend_pretty
# ============================================================================
t_info "=== cb_firewall_backend_pretty ==="

CB_FW_BACKEND="firewalld"
assert_eq "firewalld (firewall-cmd)" "$(cb_firewall_backend_pretty)" "pretty: firewalld"

CB_FW_BACKEND="ufw"
assert_eq "UFW (Uncomplicated Firewall)" "$(cb_firewall_backend_pretty)" "pretty: ufw"

CB_FW_BACKEND="nftables"
assert_eq "nftables (nft)" "$(cb_firewall_backend_pretty)" "pretty: nftables"

CB_FW_BACKEND="iptables-nft"
assert_eq "iptables (nf_tables backend)" "$(cb_firewall_backend_pretty)" "pretty: iptables-nft"

CB_FW_BACKEND="iptables-legacy"
assert_eq "iptables (legacy)" "$(cb_firewall_backend_pretty)" "pretty: iptables-legacy"

CB_FW_BACKEND="docker"
assert_eq "container (host-managed)" "$(cb_firewall_backend_pretty)" "pretty: docker"

CB_FW_BACKEND="none"
assert_eq "no active firewall" "$(cb_firewall_backend_pretty)" "pretty: none"

# ============================================================================
# 3) cb_firewall_open_port
# ============================================================================
t_info "=== cb_firewall_open_port ==="

# --- 3a) DRY_RUN mode: no commands, returns 0 ---
reset_mocks
CB_FW_BACKEND="nftables"
CB_DRY_RUN=1
cb_firewall_open_port tcp 443
assert_eq "" "$(cat "$MOCK_LOG")" "open_port DRY_RUN: no calls"
CB_DRY_RUN=0

# --- 3b) nftables backend: uses insert (not add) ---
reset_mocks
CB_FW_BACKEND="nftables"
# Mock nft: list ruleset does not contain port -> must add
cat > "$MOCK/nft" <<MOCKEOF
#!/bin/bash
echo "nft \$*" >> "$MOCK_LOG"
case "\$1" in
    list)
        if [[ "\$*" == *"ruleset"* ]]; then
            echo "table inet filter { chain input { } }"
        elif [[ "\$*" == *"table inet filter"* ]]; then
            echo "table inet filter { chain input { } }"
        fi
        ;;
    insert) exit 0 ;;
    add) exit 0 ;;
esac
exit 0
MOCKEOF
chmod +x "$MOCK/nft"
cb_firewall_open_port tcp 443
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "insert rule inet filter input" "open_port nft: uses insert (not add)"
assert_contains "$calls" "443" "open_port nft: contains port 443"

# --- 3c) nftables: idempotence - port already exists ---
reset_mocks
CB_FW_BACKEND="nftables"
cat > "$MOCK/nft" <<MOCKEOF
#!/bin/bash
echo "nft \$*" >> "$MOCK_LOG"
case "\$1" in
    list)
        echo "table inet filter { chain input { tcp dport 443 accept } }"
        ;;
esac
exit 0
MOCKEOF
chmod +x "$MOCK/nft"
cb_firewall_open_port tcp 443
calls=$(cat "$MOCK_LOG")
# Must not contain insert — port is already open
assert_not_contains "$calls" "insert" "open_port nft: idempotent, port already open"

# --- 3d) iptables backend: uses -I INPUT ---
reset_mocks
CB_FW_BACKEND="iptables-legacy"
cat > "$MOCK/iptables" <<MOCKEOF
#!/bin/bash
echo "iptables \$*" >> "$MOCK_LOG"
# -C (check) returns 1 = rule does not exist -> add it
if [[ "\$1" == "-C" ]]; then exit 1; fi
exit 0
MOCKEOF
chmod +x "$MOCK/iptables"
cb_firewall_open_port tcp 80 "certberus-http"
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "iptables -I INPUT" "open_port iptables: uses -I INPUT"
assert_contains "$calls" "--dport 80" "open_port iptables: --dport 80"
assert_contains "$calls" "certberus-http" "open_port iptables: comment certberus-http"

# --- 3e) iptables idempotence: -C succeeds -> no insert ---
reset_mocks
CB_FW_BACKEND="iptables-nft"
cat > "$MOCK/iptables" <<MOCKEOF
#!/bin/bash
echo "iptables \$*" >> "$MOCK_LOG"
# -C (check) returns 0 = rule already exists
exit 0
MOCKEOF
chmod +x "$MOCK/iptables"
cb_firewall_open_port tcp 80
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "iptables -C INPUT" "open_port iptables idempotent: -C check"
assert_not_contains "$calls" "iptables -I INPUT" "open_port iptables idempotent: no -I (already exists)"

# --- 3f) docker/none: no action ---
reset_mocks
CB_FW_BACKEND="docker"
cb_firewall_open_port tcp 80
assert_eq "" "$(cat "$MOCK_LOG")" "open_port docker: no calls"

reset_mocks
CB_FW_BACKEND="none"
cb_firewall_open_port tcp 443
assert_eq "" "$(cat "$MOCK_LOG")" "open_port none: no calls"

# ============================================================================
# 4) cb_firewall_close_port
# ============================================================================
t_info "=== cb_firewall_close_port ==="

# --- 4a) DRY_RUN ---
reset_mocks
CB_FW_BACKEND="iptables-legacy"
CB_DRY_RUN=1
cb_firewall_close_port tcp 80
assert_eq "" "$(cat "$MOCK_LOG")" "close_port DRY_RUN: no calls"
CB_DRY_RUN=0

# --- 4b) iptables: -D INPUT ---
reset_mocks
CB_FW_BACKEND="iptables-legacy"
cat > "$MOCK/iptables" <<MOCKEOF
#!/bin/bash
echo "iptables \$*" >> "$MOCK_LOG"
exit 0
MOCKEOF
chmod +x "$MOCK/iptables"
cb_firewall_close_port tcp 443 "certberus-https"
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "iptables -D INPUT" "close_port iptables: -D INPUT"
assert_contains "$calls" "--dport 443" "close_port iptables: --dport 443"
assert_contains "$calls" "certberus-https" "close_port iptables: comment"

# --- 4c) firewalld: --remove-port ---
reset_mocks
CB_FW_BACKEND="firewalld"
make_mock "firewall-cmd" ""
cb_firewall_close_port tcp 80
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "firewall-cmd --permanent --remove-port=80/tcp" "close_port firewalld: --remove-port"
assert_contains "$calls" "firewall-cmd --reload" "close_port firewalld: --reload"

# --- 4d) ufw: delete allow ---
reset_mocks
CB_FW_BACKEND="ufw"
make_mock "ufw" ""
cb_firewall_close_port tcp 443
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "ufw delete allow 443/tcp" "close_port ufw: delete allow"

# --- 4e) docker/none: nothing ---
reset_mocks
CB_FW_BACKEND="docker"
cb_firewall_close_port tcp 80
assert_eq "" "$(cat "$MOCK_LOG")" "close_port docker: no action"

# ============================================================================
# 5) cb_firewall_redirect_80_to
# ============================================================================
t_info "=== cb_firewall_redirect_80_to ==="

# --- 5a) nftables: nat table + redirect + _cb_nft_ensure_input_accept ---
reset_mocks
CB_FW_BACKEND="nftables"
cat > "$MOCK/nft" <<MOCKEOF
#!/bin/bash
echo "nft \$*" >> "$MOCK_LOG"
case "\$*" in
    "list chain ip nat prerouting")
        # Chain does not exist -> exit 1 -> create
        exit 1
        ;;
    *"list ruleset"*)
        echo "table inet filter { chain input { } }"
        ;;
    *"list chain"*)
        # For _cb_nft_ensure_input_accept - check if chain exists
        echo "chain input { }"
        exit 0
        ;;
    *) exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK/nft"
cb_firewall_redirect_80_to 8080
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "add table ip nat" "redirect nft: nat table created"
assert_contains "$calls" "add chain ip nat prerouting" "redirect nft: prerouting chain created"
assert_contains "$calls" "add rule ip nat prerouting tcp dport 80 redirect to :8080" "redirect nft: redirect rule"
# _cb_nft_ensure_input_accept should add accept for target port
assert_contains "$calls" "insert rule" "redirect nft: _cb_nft_ensure_input_accept called"
assert_contains "$calls" "8080" "redirect nft: target port 8080 in accept rule"

# --- 5b) iptables: nat PREROUTING + input accept ---
reset_mocks
CB_FW_BACKEND="iptables-legacy"
cat > "$MOCK/iptables" <<MOCKEOF
#!/bin/bash
echo "iptables \$*" >> "$MOCK_LOG"
# -C (check) -> rule does not exist
if [[ "\$1" == "-C" ]] || [[ "\$2" == "-C" ]]; then exit 1; fi
exit 0
MOCKEOF
chmod +x "$MOCK/iptables"
cb_firewall_redirect_80_to 8080
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "-t nat" "redirect iptables: nat table"
assert_contains "$calls" "PREROUTING" "redirect iptables: PREROUTING chain"
assert_contains "$calls" "REDIRECT" "redirect iptables: REDIRECT target"
assert_contains "$calls" "--to-port 8080" "redirect iptables: --to-port 8080"
assert_contains "$calls" "-I INPUT" "redirect iptables: input accept rule"
assert_contains "$calls" "certberus-redirect" "redirect iptables: comment"

# --- 5c) docker/none: returns error ---
reset_mocks
CB_FW_BACKEND="docker"
if cb_firewall_redirect_80_to 8080 2>/dev/null; then
    t_fail "redirect docker: should return non-zero exit code"
else
    t_pass "redirect docker: correctly returns error (unsupported)"
fi

# --- 5d) nftables: default port (without argument should be 8080) ---
reset_mocks
CB_FW_BACKEND="nftables"
cat > "$MOCK/nft" <<MOCKEOF
#!/bin/bash
echo "nft \$*" >> "$MOCK_LOG"
case "\$*" in
    "list chain ip nat prerouting") exit 0 ;;
    *"list chain ip nat prerouting"*) echo "tcp dport 80 redirect to :9999" ;;
    *"list ruleset"*) echo "table inet filter { chain input { tcp dport 8080 accept } }" ;;
    *"list chain"*) echo "chain input { }"; exit 0 ;;
    *) exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK/nft"
cb_firewall_redirect_80_to
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "redirect to :8080" "redirect nft: default port 8080"

# ============================================================================
# 6) cb_firewall_snapshot
# ============================================================================
t_info "=== cb_firewall_snapshot ==="

# --- 6a) nftables: nft list ruleset + file ---
reset_mocks
CB_FW_BACKEND="nftables"
cat > "$MOCK/nft" <<MOCKEOF
#!/bin/bash
echo "nft \$*" >> "$MOCK_LOG"
echo "table inet filter { chain input { type filter hook input priority 0; } }"
exit 0
MOCKEOF
chmod +x "$MOCK/nft"
snap_dir=$(cb_firewall_snapshot)
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "nft list ruleset" "snapshot nft: called nft list ruleset"
assert_file_exists "$snap_dir/nftables.conf" "snapshot nft: file nftables.conf created"
# Verify content
snap_content=$(cat "$snap_dir/nftables.conf")
assert_contains "$snap_content" "table inet filter" "snapshot nft: file content"

# --- 6b) iptables: iptables-save ---
reset_mocks
CB_FW_BACKEND="iptables-legacy"
cat > "$MOCK/iptables-save" <<MOCKEOF
#!/bin/bash
echo "iptables-save \$*" >> "$MOCK_LOG"
echo "*filter"
echo "-A INPUT -p tcp --dport 80 -j ACCEPT"
echo "COMMIT"
MOCKEOF
chmod +x "$MOCK/iptables-save"
cat > "$MOCK/ip6tables-save" <<MOCKEOF
#!/bin/bash
echo "ip6tables-save \$*" >> "$MOCK_LOG"
echo "*filter"
echo "COMMIT"
MOCKEOF
chmod +x "$MOCK/ip6tables-save"
snap_dir=$(cb_firewall_snapshot)
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "iptables-save" "snapshot iptables: called iptables-save"
assert_contains "$calls" "ip6tables-save" "snapshot iptables: called ip6tables-save"
assert_file_exists "$snap_dir/iptables.rules" "snapshot iptables: file iptables.rules"
assert_file_exists "$snap_dir/ip6tables.rules" "snapshot iptables: file ip6tables.rules"

# --- 6c) firewalld: firewall-cmd --list-all-zones ---
reset_mocks
CB_FW_BACKEND="firewalld"
cat > "$MOCK/firewall-cmd" <<MOCKEOF
#!/bin/bash
echo "firewall-cmd \$*" >> "$MOCK_LOG"
echo "public (active)"
echo "  services: ssh http https"
MOCKEOF
chmod +x "$MOCK/firewall-cmd"
snap_dir=$(cb_firewall_snapshot)
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "firewall-cmd --list-all-zones" "snapshot firewalld: --list-all-zones"
assert_file_exists "$snap_dir/firewalld-zones.txt" "snapshot firewalld: file created"

# --- 6d) ufw: ufw status verbose ---
reset_mocks
CB_FW_BACKEND="ufw"
cat > "$MOCK/ufw" <<MOCKEOF
#!/bin/bash
echo "ufw \$*" >> "$MOCK_LOG"
echo "Status: active"
echo "80/tcp  ALLOW IN  Anywhere"
MOCKEOF
chmod +x "$MOCK/ufw"
snap_dir=$(cb_firewall_snapshot)
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "ufw status verbose" "snapshot ufw: status verbose"
assert_file_exists "$snap_dir/ufw-status.txt" "snapshot ufw: file created"

# --- 6e) snapshot: variable CB_LAST_FW_SNAPSHOT is set ---
# Call directly (not in subshell) so the variable propagates
reset_mocks
CB_FW_BACKEND="nftables"
cat > "$MOCK/nft" <<MOCKEOF
#!/bin/bash
echo "nft \$*" >> "$MOCK_LOG"
echo "table inet filter { chain input { } }"
exit 0
MOCKEOF
chmod +x "$MOCK/nft"
CB_LAST_FW_SNAPSHOT=""
cb_firewall_snapshot >/dev/null
assert_ne "" "${CB_LAST_FW_SNAPSHOT:-}" "snapshot: CB_LAST_FW_SNAPSHOT set"
assert_match "$CB_LAST_FW_SNAPSHOT" "firewall-" "snapshot: CB_LAST_FW_SNAPSHOT contains prefix"

# ============================================================================
# 7) cb_firewall_ensure_http_https
# ============================================================================
t_info "=== cb_firewall_ensure_http_https ==="

reset_mocks
CB_FW_BACKEND="iptables-legacy"
cat > "$MOCK/iptables" <<MOCKEOF
#!/bin/bash
echo "iptables \$*" >> "$MOCK_LOG"
# -C -> does not exist, let it be inserted
if [[ "\$1" == "-C" ]]; then exit 1; fi
exit 0
MOCKEOF
chmod +x "$MOCK/iptables"
cb_firewall_ensure_http_https
calls=$(cat "$MOCK_LOG")
# Verify both ports are opened
assert_contains "$calls" "--dport 80" "ensure_http_https: port 80"
assert_contains "$calls" "--dport 443" "ensure_http_https: port 443"
assert_contains "$calls" "certberus-http" "ensure_http_https: comment certberus-http"
assert_contains "$calls" "certberus-https" "ensure_http_https: comment certberus-https"

# ============================================================================
# 8) cb_firewall_acme_auto_open_enabled — supplementary tests
# ============================================================================
t_info "=== cb_firewall_acme_auto_open_enabled ==="

# --- 8a) HARICA with global ON but HARICA-specific OFF -> returns 1 ---
export CB_FIREWALL_AUTO_OPEN=1
export CB_CA="harica"
export CB_HARICA_FIREWALL_AUTO_OPEN=0
unset _CB_HARICA_FIREWALL_WARNED 2>/dev/null || true
if cb_firewall_acme_auto_open_enabled; then
    t_fail "acme_auto: HARICA ON + HARICA_FIREWALL=0 should be OFF"
else
    t_pass "acme_auto: HARICA ON + HARICA_FIREWALL=0 -> OFF (correct)"
fi

# --- 8b) HARICA with both ON -> returns 0 ---
export CB_FIREWALL_AUTO_OPEN=1
export CB_CA="harica"
export CB_HARICA_FIREWALL_AUTO_OPEN=1
unset _CB_HARICA_FIREWALL_WARNED 2>/dev/null || true
if cb_firewall_acme_auto_open_enabled; then
    t_pass "acme_auto: HARICA double opt-in -> ON"
else
    t_fail "acme_auto: HARICA double opt-in should be ON"
fi

# --- 8c) Other CA (letsencrypt) with ON -> returns 0 ---
export CB_FIREWALL_AUTO_OPEN=1
export CB_CA="letsencrypt"
unset _CB_HARICA_FIREWALL_WARNED 2>/dev/null || true
if cb_firewall_acme_auto_open_enabled; then
    t_pass "acme_auto: letsencrypt + AUTO_OPEN=1 -> ON"
else
    t_fail "acme_auto: letsencrypt + AUTO_OPEN=1 should be ON"
fi

# --- 8d) Without CB_CA and with ON -> returns 0 ---
export CB_FIREWALL_AUTO_OPEN=1
unset CB_CA 2>/dev/null || true
export CB_CA=""
unset _CB_HARICA_FIREWALL_WARNED 2>/dev/null || true
if cb_firewall_acme_auto_open_enabled; then
    t_pass "acme_auto: no CA + AUTO_OPEN=1 -> ON"
else
    t_fail "acme_auto: no CA + AUTO_OPEN=1 should be ON"
fi

# --- 8e) Default off ---
export CB_FIREWALL_AUTO_OPEN=0
unset CB_CA 2>/dev/null || true
if cb_firewall_acme_auto_open_enabled; then
    t_fail "acme_auto: default OFF not respected"
else
    t_pass "acme_auto: default OFF"
fi

# ============================================================================
# 9) cb_firewall_open_port — firewalld backend
# ============================================================================
t_info "=== cb_firewall_open_port firewalld ==="

reset_mocks
CB_FW_BACKEND="firewalld"
make_mock "firewall-cmd" ""
cb_firewall_open_port tcp 443 "certberus-https"
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "firewall-cmd --permanent --add-port=443/tcp" "open_port firewalld: --add-port"
assert_contains "$calls" "firewall-cmd --reload" "open_port firewalld: --reload"

# ============================================================================
# 10) cb_firewall_open_port — ufw backend
# ============================================================================
t_info "=== cb_firewall_open_port ufw ==="

reset_mocks
CB_FW_BACKEND="ufw"
make_mock "ufw" ""
cb_firewall_open_port tcp 80
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "ufw allow 80/tcp" "open_port ufw: allow port/proto"

# ============================================================================
# 11) Additional edge-case: firewalld redirect
# ============================================================================
t_info "=== cb_firewall_redirect_80_to firewalld ==="

reset_mocks
CB_FW_BACKEND="firewalld"
make_mock "firewall-cmd" ""
cb_firewall_redirect_80_to 8443
calls=$(cat "$MOCK_LOG")
assert_contains "$calls" "--add-forward-port=port=80:proto=tcp:toport=8443" \
    "redirect firewalld: forward-port rule"
assert_contains "$calls" "--add-port=8443/tcp" \
    "redirect firewalld: accept target port"
assert_contains "$calls" "--reload" "redirect firewalld: reload"

# ============================================================================
# 12) cb_firewall_port_open_to_world — reachability inspection
#     (no network probe, no domain needed — pure ruleset inspection)
# ============================================================================
t_info "=== cb_firewall_port_open_to_world ==="

# Mock iptables-save with an arbitrary multi-line ruleset.
mock_iptables_save() {
    {
        echo '#!/bin/bash'
        echo "cat <<'RULES'"
        printf '%s\n' "$1"
        echo 'RULES'
    } > "$MOCK/iptables-save"
    chmod +x "$MOCK/iptables-save"
}

reset_mocks; CB_FW_BACKEND="iptables-nft"
mock_iptables_save '*filter
:INPUT DROP [0:0]
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -s 10.0.0.0/8 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A SUBCHAIN -i lo -j ACCEPT
COMMIT'
assert_eq "closed" "$(cb_firewall_port_open_to_world tcp 80)" \
    "iptables DROP policy, only restricted accepts -> closed"

reset_mocks; CB_FW_BACKEND="iptables-nft"
mock_iptables_save '*filter
:INPUT DROP [0:0]
-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
COMMIT'
assert_eq "open" "$(cb_firewall_port_open_to_world tcp 80)" \
    "iptables explicit --dport 80 ACCEPT -> open"

reset_mocks; CB_FW_BACKEND="iptables-nft"
mock_iptables_save '*filter
:INPUT ACCEPT [0:0]
COMMIT'
assert_eq "open" "$(cb_firewall_port_open_to_world tcp 80)" \
    "iptables default-ACCEPT policy -> open"

reset_mocks; CB_FW_BACKEND="iptables-nft"
mock_iptables_save '*filter
:INPUT DROP [0:0]
-A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
COMMIT'
assert_eq "open" "$(cb_firewall_port_open_to_world tcp 80)" \
    "iptables multiport incl. 80 -> open"

reset_mocks; CB_FW_BACKEND="iptables-nft"
make_mock "iptables-save" "" 1
assert_eq "unknown" "$(cb_firewall_port_open_to_world tcp 80)" \
    "iptables-save failure -> unknown (never a false 'closed')"

reset_mocks; CB_FW_BACKEND="firewalld"
make_mock "firewall-cmd" "" 0
assert_eq "open" "$(cb_firewall_port_open_to_world tcp 80)" \
    "firewalld query-port success -> open"

reset_mocks; CB_FW_BACKEND="firewalld"
make_mock "firewall-cmd" "" 1
assert_eq "closed" "$(cb_firewall_port_open_to_world tcp 80)" \
    "firewalld query-port fail -> closed"

reset_mocks; CB_FW_BACKEND="ufw"
make_mock "ufw" "Status: active
80/tcp                     ALLOW       Anywhere"
assert_eq "open" "$(cb_firewall_port_open_to_world tcp 80)" \
    "ufw 80/tcp ALLOW -> open"

reset_mocks; CB_FW_BACKEND="ufw"
make_mock "ufw" "Status: active
22/tcp                     ALLOW       Anywhere"
assert_eq "closed" "$(cb_firewall_port_open_to_world tcp 80)" \
    "ufw without 80/tcp -> closed"

reset_mocks; CB_FW_BACKEND="none"
assert_eq "open" "$(cb_firewall_port_open_to_world tcp 80)" \
    "backend none -> open (nothing in the way)"

reset_mocks; CB_FW_BACKEND="docker"
assert_eq "unknown" "$(cb_firewall_port_open_to_world tcp 80)" \
    "backend docker -> unknown (host-managed)"

# ============================================================================
# Summary
# ============================================================================
t_summary
