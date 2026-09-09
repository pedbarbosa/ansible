# ansible

Personal Ansible config for provisioning/configuring machines: an Ubuntu
server/workstation setup and a macOS workstation setup, one repo, run via
`./run.sh`. See README.md for the full layout description.

## Secrets

- `secrets.yml` is gitignored and must never be created or committed by an
  assistant — it holds real host/user-specific values (hostnames, webhook
  URLs, mount paths, etc).
- `secrets.yml.example` is the canonical list of every expected key. Each
  entry is commented with the playbook/file(s) that consume it. When a
  change introduces a new secret-derived variable, update this file too.
- Vars sourced from secrets are only available in plays that explicitly run
  an `include_vars: ../secrets.yml` task — group_vars files can reference
  them (e.g. `is_corporate` in `mac/group_vars/all.yml` depends on
  `personal_hostnames` from secrets), but the value only resolves in plays
  that load secrets first, due to Ansible's lazy variable evaluation.
- Exception: connection vars like `ansible_host` are needed *before* Ansible
  can reach a host, so they can't wait on an `include_vars` task inside the
  play that targets it — see `openwrt/inventory.yml`'s `add_host` bootstrap
  below for the pattern used when secret data has to become inventory, not
  just task-level vars.

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
  `secrets.yml`, and `add_host`s the router + APs into the `openwrt`/
  `router`/`ap` groups at runtime. This keeps real IPs/hostnames out of the
  repo without a second gitignored file alongside `secrets.yml`. `group_vars`
  (`all.yml`/`router.yml`) still apply normally to hosts added this way.
  - The router's registered hostname is `gateway`, not `router` — Ansible
    warns ("Found both group and host with same name") if a host is added
    to a group sharing its exact name. The `router` *group* name stays as
    is since `group_vars/router.yml` and the `'router' in group_names`
    checks depend on it; only the host's own name needed to change to
    avoid the collision. The AP host names (from `openwrt_ap_hosts[].name`
    in secrets, e.g. `ap-upstairs`) don't collide with the `ap` group name,
    so they're unaffected.
- `openwrt/default.yml` runs an explicit `opkg update` as a `pre_task`,
  before the `community.openwrt.init` role. The role does its own cache
  refresh internally, but only fails the play if the opkg lists directory
  didn't exist yet at all — if the directory exists but the refresh itself
  fails (e.g. a device that's just never had a working `opkg update`), that
  failure is swallowed, leaving a stale/empty cache. The next role step
  (installing `coreutils-base64`/`-md5sum`/`-sha1sum` compat shims when
  `openssl` is missing) then fails with a confusing "Unknown package"
  instead of the real cause. Seen in practice on an AP whose opkg cache had
  never successfully populated; the router was unaffected only because it
  already had `openssl` and skipped that step.
- `community.openwrt` requires `ansible-core>=2.18` (see its
  `meta/runtime.yml`) — an older `ansible-core` (e.g. some distros' `apt
  install ansible` package) prints a "does not support Ansible version"
  warning but has so far still run correctly; see README for the upgrade
  command if something actually breaks.
- Uses the `community.openwrt` collection (declared in `requirements.yml`), not
  `ansible.builtin`/`community.general` modules — it's shell-based
  (`community.openwrt.opkg`/`uci`/`service`/`file`/`command`, etc.) so it
  works without Python installed on the router/APs.
- This is the repo's first external collection, so nothing else here does
  `ansible-galaxy collection install` — `run.sh` only bootstraps ansible
  itself plus SSH/sudoers for the ubuntu.yml/mac.yml localhost targets, and
  deliberately doesn't touch openwrt.yml (the router/APs aren't the machine
  running Ansible). Install `requirements.yml` manually, same one-time step
  as copying `secrets.yml.example`.
- When bumping the version pin in `requirements.yml`, check the collection's
  actual GitHub *tags/releases* (or `galaxy.yml` at that tag), not the
  version in its `main` branch's `galaxy.yml` — `main` bumps the version
  ahead of what's published to Galaxy, so pinning to it produces an
  unsatisfiable `ansible-galaxy collection install` requirement.
- Check-mode support varies per module, same "force `check_mode: false` only
  for idempotent bootstrapping" rule as the mac/ubuntu gotcha above:
  `community.openwrt.opkg`, `service`, and `file` support check mode fully
  and are left alone; `community.openwrt.command` does not (`check_mode:
  support: none`) and is skipped under `-C` unless forced. `openwrt/default.yml`
  forces only the `wget`-based `opkg-upgrade` bootstrap (idempotent via
  `creates:`) — the actual `opkg-upgrade -f` upgrade is left to skip during a
  dry run since it's a real, non-idempotent action.
- `community.openwrt.opkg`'s `name` argument is `type: str` only (no list
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
  (`openwrt_collectd_server_host`) lives in `secrets.yml`, same as the
  router/AP addresses, since it's also a real network detail.
- `openwrt/system.yml` (`/etc/config/system`) covers hostname, timezone,
  logging, and NTP, all driven by `group_vars` (router vs. AP) same as the
  playbooks above — plus AP-only LED sections, which are genuinely
  per-physical-device rather than per-group. Those are keyed by a `profile`
  field added to each `openwrt_ap_hosts` entry in `secrets.yml` (e.g.
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
  entire file's content lives as a single `openwrt_router_firewall_config`
  block-scalar in `router.yaml` (gitignored, `router.yaml.example` has the
  format), read via a `when: "'router' in group_names"`-gated `include_vars`
  task rather than `secrets.yml`. It's a separate file from `secrets.yml`
  on purpose: `secrets.yml` covers individual private *values*
  (IPs, hostnames) plugged into otherwise-committed templates, while
  `router.yaml` covers a whole config *body* that itself describes the
  network's structure and exposed services — different enough in kind, and
  scoped to one host, that mixing it into `secrets.yml` (read by every
  playbook) felt like the wrong place for it.
- `openwrt/irqbalance.yml` (`/etc/config/irqbalance`) is enabled on the
  router only and disabled on both APs, driven by `openwrt_irqbalance_enabled`
  (`'router' in group_names`) in `group_vars/all.yml` — same
  router-vs-AP branching pattern as `openwrt_log_size`/`openwrt_cronloglevel`
  above rather than a separate `group_vars/router.yml` override, since it's
  a single boolean rather than a router-only value with no AP equivalent.
  The `luci-app-irqbalance` package (which provides the irqbalance binary +
  init script) is already installed on all hosts via
  `openwrt_packages_common`, so `openwrt/default.yml` needed no changes.

- `openwrt/dhcp.yml` (`/etc/config/dhcp`) covers `dnsmasq`/`dhcp`/`odhcpd`
  sections, branched on `'router' in group_names` inside
  `openwrt/files/dhcp.conf` — the router runs the actual DHCP server (`lan`/
  `iot`/`wan` sections, `authoritative`/`sequential_ip`/`nonegcache`), while
  APs just relay to it (`list server '{{ openwrt_router_host }}'`, a single
  `lan` section with `ra`/`dhcpv6`/`dhcpv4` all `server`). `domain` is the
  same `domain` secret reused by `openwrt/adblock.yml`/`banip.yml`. Notifies
  both `dnsmasq` and `odhcpd` restarts, since the one file configures both
  daemons. The template also has an `openwrt_router_dhcp_extra` hook
  (`default('')`, appended verbatim after `odhcpd` with a blank line before
  it) for the router's `config domain`/`config host` static-lease entries —
  not yet populated, but reserved so they can go straight into `router.yaml`
  (same reasoning as `openwrt_router_firewall_config`: real internal
  hostnames, too revealing to commit) without touching the template again.

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
