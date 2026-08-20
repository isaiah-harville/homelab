# Home Automation Infrastructure Design

## Goal

Deploy the Kubernetes infrastructure for Home Assistant, Mosquitto,
Zigbee2MQTT, Matter Server, and OpenThread Border Router (OTBR) before the
physical smart-home devices arrive. Installation-time work should be limited to
assigning stable LAN names or addresses, setting the two SMLIGHT radio
endpoints, supplying credentials, pairing devices, and completing integrations
that Home Assistant owns through its UI.

## Repository fit

The stack remains under `apps/base/home-automation/` and is composed by the
existing `clusters/homelab/apps` Flux Kustomization. It uses the shared `apps`
namespace because this repository groups application workloads there, the
wildcard TLS secret is already reflected there, the namespace already admits
host-networked workloads, and cross-service DNS names remain short and stable.

Raw Kubernetes manifests match the existing home-automation work and other
applications in the repository. Adding a Helm chart or a child Flux
Kustomization would add another configuration layer without providing useful
lifecycle or dependency behavior. The parent Flux Kustomization already waits
for sources, infrastructure, and certificates before reconciling apps.

The existing Mosquitto, Zigbee2MQTT, and Home Assistant commits are the starting
point. Implementation will preserve their intent while correcting radio
allocation, adding the remaining services, hardening networking and security,
and adding operations documentation.

## Component architecture

### Mosquitto

Mosquitto remains a single-replica Deployment with normal pod networking, a
ClusterIP Service on TCP 1883, password authentication, anonymous access
disabled, and broker persistence enabled. It is not exposed by Ingress,
NodePort, or LoadBalancer.

Zigbee2MQTT and Home Assistant use separate MQTT identities from the existing
SOPS-encrypted `mosquitto-clients` and `mosquitto-passwd` Secrets. Clients use
`mqtt://mosquitto.apps.svc.cluster.local:1883` rather than a pod or ClusterIP.
Secret MAC replacements trigger controlled workload rollouts when credentials
change.

### Zigbee2MQTT

Zigbee2MQTT remains a single-replica Deployment with normal pod networking and
a retained PVC mounted at `/app/data`. Its frontend is available only through
the existing internal Traefik ingress and Authentik ForwardAuth.

The SLZB-MR3U radios are independent; no multiprotocol firmware is used. The
recommended allocation follows SMLIGHT's MR-series guidance:

- CC2674P10 / Radio 2: Zigbee coordinator, `zstack` adapter.
- EFR32MG24 / Radio 1: Thread RCP for OTBR.

The Zigbee radio host, TCP port, adapter, and baud rate are held in a focused
ConfigMap. The initial port is an invalid `0` sentinel because the final
SLZB-MR3U endpoint must be read from its configured web interface. Startup
validation rejects the sentinel with an actionable log message instead of
guessing a port or connecting to the wrong radio.

Zigbee2MQTT publishes Home Assistant MQTT discovery data, keeps its generated
network key, device database, friendly names, logs, and coordinator backup on
its PVC, and does not contain synthetic IEEE addresses. Pairing is performed
after hardware installation through a time-limited permit-join workflow.

### Home Assistant

Home Assistant remains a single-replica Deployment with a retained `/config`
PVC. Git owns the stable `configuration.yaml` settings while Home Assistant
owns `.storage`, integrations, automations, scripts, scenes, and its SQLite
database on the PVC.

Home Assistant uses `hostNetwork: true` and
`dnsPolicy: ClusterFirstWithHostNet`. This provides direct LAN participation
for mDNS, SSDP, UPnP, and discovery without Multus, macvlan, a dedicated
LoadBalancer, or direct USB access. Its ClusterIP Service and internal Traefik
Ingress remain the supported HTTP path. The ingress has no ForwardAuth because
Home Assistant provides its own authentication and companion-app/webhook
clients cannot complete browser redirects. Trusted-proxy configuration covers
the cluster pod CIDR used by Traefik.

Home Assistant uses only the privileges required by host networking; it does
not receive `/dev/net/tun`, `NET_ADMIN`, or a privileged security context.

Home Assistant's native Lovelace dashboards, automation editor, script editor,
scene editor, and device/entity management UI remain enabled through
`default_config`. Dashboard definitions and UI-created automations persist on
the `/config` PVC. No separate dashboard or automation application is needed.
The operations runbook will distinguish Git-owned base configuration from
Home Assistant-owned UI state so an operator does not overwrite dashboards or
automations during reconciliation.

### Matter Server

Matter Server uses the official
`ghcr.io/home-assistant-libs/python-matter-server` image pinned to a concrete
version. It runs as one host-networked replica with
`dnsPolicy: ClusterFirstWithHostNet`, retained `/data` state, and a ClusterIP
Service for its WebSocket API on TCP 5580. Home Assistant connects through
`ws://matter-server.apps.svc.cluster.local:5580/ws`.

Host networking is required for Matter's IPv6 link-local multicast and
commissioning behavior. The self-managed container path is less tested than
the Home Assistant OS add-on path; this is an accepted constraint of running
Home Assistant Core in Kubernetes and will be stated in the runbook.

Matter Server does not own the Thread radio or the OTBR process. It reaches
Matter-over-Thread devices through normal LAN IPv6 routing advertised by OTBR.
No fake Matter nodes or lock definitions are created.

### Kubernetes OTBR

OTBR uses `bnutzer/otbr-tcp`, pinned by its immutable source tag and container
digest. This image packages upstream OTBR with `socat` in the same container and
is specifically designed for network-attached Thread RCPs. SMLIGHT recommends
it for container deployments outside Home Assistant OS. Keeping `socat` and
OTBR in one container is necessary because a pseudo-TTY created in a normal
sidecar belongs to that sidecar's private `devpts` mount and is not reliably
usable by another container. The selected image avoids a custom homelab image
while retaining the upstream OTBR implementation.

The Thread ConfigMap exposes the SMLIGHT hostname, TCP port, local RCP TTY,
baud rate, additional Spinel arguments such as hardware flow control, LAN
infrastructure interface, REST listen address, and logging level. The initial
TCP port is `0`; an init validator prevents OTBR from starting until a real
value is supplied. Neither the MR3U's final port nor its complete RCP settings
are guessed.

OTBR runs with:

- `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet`;
- one replica and Deployment strategy `Recreate`;
- required node affinity for `home.harville.dev/otbr=true`;
- preferred node affinity for hostname `thinkcentre-01`;
- `/dev/net/tun` passed into the OTBR container;
- only `NET_ADMIN` and the security settings proven necessary by the selected
  image;
- a retained PVC for the OpenThread operational dataset and daemon state;
- a PodDisruptionBudget that prevents voluntary eviction without an available
  replacement only after another eligible node exists. With one eligible node,
  a PDB would block maintenance without adding availability, so it is omitted
  initially.

At most one OTBR process may connect to the RCP. `replicas: 1` and `Recreate`
prevent normal rollouts from overlapping. Kubernetes cannot provide a strict
distributed hardware lease if an old node is partitioned while its process
continues running; the single eligible node avoids that split-brain case for the
initial deployment. Any future failover-node design must account for fencing,
not merely add a second label.

The Home Assistant OpenThread Border Router integration connects to OTBR's
standard REST interface through a stable Service. Nothing else depends on the
TCP bridge or local pseudo-TTY.

## Talos host preparation and scheduling

Only `thinkcentre-01` is currently an always-on dedicated worker suitable for
OTBR. The `dl380` is not selected as a failover host. A reusable
`talos/omni/patches/otbr-host.yaml` patch will:

- add `home.harville.dev/otbr: "true"` as a node label;
- enable the exact IPv6 forwarding/sysctl settings required by OTBR;
- ensure the TUN device and any required kernel modules are available; and
- avoid unrelated modules, mounts, or privileges.

The patch is assigned to `thinkcentre-01` in both
`talos/omni/cluster-template.yaml` and Terraform's shared patch mapping so the
manual and Terraform topology paths remain aligned.

The Deployment uses required affinity rather than a hard-coded `nodeName`.
Although only `thinkcentre-01` is eligible initially, another always-on worker
can later receive the same complete Talos patch and become eligible without
changing the pod template. Automatic failover is not claimed until such a node
exists. An OTBR interruption occurs whenever `thinkcentre-01` is rebooted,
drained, or unavailable.

## Networking and service flow

The LAN already has IPv6 enabled. Before commissioning, verification must show
that `thinkcentre-01`, the SLZB-MR3U, the phone used for commissioning, and the
IoT LAN exchange IPv6 multicast and router advertisements correctly.

Service flows are:

```text
Home Assistant -> mosquitto.apps.svc.cluster.local:1883
Zigbee2MQTT     -> mosquitto.apps.svc.cluster.local:1883
Home Assistant -> matter-server.apps.svc.cluster.local:5580
Home Assistant -> otbr.apps.svc.cluster.local:8081
Zigbee2MQTT     -> SLZB-MR3U Zigbee TCP endpoint
OTBR TCP bridge -> SLZB-MR3U Thread RCP TCP endpoint
Matter Server   -> LAN/Thread devices over IPv6 and multicast
Home Assistant -> ecobee cloud endpoints and local UniFi Protect controller
```

No restrictive NetworkPolicy is added to the host-networked components because
standard policy semantics do not reliably constrain host-network traffic and a
partially correct policy could break multicast discovery. Mosquitto remains
cluster-internal. VLAN migration documentation will specify DNS, unicast,
mDNS, SSDP, IPv6 multicast, ICMPv6, Matter, Protect, and SMLIGHT flows rather
than prematurely enforcing a policy against an unknown VLAN design.

## Ingress and TLS

Only Home Assistant and the Zigbee2MQTT frontend receive Ingress resources.
Both use `traefik-internal` and `*.int.harville.dev`; the parent apps
Kustomization applies `websecure` and replaces the placeholder TLS secret with
`harville-wildcard-shared-tls`. Standard HTTP upgrade handling in Traefik
supports Home Assistant WebSockets without a special middleware.

Mosquitto, Matter Server, and OTBR have ClusterIP Services only. They are never
published through public ingress.

## Persistent data and recovery

All stateful workloads use RWO `longhorn-retain` PVCs and `Recreate` updates:

| PVC | Contents | Initial size |
| --- | --- | ---: |
| `home-assistant-config` | HA configuration, `.storage`, SQLite DB, automations | 10 Gi |
| `zigbee2mqtt-data` | Device database, network key, names, coordinator backups | 1 Gi |
| `mosquitto-data` | Retained MQTT messages and broker persistence DB | 1 Gi |
| `matter-server-data` | Matter fabric, credentials, nodes, subscriptions | 1 Gi |
| `otbr-data` | Active Thread operational dataset and OTBR state | 1 Gi |

The existing Longhorn default recurring-job group supplies seven daily local
snapshots. These protect against short-term application damage but not cluster
or disk loss. The repository has no non-circular off-cluster volume backup
system: SeaweedFS itself depends on Longhorn. This design records that disaster
recovery gap rather than adding a second backup architecture without approval.

Restore order is OTBR dataset, Matter fabric, Zigbee2MQTT state, Mosquitto state,
then Home Assistant state. Restoring only part of the Thread/Matter pair can
invalidate commissioning state and require device recommissioning.

## Secrets and integrations

MQTT credentials stay in SOPS/age Secrets. No ecobee, UniFi, Matter device,
Zigbee IEEE address, or future security-device credentials are committed.

The runbook will cover UI-owned configuration:

- MQTT: add the broker using the Home Assistant MQTT identity.
- ecobee: use Home Assistant's supported integration and its current
  authorization flow; credentials or account authorization cannot be completed
  before the thermostat and account exist.
- UniFi Protect: use the supported integration with a dedicated local UniFi
  account, least-privilege Protect permissions, controller LAN name, and local
  certificate handling. Expected entities include doorbell, motion, person,
  vehicle, animal, and camera state when the installed hardware exposes them.
- Matter and Thread: add the Matter Server and OTBR integrations, form or import
  exactly one Thread dataset, make it preferred, and synchronize credentials to
  the companion phone before commissioning locks.
- Apple HomeKit: use Home Assistant's HomeKit Device integration to import
  compatible HomeKit accessories and HomeKit Bridge to expose selected Home
  Assistant entities to Apple Home. Configure both through Home Assistant,
  retain pairing state on the Home Assistant PVC, and keep pairing codes and
  Apple account data out of Git. Host networking supplies the mDNS visibility
  required by HomeKit discovery. Avoid bridging an entity back into the
  ecosystem from which it was imported, which would create duplicate devices.
- Future UniFi SuperLink/security devices: add only when Home Assistant exposes
  a supported integration; no speculative resources are created.

## Observability and health

Kube-prometheus-stack already supplies pod, Deployment, node, resource, restart,
and PVC metrics. New PrometheusRules alert when a smart-home Deployment has no
available replica for a sustained interval or enters a restart loop. This gives
coverage for Home Assistant, Mosquitto, Zigbee2MQTT, Matter Server, and OTBR
without inventing exporters.

TCP or HTTP probes are used only when the endpoint accurately represents
process health. OTBR startup additionally validates `/dev/net/tun`, IPv6
forwarding, the selected LAN interface, the persistent data path, and the RCP
configuration. A disconnected MR3U produces a visible unavailable workload and
alert rather than a falsely Ready pod.

Native application metrics are exposed only if the pinned application version
provides a stable unauthenticated metrics endpoint. No long-lived Home Assistant
token is created merely to scrape health.

## Failure behavior

| Failure | Result |
| --- | --- |
| Container crash or pod deletion | Kubernetes recreates the singleton workload. |
| Flux upgrade | `Recreate` performs a controlled stop then start. |
| `thinkcentre-01` reboot, drain, or failure | OTBR remains Pending until that node returns because no second always-on eligible worker exists. Other stack components remain scheduled normally. |
| SLZB-MR3U reboot | Zigbee and Thread are temporarily unavailable; clients reconnect when the TCP endpoints return. |
| SLZB-MR3U failure | Zigbee coordination and Thread border routing remain unavailable. |
| RCP TCP interruption | OTBR may leave stale routes for up to the upstream-documented 30-minute route lifetime. |
| PVC attachment movement | `Recreate` and RWO semantics serialize attachment; retained data follows a rescheduled pod. |
| Cluster/storage loss | Longhorn snapshots are lost with the cluster; off-cluster recovery is unavailable. |

## Migration to MR3U-hosted OTBR

The future migration changes the OTBR implementation, not the consumers:

1. Back up/export the active Thread operational dataset from Kubernetes OTBR.
2. Enable the MR3U's built-in OTBR only after its implementation is accepted as
   stable and load or join it to the same dataset.
3. Stop the Kubernetes OTBR before allowing the MR3U-hosted OTBR to advertise
   the network; never form a second independent Thread network.
4. Change Home Assistant's OTBR integration endpoint from the Kubernetes
   Service to the MR3U REST/API URL.
5. Keep Matter Server and its fabric state unchanged.
6. Verify Thread credentials, preferred-network state, IPv6 routes, mDNS,
   existing device reachability, and new-device commissioning.
7. Disable or remove the Kubernetes OTBR Deployment only after validation.

## Validation

Static validation includes:

- `kubectl kustomize clusters/homelab/apps`;
- `kubectl kustomize clusters/homelab/infra`;
- `kubectl kustomize clusters/homelab/flux-system`;
- `terraform -chdir=terraform/omni fmt -check -recursive`;
- `uvx pre-commit run --all-files`;
- checks that images are not tagged `latest`, plaintext credentials are absent,
  host-network pods use `ClusterFirstWithHostNet`, OTBR has one replica and
  `Recreate`, and both topology declarations assign the same Talos patch.

Runtime acceptance after the MR3U is installed includes:

- verify Zigbee2MQTT connects only to the CC2674P10 Zigbee endpoint;
- verify OTBR connects only to the EFR32MG24 Thread RCP endpoint;
- verify `/dev/net/tun`, `wpan0`, IPv6 forwarding, RIO routes, mDNS, and OTBR
  REST health on `thinkcentre-01`;
- add MQTT, Matter Server, and OTBR integrations in Home Assistant;
- create a test Lovelace dashboard and UI-authored automation, restart Home
  Assistant, and verify that both persist;
- pair one compatible HomeKit accessory or bridge a test entity to Apple Home,
  verify mDNS discovery, and confirm that no duplicate entity loop is created;
- pair one powered Zigbee router, one Zigbee sensor, and a test Matter device;
- restart each singleton and verify its state survives;
- confirm Prometheus alerts clear after successful startup; and
- record the final radio endpoints, firmware roles, Thread dataset backup, and
  recovery steps in the operations runbook.
