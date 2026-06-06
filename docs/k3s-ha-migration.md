# k3s Control-Plane HA Migration (runbook)

Status: Phases 1-4 done (2026-06-06). Three etcd servers (dl380, precision-1,
precision-2) behind the VIP at 10.1.10.9; agents and kubectl point at the VIP.
The cluster now survives losing any one server. Left to do: the failover test
(Phase 5), whenever you want to prove it.

## Goal

Take the single SQLite k3s server (dl380) to three servers on embedded etcd
behind a floating VIP, so losing any one server keeps the API up. There's no
standby that gets promoted — all three run etcd and the cluster survives as long
as two are alive (quorum).

## Decisions

| Thing | Value | Notes |
|---|---|---|
| Servers (etcd) | `dl380` (.10), `thinkcentre-01` (.33), `precision-1` (.30) | **Must stay an odd number.** |
| Agents | `precision-2` (.31), `latitude-01` (.32) | Stay workers. |
| API VIP | **`10.1.10.9`** | Free; clear of MetalLB pool `10.1.10.251-252`. Reserve it in the router (exclude from DHCP). |
| New API endpoint | `https://10.1.10.9:6443` | Replaces `https://10.1.10.10:6443` everywhere. |

**Why these:** etcd needs a majority to work — 1 server tolerates 0 failures,
**2 tolerates 0 (worse — either one down = dead)**, **3 tolerates 1**, 5 tolerates 2.
So 3 is the minimum that survives losing `dl380`.

Servers are `dl380` + `thinkcentre-01` (new, no data — joins clean) +
`precision-1` (a beefier workstation, more reliable for etcd than a laptop).
**Caveat for `precision-1`:** it's currently an agent holding Longhorn replicas,
so promoting it means **draining it, uninstalling the agent, and rejoining as a
server** — Longhorn rebuilds its replicas onto the other nodes meanwhile. We do
this one node at a time so redundancy is never lost (replica 3 across 5 nodes).

---

## Pre-flight (no changes)

- [ ] Flux shows everything synced (`flux get kustomizations -A`) — most cluster
      state is reproducible from git; the irreplaceable bits are etcd/SQLite
      data (secrets created at runtime, Longhorn volume↔PVC mapping).
- [ ] Reserve `10.1.10.9` in the router / exclude from DHCP.
- [ ] Record each server's NIC for kube-vip: `dl380` = TBD (`ip -br link`),
      `thinkcentre-01` = `eno1`, `precision-1` = `enp0s31f6`.
- [ ] Schedule a maintenance window — Phases 1 and 4 cause brief API blips.

## Phase 0 — Backups (do this every run; highest-leverage safety)

```bash
# On dl380, back up the datastore + identity
sudo cp -a /var/lib/rancher/k3s/server/db   /root/k3s-db-backup-$(date +%F)
sudo cp -a /etc/rancher/k3s                 /root/k3s-etc-backup-$(date +%F)
sudo cat /var/lib/rancher/k3s/server/token        # save somewhere safe
```

- [ ] All Longhorn volumes `healthy` (replica 3) before starting.
- [ ] Optional but ideal: a Longhorn backup target (NFS/S3) and a backup taken.
- [ ] Rollback is understood (see end).

## Phase 1 — dl380 SQLite to embedded etcd (done 2026-06-06)

dl380 already had a config.yaml with `disable: [traefik, servicelb]`, so that
was carried over. The final `/etc/rancher/k3s/config.yaml`:

```yaml
disable:
  - traefik
  - servicelb
cluster-init: true
tls-san:
  - 10.1.10.9
  - 10.1.10.10
```

Not in the original plan: the datastore had a leftover `db/etcd/` directory from
cluster creation with only a `name` file in it, no member data. The k3s docs say
`cluster-init` is ignored if an etcd datastore already exists on disk, so instead
of gambling on how it reads that stub we stopped k3s and moved it out of the way
first. What actually ran:

```bash
sudo systemctl stop k3s
sudo cp -a /var/lib/rancher/k3s/server/db /root/k3s-db-backup-<ts>
sudo mv /var/lib/rancher/k3s/server/db/etcd /root/k3s-etcd-stub-<ts>
# write the config.yaml above
sudo systemctl start k3s
```

On start, k3s migrated the SQLite data into etcd and renamed `state.db` to
`state.db.migrated`. Afterward: dl380 is `control-plane,etcd`, `db/etcd/member/`
exists, 89 pods Running, the 4 Longhorn volumes healthy, Flux kustomizations all
Ready, and the API cert includes 10.1.10.9.

To roll back: stop k3s, copy `/root/k3s-db-backup-<ts>` back over `db/`, move the
etcd stub back, restore the saved `config.yaml`, start k3s.

## Phase 2 — kube-vip VIP on dl380 (done 2026-06-06)

kube-vip v1.2.0 runs as a DaemonSet on the control-plane nodes (just dl380 for
now, spreads as servers join) and owns 10.1.10.9 in ARP mode with leader
election. The manifest sits at
`/var/lib/rancher/k3s/server/manifests/kube-vip.yaml` on dl380 so k3s applies it
on boot; it's deliberately not in Flux so the API VIP can't depend on Flux being
up. It's a local file on dl380, not tracked in git.

Two settings worth remembering:

- `vip_interface` is empty, so kube-vip picks each node's default-route
  interface. That's what lets one DaemonSet cover dl380/precision-2 (`eno1`) and
  precision-1 (`enp0s31f6`) without per-node config.
- `svc_enable` is `false`. MetalLB still handles Service load balancers; kube-vip
  only serves the control-plane VIP.

Checked: VIP is up on `eno1`, `kubectl --server https://10.1.10.9:6443 get nodes`
works, and kube-vip's log shows it took the lease and started the ARP broadcaster.

## Phase 3 — precision-1 and precision-2 to servers (done 2026-06-06)

First fix: the four existing volumes were still replica-2 with both copies on
dl380 + precision-1 (the default-3 change only affected new volumes). Evicting
precision-1 in that state would have left single copies on dl380, so before
touching anything the volumes were raised to 3 replicas and left to rebuild
healthy across dl380/precision-1/precision-2.

```bash
for v in $(kubectl -n longhorn-system get volumes.longhorn.io -o name | sed 's#.*/##'); do
  kubectl -n longhorn-system patch volumes.longhorn.io "$v" --type=merge \
    -p '{"spec":{"numberOfReplicas":3}}'
done
```

Then each node, one at a time, watching that no volume dropped below two healthy
copies. A plain `kubectl drain` would hang on Longhorn's instance-manager PDB, so
the replicas get evicted through Longhorn first:

```bash
kubectl cordon precision-1
kubectl -n longhorn-system patch nodes.longhorn.io precision-1 --type=merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
# wait until precision-1 holds 0 replicas and volumes are still healthy
kubectl drain precision-1 --ignore-daemonsets --delete-emptydir-data
ansible precision-1 -m command -a /usr/local/bin/k3s-agent-uninstall.sh -b
ansible-playbook playbooks/servers.yml --limit precision-1   # joins as etcd server
kubectl uncordon precision-1
kubectl -n longhorn-system patch nodes.longhorn.io precision-1 --type=merge \
  -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'
```

`servers.yml` refuses to run while the agent is still installed, so it can't
stack a server on a live agent. Same sequence for precision-2. End state:
`kubectl get nodes` shows dl380, precision-1, precision-2 as `control-plane,etcd`
(three members, tolerates one failure), volumes healthy, snapshots taken after
each join. Note the brief two-member window between the two joins, where the
cluster tolerated no failures — that's why precision-2 followed precision-1
straight away.

## Phase 4 — Everything onto the VIP (done 2026-06-06)

The two agents were pinned to dl380 directly (`K3S_URL='https://10.1.10.10:6443'`
in `/etc/systemd/system/k3s-agent.service.env`), so they'd have lost the API if
dl380 went down. Repointed both at the VIP and restarted k3s-agent:

```bash
ansible k3s_agents -m replace -b \
  -a "path=/etc/systemd/system/k3s-agent.service.env regexp='10\.1\.10\.10:6443' replace='10.1.10.9:6443'"
ansible k3s_agents -m systemd -a "name=k3s-agent state=restarted daemon_reload=true" -b
```

Also pointed `~/.kube/config` at `https://10.1.10.9:6443`. In git: `k3s_server_url`
now resolves to the VIP, and the `k3s_node` role keeps `K3S_URL` matched to it
(restarts k3s-agent on change) so a re-run repoints any drifted agent.

## Phase 5 — Failover test

The proof that it all works. Stop k3s on dl380 and confirm the API still answers
through the VIP and the cluster stays usable, then bring it back:

```bash
sudo k3s etcd-snapshot save                       # baseline
sudo systemctl stop k3s                           # on dl380
kubectl get nodes                                 # still works; VIP floated to a precision
# confirm apps still schedule, then:
sudo systemctl start k3s                          # dl380 rejoins etcd
```

---

## Ansible pieces (built)

- **Inventory groups** (`inventory/hosts.yml`): `k3s_servers` = the joiners
  `precision-1`, `precision-2`; `k3s_agents` = `thinkcentre-01`, `latitude-01`;
  `k3s_bootstrap` = `dl380` (listed for reference with `connection: local`, but
  **no routine play targets it** — see below).
- **`k3s_server` role** (`roles/k3s_server`): writes `/etc/rancher/k3s/config.yaml`
  (`server:` → VIP, `token:`, `tls-san`), installs k3s as a server, idempotent,
  and **refuses to run while a k3s agent is still present**.
- **`servers.yml` playbook**: `longhorn` (idempotent host prereqs) + `k3s_server`
  against `k3s_servers`. Run with `--limit` one node at a time.
- **`vars`:** `k3s_vip` / `k3s_api_vip_url` added. `k3s_server_url` flips to the
  VIP in Phase 4. Server join reuses `vault_k3s_token` (it's already a `::server:` token).

### Why `dl380` is NOT in the routine playbooks

`dl380` is the box we run ansible *from* and the live API server for everything.
Even though its credentials match the vault, we keep its one-time etcd
conversion + kube-vip bootstrap (Phases 1–2) **manual/guided**, and exclude it
from `provision.yml`/`servers.yml`. Rationale: blast radius — you don't want the
control plane that hosts every app to be reconfigurable as a side effect of a
routine play, and a SQLite→etcd `cluster-init` is a once-ever step, not something
worth making re-runnable. It's in the inventory under `k3s_bootstrap` purely for
documentation.

## Still manual (by design)

- **Phase 1** (dl380 SQLite→etcd) and **Phase 2** (kube-vip on dl380).
- **kube-vip manifest:** your servers have mixed NICs (`dl380`/`precision-2` =
  `eno1`, `precision-1` = `enp0s31f6`), so confirm interface handling when
  generating it — use kube-vip interface auto-detection, or per-node values.
- **Playbook order:** bootstrap server → joiner servers → agents.

## Rollback

- **Phase 1:** stop k3s, restore `/var/lib/rancher/k3s/server/db`, remove
  `cluster-init`, start → back to the single SQLite server.
- **Later:** `k3s-uninstall.sh` on the added servers, `kubectl delete node` them,
  revert `server:` URLs, restart agents.

## Ongoing HA hygiene

- Scheduled etcd snapshots: `--etcd-snapshot-schedule-cron` + retention, to
  NFS/Longhorn/offsite.
- Patch/upgrade servers **one at a time** (rolling), never losing quorum.
- Keep the server count **odd** (grow 3 → 5, never 4).
