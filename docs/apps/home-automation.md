# Home automation

## Architecture and service names

The production Thread border router is OTBR in Kubernetes. The SLZB-MR4U
provides two independent network radios; it does not run OTBR and does not use
multiprotocol firmware.

```text
SLZB-MR4U Radio 2 (CC2674P10) -- TCP --> Zigbee2MQTT --> Mosquitto
SLZB-MR4U Radio 1 (EFR32MG26)  -- TCP --> Kubernetes OTBR
                                                   |
Home Assistant ---------------- Matter Server -----+--- LAN/Thread devices
```

| Interface | Address |
| --- | --- |
| Home Assistant | `https://home-assistant.int.harville.dev` |
| Zigbee2MQTT | `https://zigbee2mqtt.int.harville.dev` |
| MQTT broker | `mqtt://mosquitto.apps.svc.cluster.local:1883` |
| Matter Server | `ws://matter-server.apps.svc.cluster.local:5580/ws` |
| OTBR API | `http://otbr.apps.svc.cluster.local:8081` |

Home Assistant, Matter Server, and OTBR use host networking so they participate
directly in LAN IPv6 and multicast discovery. Matter Server port 5580 and OTBR
port 8081 are consequently reachable on their scheduled nodes' LAN addresses
even though neither has an Ingress. Future UniFi firewall rules must restrict
these ports to Home Assistant and cluster-node sources.

## Before enabling the MR4U workloads

The committed port `0` values and `change-me` interface are deliberate startup
blocks. Before changing them:

1. Give the MR4U a stable DHCP reservation and make
   `slzb-mr4u.home.arpa` resolve from every cluster node.
2. Configure each radio independently in the MR4U UI and record the endpoints
   it reports. Do not infer ports from another SMLIGHT model.
3. Apply the Omni/Terraform machine patch to `thinkcentre-01`; let Omni perform
   the rolling machine update.
4. Verify the node has the `home.harville.dev/otbr=true` label, IPv6 forwarding,
   `/dev/net/tun`, LAN multicast, and an IPv6 default route.
5. Determine the physical LAN interface name on `thinkcentre-01` through Talos
   or Kubernetes node diagnostics.

## MR4U radio allocation and firmware modes

- Radio 2, CC2674P10: Zigbee coordinator using the Zigbee2MQTT `zstack`
  adapter.
- Radio 1, EFR32MG26: dedicated OpenThread RCP connected to Kubernetes OTBR.

Keep Zigbee and Thread on separate radios. Do not install single-radio
multiprotocol firmware. Do not enable the MR4U's beta built-in OTBR while the
Kubernetes OTBR is active: only one OTBR process may own the Thread RCP.

## Configure Zigbee2MQTT

Edit `apps/base/home-automation/zigbee2mqtt.yaml`:

```text
zigbee2mqtt-adapter.data.serial_port
```

Replace `tcp://slzb-mr4u.home.arpa:0` with the exact Radio 2 Zigbee endpoint
shown by the MR4U. Leave `serial_adapter: zstack`; change `serial_baudrate` only
if the installed Radio 2 firmware requires it. Port 0 intentionally leaves the
init container unavailable rather than connecting to an unknown radio.

After Flux reconciles, open the Zigbee2MQTT UI, enable permit-join for a short
window, pair one device at a time, assign a stable friendly name, disable
permit-join, and verify its Home Assistant MQTT discovery entities.

## Configure OTBR and verify IPv6/TUN

Edit `apps/base/home-automation/otbr.yaml`:

```text
otbr-config.data.RCP_HOST
otbr-config.data.RCP_PORT
otbr-config.data.RCP_BAUDRATE
otbr-config.data.OTBR_RCP_ADDITIONAL_ARGS
otbr-config.data.OTBR_BACKBONE_IF
```

Set `RCP_PORT` to the exact EFR32MG26 Thread RCP endpoint exposed by the MR4U
and `OTBR_BACKBONE_IF` to the physical LAN interface on `thinkcentre-01`.
Confirm the baud rate and any Spinel/UART arguments against the installed RCP
firmware. The init container rejects port 0, `change-me`, a missing TUN device,
an unknown interface, or disabled IPv6 forwarding.

Do not initialize a second Thread network if one already exists. Preserve the
active Thread dataset in `otbr-data`, and export its active TLV before upgrades
or migration.

## Add MQTT, Matter, Thread, and OTBR integrations

In Home Assistant, use **Settings > Devices & services > Add integration**:

1. Add MQTT with host `mosquitto.apps.svc.cluster.local`, port `1883`, and the
   Home Assistant identity stored in the SOPS-managed MQTT Secrets.
2. Add Matter using
   `ws://matter-server.apps.svc.cluster.local:5580/ws`.
3. Add OpenThread Border Router using
   `http://otbr.apps.svc.cluster.local:8081`.
4. Confirm Home Assistant discovers the same active Thread dataset exposed by
   OTBR before commissioning Matter-over-Thread devices.

These integrations depend only on the MQTT, Matter WebSocket, and standard
OTBR REST interfaces. Home Assistant does not depend on the OTBR container's
TCP bridge, pseudo-TTY, or Kubernetes implementation details.

## Home Assistant dashboards and automation editors

`default_config` enables Home Assistant's native Lovelace dashboards, device
and entity pages, automation editor, script editor, and scene editor. Use
**Overview > Edit dashboard** and **Settings > Automations & scenes** for normal
configuration. UI-owned state, integrations, dashboards, automations, scripts,
and scenes persist on `home-assistant-config` under `/config` and `.storage`.

Git owns only the mounted base `configuration.yaml`. Do not copy UI-managed
`.storage`, `automations.yaml`, `scripts.yaml`, or `scenes.yaml` into the
ConfigMap or overwrite them during reconciliation.

## THIRDREALITY pairing and naming workflow

Factory-reset each THIRDREALITY device, open a short Zigbee2MQTT permit-join
window, pair one device, and wait for interview completion. Give it a stable
location-based name such as `kitchen_motion_north`, then disable permit-join.
Verify manufacturer, link quality, battery, and expected entities in both
Zigbee2MQTT and Home Assistant before pairing the next device.

## HomeKit Device and HomeKit Bridge

Use **HomeKit Device** to import an unpaired Apple Home accessory into Home
Assistant with its HomeKit pairing code. Use **HomeKit Bridge** to export
selected Home Assistant entities to Apple Home. Imported accessories must not
be re-exported through HomeKit Bridge, which creates duplicates and routing
loops. Store pairing codes outside Git and back up Home Assistant state before
removing or resetting a pairing.

## ecobee authorization

Add ecobee through Home Assistant's supported integration and complete the
authorization flow in the UI after the thermostat and account are available.
Keep account credentials, application credentials, tokens, and authorization
codes out of Git and SOPS manifests unless the integration explicitly requires
a Kubernetes Secret.

## UniFi Protect service account

Create a dedicated local UniFi account with Protect viewer access and no UniFi
OS administrator role. Add the UniFi Protect integration with the controller's
stable LAN hostname and that account. Grant additional camera permissions only
when an automation needs them; do not use the primary UniFi administrator.

## VLAN and firewall flows

Before moving devices to an IoT VLAN, explicitly permit:

- DNS and NTP from smart-home devices;
- Home Assistant and Matter Server IPv6 unicast, ICMPv6, mDNS, and Matter
  discovery/commissioning traffic;
- required mDNS reflection and SSDP/UPnP discovery between trusted and IoT
  networks;
- `thinkcentre-01` to the MR4U Thread RCP TCP endpoint;
- Zigbee2MQTT pods to the MR4U Zigbee TCP endpoint;
- Home Assistant to the UniFi Protect controller and required cloud endpoints;
- Home Assistant and cluster nodes to Matter Server TCP 5580 and OTBR TCP 8081.

Do not broadly block IPv6 multicast or ICMPv6; Thread routing and Matter
commissioning depend on them. Validate flows before enforcing isolation.

## Persistent volumes, snapshots, and restore order

All five state volumes use `longhorn-retain`: `otbr-data`,
`matter-server-data`, `zigbee2mqtt-data`, `mosquitto-data`, and
`home-assistant-config`. The seven daily Longhorn snapshots are local recovery
points only; there is no off-cluster disaster recovery for these volumes.

Restore in this order: OTBR dataset, Matter fabric, Zigbee2MQTT state,
Mosquitto state, then Home Assistant state. Restore related Thread and Matter
state from compatible points to avoid invalidating commissioned devices.

## Failure behavior

OTBR is eligible only on `thinkcentre-01`; rebooting, draining, or losing that
node interrupts Thread border routing. The PVC and `Recreate` strategy prevent
normal concurrent OTBR instances. Zigbee2MQTT and OTBR intentionally remain
unavailable while their port 0 sentinels are present. Zigbee devices can
continue local mesh behavior during controller downtime, but Home Assistant
events and commands stop. Existing Thread devices may continue local mesh
traffic, but border routing and new commissioning stop when OTBR is down.

## Migrate the Thread dataset to MR4U-hosted OTBR

Use this only when the MR4U's built-in OTBR is considered stable. Never create
a second independent Thread network.

1. Export and securely record the active dataset:
   `kubectl -n apps exec deployment/otbr -- wrap-ot-ctl dataset active -x`.
2. Stop/disable the Kubernetes OTBR Deployment and verify it has released the
   RCP before enabling built-in OTBR on the MR4U.
3. Enable MR4U OTBR and import the same active Thread dataset. Do not create a
   new dataset and do not recommission devices preemptively.
4. Change only Home Assistant's OpenThread Border Router integration URL to
   `http://slzb-mr4u.home.arpa:<OTBR_PORT>`; Matter Server continues using LAN
   IPv6 and its existing WebSocket URL.
5. Verify the dataset identity, OTBR role, existing Matter/Thread devices, and
   automations before deleting or archiving Kubernetes OTBR state.

Rollback by stopping MR4U OTBR before restarting Kubernetes OTBR with its
preserved dataset. At no time may both implementations control the same RCP.

## Runtime verification

```bash
kubectl -n apps get pods -l 'app in (home-assistant,matter-server,mosquitto,otbr,zigbee2mqtt)' -o wide
kubectl -n apps logs deployment/zigbee2mqtt
kubectl -n apps logs deployment/otbr
kubectl -n apps exec deployment/otbr -- wrap-ot-ctl state
kubectl -n apps exec deployment/otbr -- wrap-ot-ctl dataset active -x
kubectl -n apps port-forward service/matter-server 5580:5580
```

Also verify the OTBR API from Home Assistant, Matter WebSocket connectivity,
Zigbee MQTT discovery, IPv6 reachability across the LAN, mDNS discovery from a
commissioning phone, and normal operation after restarting each singleton one
at a time.
