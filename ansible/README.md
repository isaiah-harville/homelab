# Ansible — k3s Node Provisioning

Provisions Ubuntu 24.04 machines as k3s agent nodes with Longhorn storage.

All cluster-wide settings live in `group_vars/all/`, and the secrets (k3s token, login user, password) live encrypted in `group_vars/all/vault.yml`. Adding a node is just needs a∂ hostname and a static IP.

## What it does

1. **common** — sets hostname, creates/sets the user password, configures the static IP via netplan
2. **longhorn** — installs `open-iscsi`, `nfs-common`, creates `/data/longhorn`, loads `iscsi_tcp`
3. **k3s_node** — installs the k3s agent and joins the cluster

## Layout

```
ansible.cfg              # inventory, roles, sudo, and vault password wiring
inventory/hosts.yml      # the nodes (no secrets — safe to commit)
group_vars/all/vars.yml  # non-secret defaults (server URL, gateway, NIC, …)
group_vars/all/vault.yml # ENCRYPTED secrets (token, user, password)
.vault-pass              # vault password — gitignored, never committed
playbooks/provision.yml  # the entrypoint
roles/{common,longhorn,k3s_node}
```

The vault password file `.vault-pass` is the only thing kept out of git. The
vault itself is encrypted, so it's committed alongside everything else. Keep a
backup of `.vault-pass` somewhere safe (a password manager) — without it the
vault can't be decrypted.

## Prerequisites

```bash
ansible-galaxy collection install community.general
```

## Adding a node

1. Install Ubuntu 24.04 and give it the target static IP during install (or via
   cloud-init). It must be reachable at that IP over SSH.

2. Add the host to `inventory/hosts.yml` — two fields:

   ```yaml
   node-03:
     node_name: node-03
     node_ip: "10.1.10.103/24"
   ```

   `ansible_host` is derived from `node_ip`. The login user and password come
   from the vault.

3. Run it:

   ```bash
   ansible-playbook playbooks/provision.yml --limit node-03
   ```

   Omit `--limit` to (re)provision every host. Re-runs are idempotent.

## Common commands

Run everything from this `ansible/` directory — `ansible.cfg` handles the
inventory, roles, sudo, and vault password automatically.

### Provisioning

```bash
# Provision one node
ansible-playbook playbooks/provision.yml --limit node-03

# Provision all nodes
ansible-playbook playbooks/provision.yml

# Dry run (show what would change, change nothing)
ansible-playbook playbooks/provision.yml --check --diff

# Run only one role's tasks
ansible-playbook playbooks/provision.yml --tags longhorn

# More verbose output for debugging (-vvv for connection detail)
ansible-playbook playbooks/provision.yml --limit node-03 -vv
```

### Vault

```bash
# Edit secrets (opens decrypted in $EDITOR, re-encrypts on save)
ansible-vault edit group_vars/all/vault.yml

# View secrets without editing
ansible-vault view group_vars/all/vault.yml

# Change the vault password (re-encrypts with a new key)
ansible-vault rekey group_vars/all/vault.yml

# Encrypt a brand-new plaintext file in place
ansible-vault encrypt group_vars/all/vault.yml
```

### Inventory & connectivity

```bash
# List hosts Ansible sees
ansible-inventory --graph

# Show all resolved vars for a host
ansible-inventory --host node-01

# Ping every node over SSH (are they reachable?)
ansible all -m ping

# Ad-hoc command on all nodes
ansible all -m command -a "uptime"
```

### After provisioning (from the control node)

```bash
# Confirm the new node joined
kubectl get nodes -o wide

# Watch Longhorn see the node's disk
kubectl -n longhorn-system get nodes.longhorn.io
```

## Variables

| Variable | Where | Description |
|---|---|---|
| `node_name` | inventory (per-host) | Hostname to assign |
| `node_ip` | inventory (per-host) | Static IP in CIDR (e.g. `10.1.10.103/24`); also used as `ansible_host` |
| `vault_node_user` | vault.yml | Login user created on every node |
| `vault_node_password` | vault.yml | Password for that user |
| `vault_k3s_token` | vault.yml | k3s node join token |
| `k3s_server_url` | vars.yml | k3s API URL — `https://10.1.10.10:6443` |
| `node_gateway` | vars.yml | Default gateway (`10.1.10.1`) |
| `node_dns` | vars.yml | DNS servers list |
| `network_interface` | vars.yml | NIC to configure (default: `enp1s0`) |
| `longhorn_data_path` | vars.yml | Longhorn data dir (`/data/longhorn`) |
