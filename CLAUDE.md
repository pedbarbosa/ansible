# ansible

Personal Ansible config for provisioning/configuring machines: an Ubuntu
server/workstation setup and a macOS workstation setup, one repo, run via
`./run.sh`. See README.md for the full layout description.

## Secrets

- `local/` holds every not-committed-but-critical config file: real
  secrets and router-only config bodies. Nothing an assistant creates
  should ever be written into it except by copying a `.example` file.
- `local/secrets.yml` is gitignored and must never be created or committed
  by an assistant — it holds real host/user-specific values (hostnames,
  webhook URLs, mount paths, etc).
- `local/secrets.yml.example` is the canonical list of every expected key.
  Each entry is commented with the playbook/file(s) that consume it. When a
  change introduces a new secret-derived variable, update this file too.
- For `ubuntu`/`mac`, vars sourced from secrets are only available in plays
  that explicitly run an `include_vars: ../local/secrets.yml` task —
  group_vars files can reference them (e.g. `is_corporate` in
  `mac/group_vars/all.yml` depends on `personal_hostnames` from secrets),
  but the value only resolves in plays that load secrets first, due to
  Ansible's lazy variable evaluation.
- `openwrt` is the exception: `openwrt/group_vars/all/secrets.yml` is a
  symlink to `../../../local/secrets.yml`, so it's auto-loaded by Ansible's
  normal group_vars mechanism for every host in the play — no
  `include_vars` task needed in any `openwrt/*.yml` playbook. This only
  works because every `openwrt` play lives in a file under `openwrt/`,
  which is what fixes the group_vars lookup's base directory to
  `openwrt/group_vars/`.
- Exception: connection vars like `ansible_host` are needed *before* Ansible
  can reach a host, so they can't wait on a play-level var (`include_vars`
  or group_vars) to resolve inside the play that targets it — see
  `openwrt/inventory.yml`'s `add_host` bootstrap below for the pattern used
  when secret data has to become inventory, not just task-level vars.

## Dry-run convention

`run.sh` always runs `ansible-playbook -CD <playbook>.yml` (check + diff)
first and prints a reminder to re-run with `-v` to apply. Keep this
"preview by default" behavior in mind when adding tasks:

- `ansible.builtin.command`/`shell`/`uri` tasks are **skipped** under `-C`
  check mode unless `check_mode: false` is set. This repo already forces a
  few tasks to always run (the `uri` release lookups in `ubuntu/pms.yml`,
  the `packaging` bootstrap in `mac/default.yml`) because later tasks in
  the same play depend on their result to evaluate correctly in check
  mode. Forcing a task like this means it has real side effects even
  during a dry run — only do it for idempotent, non-destructive
  bootstrapping.
  - Referencing a **top-level** field on a skipped task's registered
    result (e.g. `some_command_result.stdout`) is tolerated — Jinja's
    Undefined compares without raising, so `when: x.stdout != "foo"`
    just evaluates true. But **chained/nested** attribute access on a
    skipped `uri` result (e.g. `some_uri_result.json.assets`) raises
    `'dict object' has no attribute ...` immediately, because `.json`
    itself is Undefined and `|selectattr`/further attribute access on
    it isn't tolerated the way a bare comparison is. This is why the
    `uri` release-lookup tasks need `check_mode: false` but the
    `dpkg-query` version-check `command` tasks don't.
  - `get_url` is different again: it already **supports** check mode, so
    it is not skipped — it _simulates_ (reports `changed` without
    writing the file). A later task in the same play that needs the
    real file on disk (e.g. `apt: deb=...` reading the downloaded
    `.deb`) will fail with a missing-file error unless the `get_url`
    task is also forced with `check_mode: false` so the download
    actually happens.

## Agent execution constraints

- Never run `ansible-playbook` yourself — not even a check-mode/dry-run
  (`-C`/`-CD`, `run.sh`'s default). The router and APs aren't reachable from
  this environment, so any invocation just fails or hangs; it also isn't
  your call to make against live network gear. Prepare/edit the playbooks
  and templates, then hand off the exact command for the user to run on a
  host that actually has access.

## Shared files across mac/ubuntu

- When a file is identical (or near-identical) between `mac/` and `ubuntu/`
  playbooks — e.g. `vimrc`, `zshrc.j2` — the canonical copy lives in the
  top-level `files/` directory, not duplicated under `mac/files/` and
  `ubuntu/files/`.
- Reference it with `src: "{{ playbook_dir }}/../files/<name>"`. A plain
  relative `src: files/<name>` resolves against *that play's own*
  `<os>/files/` directory, not the repo-root `files/` — it silently looks
  in the wrong place (or 404s) without the `playbook_dir` prefix.
- If the shared file needs a handful of OS-specific lines (see the
  Mac-only blocks in `files/zshrc.j2`), gate them with a boolean group var
  defined per-OS (e.g. `zsh_is_mac: true`/`false` in
  `mac/group_vars/all.yml` / `ubuntu/group_vars/all.yml`) rather than
  forking the file back into two copies.
- Don't force this pattern onto files that only *look* similar —
  `default.yml`/`python.yml`/`ruby.yml` exist in both `mac/` and `ubuntu/`
  but were deliberately kept separate: different `hosts`/`become` model,
  different package manager (`package` vs `apt`), and mostly
  non-overlapping tasks (ubuntu's is server-hardening, mac's is desktop
  tooling). Merging those would mean threading OS conditionals through
  nearly every task for two playbooks that are conceptually different,
  not the same thing expressed twice.

## OpenWrt playbooks (`openwrt.yml` / `openwrt/`)

- No committed inventory file — `openwrt/inventory.yml` runs first (against
  `localhost`), reads `openwrt_router_host`/`openwrt_ap_hosts` from
  `local/secrets.yml` (auto-loaded, see `## Secrets` above — no
  `include_vars` needed even here), and `add_host`s the router + APs into
  the `openwrt`/`router`/`ap` groups at runtime. This keeps real
  IPs/hostnames out of the repo without a second gitignored file alongside
  `local/secrets.yml`. `group_vars`
  (`all/`, `router.yml`) still apply normally to hosts added this way.
  - The router's registered hostname is `gateway`, not `router` — Ansible
    warns ("Found both group and host with same name") if a host is added
    to a group sharing its exact name. The `router` *group* name stays as
    is since `group_vars/router.yml` and the `'router' in group_names`
    checks depend on it; only the host's own name needed to change to
    avoid the collision. The AP host names (from `openwrt_ap_hosts[].name`
    in secrets, e.g. `ap-upstairs`) don't collide with the `ap` group name,
    so they're unaffected.
- `openwrt/default.yml` runs an explicit `apk update` as a `pre_task`,
  before the `community.openwrt.init` role. This repo now targets OpenWrt
  25.x, which replaced `opkg` with `apk` — the role detects whichever
  package manager is present (`roles/init/tasks/main.yml` in
  `community.openwrt`) and, on `apk`, its recommended-packages step
  (`packages-apk.yml`, installing `coreutils-base64`/`-md5sum`/`-sha1sum`
  compat shims when `openssl` is missing) does *no* cache-freshness check
  of its own — unlike the old `opkg` path, which had its own (buggy)
  staleness check that could swallow a failed refresh and fail later with a
  confusing "Unknown package" instead of the real cause. Under `apk` the
  explicit `pre_task` is the only thing ensuring the index is fresh before
  that role step runs, so don't drop it thinking the role has it covered.
- `community.openwrt` requires `ansible-core>=2.18` (see its
  `meta/runtime.yml`) — an older `ansible-core` (e.g. some distros' `apt
  install ansible` package) prints a "does not support Ansible version"
  warning but has so far still run correctly; see README for the upgrade
  command if something actually breaks.
- Uses the `community.openwrt` collection (declared in `requirements.yml`), not
  `ansible.builtin`/`community.general` modules — it's shell-based
  (`community.openwrt.apk`/`uci`/`service`/`file`/`command`, etc.) so it
  works without Python installed on the router/APs.
- This is the repo's first external collection, so nothing else here does
  `ansible-galaxy collection install` — `run.sh` only bootstraps ansible
  itself plus SSH/sudoers for the ubuntu.yml/mac.yml localhost targets, and
  deliberately doesn't touch openwrt.yml (the router/APs aren't the machine
  running Ansible). Install `requirements.yml` manually, same one-time step
  as copying `local/secrets.yml.example`.
- When bumping the version pin in `requirements.yml`, check the collection's
  actual GitHub *tags/releases* (or `galaxy.yml` at that tag), not the
  version in its `main` branch's `galaxy.yml` — `main` bumps the version
  ahead of what's published to Galaxy, so pinning to it produces an
  unsatisfiable `ansible-galaxy collection install` requirement.
- Check-mode support varies per module, same "force `check_mode: false` only
  for idempotent bootstrapping" rule as the mac/ubuntu gotcha above:
  `community.openwrt.apk`, `service`, and `file` support check mode fully
  and are left alone; `community.openwrt.command` does not (`check_mode:
  support: none`) and is skipped under `-C` unless forced. `openwrt/default.yml`
  no longer has any `command` tasks — the old `wget`-based `opkg-upgrade`
  bootstrap and its `-f` upgrade step were removed when this repo moved to
  `apk` (OpenWrt 25.x): `apk` has a native `apk upgrade`, but OpenWrt's own
  docs warn against using it for full-system upgrades (it can miss
  dependency/priority handling that Attended Sysupgrade does correctly), so
  there's deliberately no upgrade-all step here — full-system upgrades are
  left to ASU/sysupgrade tooling.
- `community.openwrt.apk`'s `name` argument is `type: str` only (no list
  support like `ansible.builtin.apt`/`package`) — package lists in
  `group_vars` are real YAML lists and get `| join(',')` at the point of use.
- `openwrt/collectd.yml` pushes a single `/etc/config/collectd` rendered from
  `openwrt/files/collectd.conf` via `community.openwrt.template`, rather than
  one `community.openwrt.uci` task per option — same reasoning as the
  mac/ubuntu playbooks' use of `template` over many individual edits: one
  task, a readable whole-file diff under `-D`, and full check-mode support.
  Which plugins render (`conntrack`/`dns`/`thermal` are router-only) is
  driven by `openwrt_collectd_plugins` in `group_vars`, mirroring the
  `openwrt_packages_common`/`openwrt_packages_router` split above — keep
  both splits in sync (a collectd plugin needs its `collectd-mod-*` package
  installed by `openwrt/default.yml` first). The collectd server address
  (`openwrt_collectd_server_host`) lives in `local/secrets.yml`, same as the
  router/AP addresses, since it's also a real network detail.
  `openwrt/files/collectd.conf` itself is kept free of commented-out lines
  (other than the top "file managed" header) since every option in it is
  actually in effect; the stock `collectd-mod-*` package default (all
  plugins disabled, everything else commented out) is kept for reference at
  `openwrt/reference/collectd.conf.upstream-default`, which isn't deployed
  by any playbook.
- `openwrt/system.yml` (`/etc/config/system`) covers hostname, timezone,
  logging, and NTP, all driven by `group_vars` (router vs. AP) same as the
  playbooks above — plus AP-only LED sections, which are genuinely
  per-physical-device rather than per-group. Those are keyed by a `profile`
  field added to each `openwrt_ap_hosts` entry in `local/secrets.yml` (e.g.
  `ap_dual_led`/`ap_wan_led`), which `openwrt/inventory.yml` adds as an
  extra `add_host` group; the actual LED definitions live in a committed
  `openwrt/group_vars/ap_<profile>.yml`. This indirection exists solely so
  real AP names never need to appear in the repo as `host_vars/<name>.yml`
  filenames — adding a new physical AP means adding/reusing a `profile` in
  secrets and, if its hardware is new, a new `ap_<profile>.yml`.
  `timezone`/`zonename` are also secrets (`openwrt_timezone`/
  `openwrt_zonename`) even though they're low-sensitivity, per explicit
  request rather than the IP/hostname reasoning above.
- `openwrt/uhttpd.yml` (`/etc/config/uhttpd`) is a single static template
  (`openwrt/files/uhttpd.conf`, no per-host variables) since the only
  difference across the router/APs was the cert `defaults` section's `days`
  value — and that section is dropped entirely rather than templated, since
  these devices don't generate their own certs; Let's Encrypt certs are
  injected via a separate cron process outside Ansible's management.
- `openwrt/luci.yml` (`/etc/config/luci`) is likewise a single static
  template (`openwrt/files/luci.conf`) — identical across the router and
  both APs, no group/host variation at all. No restart handler: LuCI reads
  this config live per-request rather than via a long-running service.
- `openwrt/dropbear.yml` (`/etc/config/dropbear`) is also a single static
  template (`openwrt/files/dropbear.conf`), identical across all hosts —
  restarts `dropbear` on change, since (unlike LuCI) it's a long-running
  daemon that needs to reload for e.g. a `Port` change to take effect.
- `openwrt/attendedsysupgrade.yml` (`/etc/config/attendedsysupgrade`) is
  likewise a single static template (`openwrt/files/attendedsysupgrade.conf`),
  identical across all hosts. No restart handler: like LuCI, ASU/`owut` only
  run on demand rather than as a long-running daemon.
- `openwrt/adblock.yml` (`/etc/config/adblock`) targets `hosts: router`
  directly (not `openwrt` gated by a `group_names` check) since it's the
  only file so far that doesn't apply to the APs at all. `adb_mailreceiver`/
  `adb_mailsender` are `admin@{{ domain }}`/`router@{{ domain }}`, reusing
  the same `domain` secret as `ubuntu/collectd.yml` rather than adding a
  new one, per explicit request.
- `openwrt/banip.yml` (`/etc/config/banip`) is router-only (same `hosts:
  router` / `domain`-secret reasoning as `openwrt/adblock.yml` above).
- `openwrt/firewall.yml` (`/etc/config/firewall`) is the one file so far
  split by content sensitivity rather than by host group: the AP zones are
  identical/simple enough to commit directly in
  `openwrt/files/firewall.conf` (a `{% if 'router' in group_names %}`
  branch), but the router's actual zones/rules/port-forwards are too
  revealing of the internal network to commit even sanitised — so that
  entire file's content lives verbatim in `local/router-firewall.conf`
  (gitignored, `local/router-firewall.conf.example` has the format), pulled
  in with `{{ lookup('file', '../local/router-firewall.conf') }}` inside
  the `{% if 'router' in group_names %}` branch. It's a plain UCI text file
  rather than a YAML var on purpose, for two reasons: it's a separate
  concern from `local/secrets.yml` (which covers individual private
  *values* —
  IPs, hostnames — plugged into otherwise-committed templates, whereas this
  is a whole config *body* describing the network's structure and exposed
  services), and — the bigger reason — a YAML block scalar forces every
  line to carry both the YAML indent *and* the real UCI tab, which drifted
  out of sync with what LuCI itself writes back to the device (LuCI
  regenerates these files with zero indent on `config` lines and exactly
  one tab on `option`/`list` lines). A flat file holding raw UCI text can
  be copied in from the device (or from LuCI's own output) with no
  translation step, so it can't drift.
- `openwrt/dhcp.yml` (`/etc/config/dhcp`) covers `dnsmasq`/`dhcp`/`odhcpd`
  sections, branched on `'router' in group_names` inside
  `openwrt/files/dhcp.conf` — the router runs the actual DHCP server (`lan`/
  `iot`/`wan` sections, `authoritative`/`sequential_ip`/`nonegcache`) and is
  the only host authorised to answer DNS or DHCP. APs are fully passive:
  `option port '0'` disables dnsmasq's own resolver (it previously marked
  `/lan/` as a strictly-local domain via `option local`, which made it
  NXDOMAIN local hostnames it had no records for instead of forwarding them —
  the router is now the sole DNS answerer), and both `lan` and `iot` sections
  carry `ignore '1'`/`ra 'disabled'`/`dhcpv6 'disabled'` so DHCP for both
  VLANs is fully delegated to the router and IPv6 RA/DHCPv6 stay off
  network-wide (APs no longer run their own independent
  `ra`/`dhcpv6`/`ra_slaac` server as they did before). `domain` is the
  same `domain` secret reused by `openwrt/adblock.yml`/`banip.yml`. Since the
  template neuters both daemons everywhere except the router's dnsmasq,
  `openwrt/dhcp.yml` also disables the now-useless services outright rather
  than leaving do-nothing daemons running: `odhcpd` is stopped and disabled
  unconditionally on every host (IPv6/`maindhcp` are off everywhere, so it
  has nothing left to do anywhere), and `dnsmasq` is stopped and disabled on
  APs specifically (`'router' not in group_names`) — the restart handler for
  `dnsmasq` is likewise gated to `'router' in group_names` only. The template
  also has a `local/router-dhcp-extra.conf` hook
  (read via `lookup('file', ..., errors='ignore')`, so a missing file just
  renders as empty — appended verbatim after `odhcpd` with a blank line
  before it) for the router's `config domain`/`config host` static-lease
  entries — not yet populated, but reserved so they can go straight into
  that file (same reasoning as `local/router-firewall.conf`: real internal
  hostnames, too
  revealing to commit, and plain UCI text so there's no YAML-indentation
  drift against what LuCI writes) without touching the template again.
- `openwrt/network.yml` (`/etc/config/network`) breaks from every other
  OpenWrt playbook's structure: instead of one `group_names`-branched
  template, each device profile gets its own plain file under
  `openwrt/files/` (`network.router.conf`/`network.ap_dual_led.conf`/
  `network.ap_wan_led.conf`, three separate `hosts:` plays targeting the
  `router`/`ap_dual_led`/`ap_wan_led` groups) because the physical
  port/switch layout genuinely differs per hardware model — the
  `ap_dual_led` profile trunks a single `eth0`, `ap_wan_led` repurposes its
  `wan` port into the VLAN trunk, the router fans out across 5 ports — not
  just router-vs-AP the way `dhcp.conf`/`firewall.conf` do. It targets the
  same `ap_dual_led`/`ap_wan_led` profile groups `openwrt/system.yml` uses
  for LEDs, never a specific AP's inventory hostname — that name is
  whatever's set in `local/secrets.yml`'s `openwrt_ap_hosts[].name` and must
  never be hardcoded here. `host` on
  each `openwrt_ap_hosts` entry (and `openwrt_router_host`) now does double
  duty as `ansible_host` *and* the `lan` interface's `ipaddr` in these
  templates, so it must be the device's real static LAN IP, not just
  whatever address ansible happens to reach it on — keep that in sync if
  either ever changes. IPv6 is disabled network-wide via `option ipv6 '0'`
  on every bridge `device` section (the router's `wan` interface disables it
  too, since it's PPPoE not a bridge). No restart handler, unlike every
  other playbook here: a bad bridge/VLAN/IP push can sever SSH/LuCI access
  to the device outright, so this only ever stages the file — apply by
  hand, one device at a time, with console/physical access on standby.

## Gotchas learned the hard way

- **zsh's builtin `printf` is not bash's/coreutils' `printf`.** In zsh,
  `printf "%d" some_bareword` evaluates `some_bareword` as an arithmetic
  expression (so a variable name resolves to its value with no `$`
  needed). This is why `zsh_timer()` in `files/zshrc.j2` can do
  `printf "%02d" zsh_timer_counter` without a `$`. When checking shell
  semantics for `.zshrc`/zsh scripts in this repo, verify against a real
  `zsh -c '...'` invocation — the sandbox's default shell for testing
  commands is bash, and bash/coreutils `printf` behaves differently here.

- **Jinja `and`/`or` in a `when:` don't lazily skip a raising operand.**
  `A or B` evaluates `A` first regardless of whether `B` alone would make
  the condition true; if `A` itself raises (e.g. `x is version(y, '<')`
  when `x` is `""`, which errors with "Input version value cannot be
  empty" rather than just returning false), the whole expression blows
  up before `B` is ever considered. Order the operand that's safe on
  empty/missing input first (`x == "" or x is version(y, '<')`), not
  last, so it actually short-circuits.

## Response style

- Keep answers concise by default — state the change/result directly,
  skip preamble and restating the request. Expand into a fuller
  explanation only when the user asks for one (e.g. "explain", "why",
  "walk me through") or when a decision genuinely needs the user's input
  (e.g. a destructive action, an ambiguous playbook change, secrets
  handling) — those still warrant a full question, not a clipped one.

## Commit/PR style

- One commit per logical fix, not squashed — makes review and future
  `git blame` easier on a repo this size.
- Branches follow `pb/YYYYMMDD_description`.
- PRs are opened against `main` with `gh pr create`.
