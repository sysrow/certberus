#!/bin/bash
# build/rpm.sh - runs INSIDE rockylinux:8 container (noarch => installable on EL9+ too)
# Env: VERSION, /src (ro), /dist (rw)
set -euo pipefail

VERSION="${VERSION:?VERSION env is not set}"
SRC="/src"
OUT="/dist"

dnf install -q -y rpm-build >/dev/null 2>&1 || yum install -q -y rpm-build >/dev/null

# Rpm build tree
TOP="$(mktemp -d)"
trap "rm -rf '$TOP'" EXIT
mkdir -p "$TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}

# Pripravime tarball jako SOURCE
STAGE="$TOP/stage/certberus-$VERSION"
mkdir -p "$STAGE"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/webservers" "$SRC/config" "$SRC/hooks" "$STAGE/"
cp "$SRC/install.sh" "$STAGE/" 2>/dev/null || true
cp "$SRC/README.md"  "$STAGE/" 2>/dev/null || true
tar --owner=0 --group=0 --numeric-owner \
    --sort=name --mtime='2024-01-01 00:00:00 UTC' \
    -czf "$TOP/SOURCES/certberus-$VERSION.tar.gz" \
    -C "$TOP/stage" "certberus-$VERSION"

# SPEC
cat > "$TOP/SPECS/certberus.spec" <<SPEC
Name:           certberus
Version:        $VERSION
Release:        1%{?dist}
Summary:        Unified ACME certificate deployment for Apache/nginx/Tomcat
License:        MIT
URL:            https://github.com/Tristram1337/temp
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

Requires:       bash >= 4.0
Requires:       coreutils grep sed gawk openssl curl ca-certificates bind-utils
Recommends:     certbot

%description
certberus is a bash-based orchestrator for issuing and deploying TLS
certificates from Let's Encrypt, HARICA and ZeroSSL on Apache (mod_md),
nginx (certbot) and Tomcat (certbot). It provides preflight validation,
domain discovery, hook scripts and unified logging across distributions.

%prep
%setup -q

%build
# nothing - these are shell scripts

%install
install -d -m 0755 %{buildroot}%{_sbindir}
install -d -m 0755 %{buildroot}%{_prefix}/lib/certberus
install -d -m 0755 %{buildroot}%{_prefix}/lib/certberus/webservers
install -d -m 0755 %{buildroot}%{_datadir}/certberus/config
install -d -m 0755 %{buildroot}%{_datadir}/certberus/hooks
install -d -m 0755 %{buildroot}%{_sysconfdir}/certberus
install -d -m 0755 %{buildroot}%{_sysconfdir}/certberus/hooks
install -d -m 0755 %{buildroot}%{_sysconfdir}/logrotate.d
install -d -m 0755 %{buildroot}%{_localstatedir}/lib/certberus
install -d -m 0755 %{buildroot}%{_localstatedir}/log/certberus
install -d -m 0755 %{buildroot}%{_localstatedir}/cache/certberus

install -m 0755 bin/certberus %{buildroot}%{_sbindir}/certberus
# Fix CB_LIB_DIR lookup (RPM uses /usr/lib, not /usr/local/lib)
sed -i 's|/usr/local/lib/certberus|%{_prefix}/lib/certberus|g' %{buildroot}%{_sbindir}/certberus

for f in common.sh os.sh dns.sh firewall.sh hooks.sh discover.sh preflight.sh scan.sh; do
    install -m 0644 lib/\$f %{buildroot}%{_prefix}/lib/certberus/\$f
done

for f in apache-md.sh apache-md-eab.sh nginx-certbot.sh tomcat-certbot.sh; do
    install -m 0755 webservers/\$f %{buildroot}%{_prefix}/lib/certberus/webservers/\$f
done

install -m 0644 config/config.env.example   %{buildroot}%{_datadir}/certberus/config/
install -m 0644 config/advanced.env.example %{buildroot}%{_datadir}/certberus/config/

cp -R hooks/examples %{buildroot}%{_datadir}/certberus/hooks/
install -m 0644 hooks/README.md %{buildroot}%{_datadir}/certberus/hooks/README.md

# Logrotate
cat > %{buildroot}%{_sysconfdir}/logrotate.d/certberus <<'LOGR'
/var/log/certberus/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
LOGR

# Initial config files (noreplace)
install -m 0640 config/config.env.example   %{buildroot}%{_sysconfdir}/certberus/config.env
install -m 0640 config/advanced.env.example %{buildroot}%{_sysconfdir}/certberus/advanced.env

%post
# Event hook dirs
for ev in pre-install post-install pre-snapshot post-snapshot \\
          pre-issue post-issue pre-deploy post-deploy \\
          pre-reload post-reload on-failure on-rollback \\
          renewing renewed installed expiring errored \\
          ocsp-renewed ocsp-errored challenge-setup; do
    mkdir -p /etc/certberus/hooks/\$ev.d
    chmod 0755 /etc/certberus/hooks/\$ev.d
done
[ -f /etc/certberus/hooks/README.md ] || \\
    cp /usr/share/certberus/hooks/README.md /etc/certberus/hooks/README.md 2>/dev/null || true
[ -L /etc/certberus/hooks/examples ] || \\
    ln -sfn /usr/share/certberus/hooks/examples /etc/certberus/hooks/examples

%postun
if [ \$1 -eq 0 ]; then
    # uninstall (nikoli upgrade)
    rm -rf /var/log/certberus /var/lib/certberus /var/cache/certberus 2>/dev/null || true
    # /etc/certberus zachovame (user config)
fi

%files
%defattr(-,root,root,-)
%{_sbindir}/certberus
%dir %{_prefix}/lib/certberus
%dir %{_prefix}/lib/certberus/webservers
%{_prefix}/lib/certberus/*.sh
%{_prefix}/lib/certberus/webservers/*.sh
%{_datadir}/certberus
%config(noreplace) %{_sysconfdir}/certberus/config.env
%config(noreplace) %{_sysconfdir}/certberus/advanced.env
%config(noreplace) %{_sysconfdir}/logrotate.d/certberus
%dir %{_sysconfdir}/certberus
%dir %{_sysconfdir}/certberus/hooks
%dir %{_localstatedir}/lib/certberus
%dir %{_localstatedir}/log/certberus
%dir %{_localstatedir}/cache/certberus

%changelog
* $(LC_ALL=C date '+%a %b %d %Y') certberus maintainers <root@localhost> - $VERSION-1
- Release $VERSION
SPEC

# Build
rpmbuild --define "_topdir $TOP" -bb "$TOP/SPECS/certberus.spec"

# Copy to /dist
cp "$TOP/RPMS/noarch/certberus-${VERSION}-1."*.noarch.rpm "$OUT/certberus-${VERSION}-1.noarch.rpm"

# Lint
rpm -qpi "$OUT/certberus-${VERSION}-1.noarch.rpm" | sed -n '1,20p'
echo "--- Contents (first 20) ---"
rpm -qpl "$OUT/certberus-${VERSION}-1.noarch.rpm" | sed -n '1,20p'

echo "[OK] .rpm built"
