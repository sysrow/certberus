#!/bin/bash
# tests/unit/test-firewall-default.sh
# v0.1.5 regression: cb_firewall_acme_auto_open_enabled is default OFF.
# Real-world: example.com - certberus was silent and inserted iptables ACCEPT
# rules, overriding the managed firewall (ZCU policy). Firewall must be opt-in.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

t_stub_log_helpers
# shellcheck disable=SC1091
source "$CB_REPO_ROOT/lib/firewall.sh"

# Test 1: no env -> false
unset CB_FIREWALL_AUTO_OPEN _CB_HARICA_FIREWALL_WARNED CB_HARICA_FIREWALL_AUTO_OPEN CB_CA
if cb_firewall_acme_auto_open_enabled; then
    t_fail "default: firewall MUST NOT be enabled (regression from example.com)"
else
    t_pass "default OFF (firewall opt-in)"
fi

# Test 2: explicitly =1 -> true
CB_FIREWALL_AUTO_OPEN=1
if cb_firewall_acme_auto_open_enabled; then t_pass "CB_FIREWALL_AUTO_OPEN=1 -> ON"
else t_fail "CB_FIREWALL_AUTO_OPEN=1 did not enable"; fi

# Test 3: =0 -> false
CB_FIREWALL_AUTO_OPEN=0
if cb_firewall_acme_auto_open_enabled; then t_fail "=0 should stay OFF"
else t_pass "CB_FIREWALL_AUTO_OPEN=0 -> OFF"; fi

# Test 4: HARICA single opt-in -> false (HARICA requires double opt-in)
CB_FIREWALL_AUTO_OPEN=1
CB_CA="harica"
CB_HARICA_FIREWALL_AUTO_OPEN=0
unset _CB_HARICA_FIREWALL_WARNED
if cb_firewall_acme_auto_open_enabled; then
    t_fail "HARICA single opt-in must not open firewall"
else
    t_pass "HARICA without CB_HARICA_FIREWALL_AUTO_OPEN=1 -> OFF"
fi

# Test 5: HARICA double opt-in -> true
CB_HARICA_FIREWALL_AUTO_OPEN=1
unset _CB_HARICA_FIREWALL_WARNED
if cb_firewall_acme_auto_open_enabled; then t_pass "HARICA double opt-in -> ON"
else t_fail "HARICA double opt-in did not enable"; fi

t_summary
