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

## Commit/PR style

- One commit per logical fix, not squashed — makes review and future
  `git blame` easier on a repo this size.
- Branches follow `pb/YYYYMMDD_description`.
- PRs are opened against `main` with `gh pr create`.
