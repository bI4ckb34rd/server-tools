# Rollback — manifest design and guarantees

> Status: **implemented** by `src/state/manifest.sh`, `src/state/backup.sh`
> and `src/state/migrate.sh` (2.4.5).

## Why it exists

Legacy (v1) rollback restored from a `latest` symlink over a hardcoded file
list: running optimize twice made "latest" a backup of already-modified
files, several files were never rolled back, and a provider's `/swapfile` was
deleted. 2.4.4 fixed files structurally; 2.4.5 extends the same guarantees to the
**live** state the tool changes (RPS/XPS masks, governor, THP, the uplink
qdisc, firewall rules).

## What is recorded

Every change goes through one of these calls **before** it happens:

| Call | Records |
| --- | --- |
| `st_track_file PATH` | a pristine copy under `backups/original/<abs-path>` (first touch ever, never overwritten), a per-run copy under `backups/runs/<run-id>/<abs-path>`, and a `created` or `modified` row |
| `st_write_file PATH CONTENT` | nothing when PATH already holds CONTENT (a re-run stays a no-op); otherwise `st_track_file`, then the write |
| `st_set_runtime PATH VALUE` | the current value of a `/proc` or `/sys` knob under `original/.runtime/` (first touch) and `runs/<run-id>/.runtime/`, a `runtime` row, then the write |
| `st_track_qdisc IFACE` | a `qdisc` row: the uplink's root qdisc is rebuilt |
| `st_set_ethtool IFACE KEY VALUE` | the current NIC channel count or offload state under `.runtime/ethtool/`, an `ethtool` row, then the change |
| `systemd_enable_oneshot UNIT` | a `unit` row |

`manifest.tsv` (append-only, so file order is time order):

```tsv
# timestamp	run_id	action	target
2026-11-03 20:14:03	20261103-201401	modified	/etc/sysctl.d/99-zz-server-tools.conf
2026-11-03 20:14:03	20261103-201401	runtime	/sys/class/net/eth0/queues/rx-0/rps_cpus
2026-11-03 20:14:03	20261103-201401	qdisc	eth0
2026-11-03 20:14:04	20261103-201401	unit	server-tools-mss.service
2026-11-03 20:20:10	20261103-202008	rolledback	20261103-201401
```

| Action | Rollback does |
| --- | --- |
| `created` | removes the file (an active swap file is swapped off first; never deleted under the kernel) |
| `modified` | restores the run's copy |
| `unit` | `systemctl disable --now` — units' `ExecStop=` lines remove their live rules (MSS, NOTRACK, flowtable) |
| `runtime` | writes the saved value back immediately |
| `qdisc` | after sysctl files are restored and reloaded, re-attaches the kernel default qdisc (so the restored `default_qdisc` is what comes back) |
| `ethtool` | re-applies the saved channel count / offload state with ethtool |
| `package` | informational — installed prerequisites are kept (other software may depend on them) |
| `rolledback` | marker only — never replayed |

Run ids are unique even for two runs inside the same second (a `-PID`
suffix), so a scripted `st --auto && st --auto` can never overwrite the first
run's "before" copies.

## `--rollback` — newest open run

1. Take the newest run that has changes and no `rolledback` marker.
2. Replay its rows **newest first** as in the table above.
3. Reload units and sysctl, re-attach qdiscs, write the `rolledback` marker.
4. Report restored / removed / missing / failed honestly (exit 3 if anything
   failed). A copy that cannot be written back counts as failed — it is never
   reported as restored.

Because rolled-back runs are skipped, **rolling back again undoes the run
before it** — walking back through history instead of re-applying the same
backup (a 2.4.4 limitation). Ten run directories are kept (`backup_prune`); a
rollback that walks past them reports the missing copies.

## `--rollback-original` — factory state

Restores every file in `original/` (the `.runtime/` subtree is excluded from
the file pass), removes everything ever `created`, disables every `unit`,
writes every saved runtime original back, reloads sysctl, re-attaches the
qdisc of every recorded interface, and marks all runs rolled back.

## Upgrading from 2.4.4 and older

Manifests of 2.4.4 and older (created/modified/unit rows) are still valid. On the
first mutating 2.4.5 run (menu after confirmation, `--auto`, Quick/Custom
Optimize), `migrate_run` fixes what 2.4.4 left live, as tracked changes of that
run — so rolling that run back also reverts the migration:

1. the MSS unit gets an idempotent `ExecStart` and an `ExecStop`, and the
   duplicates 2.4.4 appended are collapsed into one rule;
2. NOTRACK rules are rescoped to traffic addressed to this host
   (`-m addrtype --dst-type LOCAL`) — 2.4.4's unscoped rules broke NAT/VPN
   clients reaching the same port elsewhere;
3. a single root `fq`/`fq_codel` that 2.4.4 put on a multi-queue uplink is
   handed back to the kernel (mq is rebuilt);
4. a 2.4.4 CPU/NIC boot script is flagged (Doctor reports drift) until the next
   Quick Optimize re-plans it for the detected roles;
5. MSS / NOTRACK / fast-path units are re-ordered to start after the firewall
   managers (checked before every optimize run; a no-op once done);
6. the next sysctl step moves `99-server-tools.conf` to
   `99-zz-server-tools.conf` and comments conflicting keys out of
   `/etc/sysctl.conf` — both tracked.

`--dry-run`, `--status`, `--verify` and `--rollback` never migrate.

## Guarantees and limits

- **Guaranteed:** file contents and recorded live values return to their state
  at the start of the rolled-back run; first-touch originals are always
  available for `--rollback-original`.
- **Not automatic:** values the kernel recomputes on its own and services
  outside ServerTools; a running service keeps the nofile limit it started
  with until restarted. A reboot after rollback guarantees a clean slate.
- **Firewall frameworks:** UFW rules added through the Security menu are not
  manifest-tracked (UFW has its own `ufw disable` / `ufw reset`); files UFW
  reads (`/etc/default/ufw`, `before.rules`) are.
- **Interrupt affinity:** spread receive interrupts are recorded per IRQ
  (`/proc/irq/N/smp_affinity_list`) and written back on rollback. IRQ
  numbers can change across reboots; rollback also disables the boot unit,
  so from the next boot on placement is the kernel's again.
- **Docker:** `/etc/docker/daemon.json` is a tracked file — rollback
  restores (or removes) it; dockerd picks the old settings up at its next
  reload or restart. Emptying oversized container logs (Node & Docker → 3)
  deletes log text and cannot be undone — the prompt says so.
