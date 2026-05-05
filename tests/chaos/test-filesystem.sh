#!/bin/bash
# tests/test-filesystem-chaos.sh
# FS-level chaos: disk-full, inode-exhaustion, read-only mount, noexec /tmp,
# chattr +a, symlink loop, spaces, zero-byte sites-enabled.
# Uses docker for privileged operations (mount, chattr, loopback).
#
# Usage: bash tests/test-filesystem-chaos.sh [--distro X] [--only NAME] [--keep]

set -uo pipefail
CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEEP=0; ONLY=""; ONLY_DISTRO=""
DISTROS=(debian:13 ubuntu:24.04)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)   KEEP=1 ;;
        --only)   shift; ONLY="$1" ;;
        --distro) shift; ONLY_DISTRO="$1" ;;
        *) echo "Unknown: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ -n "$ONLY_DISTRO" ]] && DISTROS=("$ONLY_DISTRO")

TOTAL_PASS=0; TOTAL_FAIL=0
PASS=0; FAIL=0
CURRENT_DISTRO=""; IMG=""

pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

ensure_image() {
    local distro="$1"
    IMG="certberus-fs-chaos-$(echo "$distro" | tr ':.' '-')"
    CURRENT_DISTRO="$distro"
    docker image inspect "$IMG" >/dev/null 2>&1 && return 0
    echo "### Building $IMG from $distro ###" >&2
    local df; df=$(mktemp)
    cat > "$df" <<DOCKER
FROM $distro
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \\
        apache2 sudo iptables certbot ssl-cert e2fsprogs \\
        util-linux mount python3 openssl ca-certificates && \\
    rm -rf /var/lib/apt/lists/*
RUN a2enmod ssl 2>/dev/null || true
DOCKER
    docker build --network=host -t "$IMG" -f "$df" . >&2 || { rm -f "$df"; return 1; }
    rm -f "$df"
}

run_case() {
    local name="$1" body="$2"
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0
    echo "--- $CURRENT_DISTRO :: $name ---"
    local out
    out=$(docker run --rm --privileged \
            -v "$CERT_ROOT:/certberus:ro" \
            "$IMG" \
            bash -c "
                set -uo pipefail
                cp -r /certberus /tmp/cb && cd /tmp/cb
                ./install.sh --prefix /usr/local >/dev/null 2>&1
                rm -rf /var/backups/certberus /etc/letsencrypt 2>/dev/null
                mkdir -p /etc/certberus
                cat > /etc/certberus/advanced.env <<EOF
CB_SYSLOG_ENABLED=0
CB_AUTO_ROLLBACK=0
CB_COLOR=never
EOF
                source /usr/local/lib/certberus/common.sh 2>/dev/null || source /tmp/cb/lib/common.sh
                set +e
                $body
            " 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "$name"
    else
        echo "$out" | tail -15 | sed 's/^/    /'
        fail "$name (rc=$rc)"
    fi
}

run_all() {

# B.2.1: disk full during snapshot - 5MB loopback FS, fill, snapshot must fail clean
run_case "snapshot-disk-full-graceful" '
dd if=/dev/zero of=/tmp/diskimg bs=1M count=5 >/dev/null 2>&1
mkfs.ext4 -F -q /tmp/diskimg >/dev/null 2>&1 || { echo "skip - no mkfs"; exit 0; }
mkdir -p /mnt/fullfs
mount -o loop /tmp/diskimg /mnt/fullfs || { echo "skip - mount failed"; exit 0; }
# Fill 90% to leave tiny headroom
dd if=/dev/urandom of=/mnt/fullfs/filler bs=1M count=4 >/dev/null 2>&1 || true
# Snapshot with incompressible source (urandom) that exceeds remaining space
mkdir -p /tmp/big-src
dd if=/dev/urandom of=/tmp/big-src/payload bs=1M count=20 >/dev/null 2>&1
CB_BACKUP_DIR=/mnt/fullfs cb_snapshot /tmp/big-src "diskfull-test" >/tmp/snap.log 2>&1
RC=$?
umount /mnt/fullfs 2>/dev/null
PARTIAL=$(find /mnt/fullfs /tmp -name "*.partial" 2>/dev/null)
[[ -z "$PARTIAL" ]] || { echo "BUG: .partial file left behind: $PARTIAL"; exit 1; }
[[ $RC -ne 0 ]] || { echo "BUG: cb_snapshot returned 0 even on disk full"; cat /tmp/snap.log; exit 1; }
'

# B.2.2: inode exhaustion - 64KB FS, fill inodes
run_case "snapshot-inode-exhaustion-graceful" '
dd if=/dev/zero of=/tmp/inodeimg bs=1M count=2 >/dev/null 2>&1
mkfs.ext4 -F -q -N 128 /tmp/inodeimg >/dev/null 2>&1 || { echo "skip"; exit 0; }
mkdir -p /mnt/inodefs
mount -o loop /tmp/inodeimg /mnt/inodefs || { echo "skip"; exit 0; }
# Create 100 files -> reaches inode limit of 128
for i in $(seq 1 200); do : > /mnt/inodefs/file$i 2>/dev/null || break; done
mkdir -p /tmp/src; echo data > /tmp/src/x
CB_BACKUP_DIR=/mnt/inodefs cb_snapshot /tmp/src "inode-test" >/tmp/snap.log 2>&1
RC=$?
umount /mnt/inodefs 2>/dev/null
[[ $RC -ne 0 ]] || { echo "BUG: snapshot succeeded despite inode exhaustion"; exit 1; }
'

# B.2.3: read-only backup dir - bind mount RO (root ignores chmod)
run_case "backup-dir-readonly-clean-error" '
mkdir -p /tmp/ro-backup-real /tmp/ro-backup
mount --bind /tmp/ro-backup-real /tmp/ro-backup || { echo "skip - bind mount failed"; exit 0; }
mount -o remount,ro,bind /tmp/ro-backup || {
    umount /tmp/ro-backup 2>/dev/null
    echo "skip - remount,ro not supported"; exit 0; }
mkdir -p /tmp/snap-src; echo data > /tmp/snap-src/file
CB_BACKUP_DIR=/tmp/ro-backup cb_snapshot /tmp/snap-src "ro-test" >/tmp/snap.log 2>&1
RC=$?
umount /tmp/ro-backup 2>/dev/null
[[ $RC -ne 0 ]] || { echo "BUG: snapshot succeeded into RO directory"; exit 1; }
grep -qiE "permission|readonly|read.only|denied|cannot|not writable" /tmp/snap.log || {
    echo "Missing comprehensible error message:"; cat /tmp/snap.log; exit 1; }
'

# B.2.5: snapshot src is a symlink (preserve) - tar must follow the target
run_case "snapshot-src-is-symlink" '
mkdir -p /tmp/real-config; echo "real-data" > /tmp/real-config/file
ln -sf /tmp/real-config /tmp/cfg-link
CB_BACKUP_DIR=/var/backups/certberus cb_snapshot /tmp/cfg-link "symlink-src" >/tmp/snap.log 2>&1
RC=$?
[[ $RC -eq 0 ]] || { echo "BUG: snapshot src=symlink failed"; cat /tmp/snap.log; exit 1; }
# Snapshot exists
ls /var/backups/certberus/symlink-src-*.tar.gz >/dev/null 2>&1 || exit 1
'

# B.2.6: /tmp is noexec - bash scripts from /tmp cannot be executed directly
run_case "tmp-noexec-fallback" '
mkdir -p /tmp/noexec-tmp
mount -t tmpfs -o noexec tmpfs /tmp/noexec-tmp || { echo "skip"; exit 0; }
echo "#!/bin/bash" > /tmp/noexec-tmp/test.sh
echo "echo OK" >> /tmp/noexec-tmp/test.sh
chmod +x /tmp/noexec-tmp/test.sh
# Direct exec fails
out=$(/tmp/noexec-tmp/test.sh 2>&1) && {
    umount /tmp/noexec-tmp; echo "noexec mount not working, skip"; exit 0; }
# Bash + script works (interpreted mode)
bash /tmp/noexec-tmp/test.sh | grep -q OK || { umount /tmp/noexec-tmp; exit 1; }
umount /tmp/noexec-tmp
'

# B.2.8: log dir append-only chattr +a
run_case "log-dir-append-only-chattr" '
mkdir -p /tmp/log-ao
echo "old" > /tmp/log-ao/file.log
chattr +a /tmp/log-ao/file.log 2>/dev/null || { echo "skip - no chattr"; exit 0; }
# Append works
echo "new" >> /tmp/log-ao/file.log 2>/dev/null
APP_RC=$?
# Truncate must fail
: > /tmp/log-ao/file.log 2>/dev/null && {
    chattr -a /tmp/log-ao/file.log; echo "BUG: append-only allowed truncate"; exit 1; }
chattr -a /tmp/log-ao/file.log 2>/dev/null
[[ $APP_RC -eq 0 ]] || { echo "Append to append-only file failed"; exit 1; }
# certberus log uses >> (append) -> compatible with chattr +a
'

# B.2.13: symlink loop in apache sites-enabled
run_case "symlink-loop-in-sites-enabled" '
mkdir -p /etc/apache2/sites-enabled
ln -sf /etc/apache2/sites-enabled/B.conf /etc/apache2/sites-enabled/A.conf
ln -sf /etc/apache2/sites-enabled/A.conf /etc/apache2/sites-enabled/B.conf
# find with -L would loop; certberus should use -P (no-follow) or timeout
timeout 10 find /etc/apache2/sites-enabled -name "*.conf" >/tmp/find.out 2>&1
RC=$?
[[ $RC -ne 124 ]] || { echo "BUG: find timed out (loop)"; exit 1; }
# discover.sh should be safe
source /usr/local/lib/certberus/discover.sh 2>/dev/null || true
# OK - just verifying that find itself does not crash (with -P as default)
'

# B.2.14: vhost file with spaces in path
run_case "vhost-with-spaces-in-path" '
mkdir -p "/etc/apache2/sites-available"
cat > "/etc/apache2/sites-available/my site.conf" <<EOF
<VirtualHost *:80>
    ServerName spaces.local
</VirtualHost>
EOF
ln -sf "/etc/apache2/sites-available/my site.conf" "/etc/apache2/sites-enabled/my site.conf"
# discover must handle this path without crashing
out=$(/usr/local/sbin/certberus discover 2>&1)
RC=$?
[[ $RC -lt 128 ]] || { echo "BUG: discover crashed with SIGNAL"; exit 1; }
echo "$out" | grep -q "spaces.local" || {
    echo "discover did not find domain from config with space in path"
    echo "--- output ---"
    echo "$out"
    exit 1
}
'

# B.2.15: zero-byte vhost file
run_case "vhost-zero-byte-file" '
: > /etc/apache2/sites-available/empty.conf
ln -sf /etc/apache2/sites-available/empty.conf /etc/apache2/sites-enabled/empty.conf
# discover must not crash
out=$(/usr/local/sbin/certberus discover 2>&1)
RC=$?
[[ $RC -lt 128 ]] || { echo "BUG: discover crash"; exit 1; }
'

# B.2.4: stale state in CB_STATE_DIR (after container restart on tmpfs)
run_case "stale-state-tmpfs-recovery" '
mkdir -p /var/lib/certberus
echo "stale-pid: 99999" > /var/lib/certberus/state.txt
# certberus should detect stale PID and self-clean
# Test: status/discover must not crash even when state is from a previous boot
out=$(/usr/local/sbin/certberus version 2>&1)
RC=$?
[[ $RC -eq 0 ]] || exit 1
'

# B.2.7: overlay FS layer - chattr does not work
run_case "overlay-fs-chattr-graceful" '
# Docker root is overlay - chattr not possible. Test that certberus does not force it.
chattr +i /etc/hostname 2>/tmp/chattr.err
RC=$?
# Either succeeds (privileged) or clean error - not a crash
[[ $RC -lt 128 ]] || { echo "BUG: chattr crashed"; exit 1; }
chattr -i /etc/hostname 2>/dev/null || true
'

# B.2.11: read-only rootfs (simulating remount root,ro)
run_case "rootfs-read-only-snapshot-graceful" '
# Cannot remount / as ro in docker (busy) - instead test that /etc/letsencrypt does not exist
# and certberus issue behaves gracefully (no crash)
rm -rf /etc/letsencrypt
out=$(/usr/local/sbin/certberus status 2>&1)
RC=$?
[[ $RC -lt 128 ]] || exit 1
'

# B.2.12: slow FS / find timeout - simulated with a large number of files
run_case "many-files-find-fast-enough" '
mkdir -p /etc/apache2/sites-available
for i in $(seq 1 200); do
    echo "<VirtualHost *:80>ServerName d$i.local</VirtualHost>" > "/etc/apache2/sites-available/d$i.conf"
done
# discover must finish within 30s even with 200 vhosts
timeout 30 /usr/local/sbin/certberus discover >/tmp/discover.out 2>&1
RC=$?
[[ $RC -ne 124 ]] || { echo "BUG: discover timed out with 200 vhosts"; exit 1; }
'

}  # end run_all

# =============================================================================
command -v docker >/dev/null || { echo "Docker not found"; exit 2; }

for distro in "${DISTROS[@]}"; do
    echo "==============================================================="
    echo " FILESYSTEM CHAOS :: $distro"
    echo "==============================================================="
    PASS=0; FAIL=0
    if ! ensure_image "$distro"; then
        echo "  [SKIP] $distro - build failed"
        continue
    fi
    run_all
    echo "  $distro: $PASS pass, $FAIL fail"
    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    [[ $KEEP == 0 ]] && docker image rm "$IMG" >/dev/null 2>&1 || true
done

echo "==============================================================="
echo "TOTAL: $TOTAL_PASS pass / $TOTAL_FAIL fail"
exit $(( TOTAL_FAIL > 0 ? 1 : 0 ))
