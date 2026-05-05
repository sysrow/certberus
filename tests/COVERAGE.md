# Certberus Test Coverage Roadmap

## Current coverage

- CLI smoke: commands, parser edge cases, `--set`, basic read-only commands.
- Discovery: mocked certbot, mocked DNS, auto/force paths.
- Apache: Docker matrix across Debian/Ubuntu with broken vhosts, MDomain collisions, rollback, non-systemd, filesystem oddities.
- nginx: Docker regression matrix for baseline failures, placeholder certs, certbot false success, deploy hook, CLI webroot forwarding.
- Tomcat: Docker matrix for Tomcat 10 detection, server.xml failures, port-80 strategies, deploy hooks, certbot failure propagation.
- Chaos: certificate lifecycle, filesystem, concurrency, clock, hooks, network, security.

## Known gaps to close next

- Real ACME staging against a controlled `*.skyrow.cz` host with a short-lived containerized HTTP-01 responder.
- Renewal path with real `certbot renew --deploy-hook` execution for nginx and Tomcat, not only issue-time setup.
- Apache mod_md event simulation for `renewing`, `renewed`, `errored`, and `challenge-setup` with generated `MDMessageCMD`.
- Full rollback restore verification after a deliberately failed reload for nginx, Apache, and Tomcat in the same matrix shape.
- HTTP-01 webroot reachability from outside the container or from a sibling container that behaves like the CA validator.
- Multi-domain SAN transitions: add domain, remove domain, CA switch, existing separate cert collision.
- Permission model: non-root dry-run, root issue, locked-down `/etc/letsencrypt`, group-readable Tomcat SSL dir.
- Config precedence: CLI > environment > config.env > advanced.env > defaults, for every public `CB_*` setting used by modules.
- CI performance: mock certbot for non-network tests and keep real network timeouts only in `test-network-chaos.sh`.

## Live DNS policy

`*.skyrow.cz` can be used for opt-in live DNS/ACME smoke tests. Tests that depend on public DNS or ACME must skip cleanly when the network is unavailable and must use unique subdomains such as `certberus-live-$RANDOM-$(date +%s).skyrow.cz`.
