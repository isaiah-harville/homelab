# Home Automation Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the GitOps-managed Home Assistant stack with LAN discovery, authenticated MQTT, independent Zigbee and Thread radios, Kubernetes-hosted OTBR, Matter, monitoring, and operating documentation.

**Architecture:** Raw manifests remain in the shared `apps` namespace and parent Flux apps Kustomization. Home Assistant, Matter Server, and OTBR use host networking where multicast/IPv6 requires it; Mosquitto and Zigbee2MQTT use normal pod networking and Kubernetes DNS. Longhorn-retain PVCs preserve all controller state, while a Talos patch prepares and labels `thinkcentre-01` for the singleton OTBR workload.

**Tech Stack:** FluxCD, Kustomize, Kubernetes Deployments/Services/PVCs, Talos Linux, Omni Terraform provider, SOPS/age, Traefik, Longhorn, kube-prometheus-stack, Home Assistant 2026.8.2, Zigbee2MQTT 2.13.0, Mosquitto 2.0.22, Matter Server 1.4.0, OTBR TCP source `a04da0c`.

**Spec:** `docs/superpowers/specs/2026-08-20-home-automation-design.md`

## Global Constraints

- Keep all smart-home Kubernetes resources in namespace `apps` and under `apps/base/home-automation/`.
- Keep MQTT cluster-internal and anonymous access disabled.
- Allocate the MR3U CC2674P10 radio to Zigbee (`zstack`) and EFR32MG24 to Thread RCP; never use single-radio multiprotocol firmware.
- Do not guess either final MR3U TCP port. Use port `0` as an invalid, startup-blocking sentinel until the user supplies the configured values.
- Use `hostNetwork: true` plus `dnsPolicy: ClusterFirstWithHostNet` for Home Assistant, Matter Server, and OTBR.
- OTBR must use one replica, `Recreate`, `/dev/net/tun`, and only `NET_ADMIN` plus `IPC_LOCK`; do not use a privileged container.
- Only nodes with `home.harville.dev/otbr: "true"` may run OTBR. Initially only `thinkcentre-01` receives the complete Talos patch.
- Pin every image to a concrete version. Pin Matter Server and OTBR to multi-architecture image digests; never use `latest` or `stable`.
- Use `longhorn-retain` for Home Assistant, Zigbee2MQTT, Mosquitto, Matter, and OTBR state.
- Keep credentials in SOPS-encrypted Secrets. Do not commit ecobee, UniFi, HomeKit, Matter, or device credentials/pairing codes.
- Do not add restrictive NetworkPolicies around host-networked discovery traffic before the future VLAN design is known.
- Preserve Home Assistant's `default_config`, native dashboards, automation/script/scene editors, and UI-managed `.storage` state.
- Treat seven daily Longhorn snapshots as local recovery only; do not represent them as off-cluster disaster recovery.

---

### Task 1: Harden the Existing MQTT and Zigbee Foundation

**Files:**
- Modify: `apps/base/home-automation/mosquitto.yaml`
- Modify: `apps/base/home-automation/zigbee2mqtt.yaml`
- Modify: `clusters/homelab/apps/kustomization.yaml`

**Interfaces:**
- Consumes: SOPS Secrets `apps/mosquitto-passwd` and `apps/mosquitto-clients`.
- Produces: MQTT at `mqtt://mosquitto.apps.svc.cluster.local:1883`; Zigbee frontend at `zigbee2mqtt.apps.svc.cluster.local:8080`; configurable `zigbee2mqtt-adapter` keys `serial_port`, `serial_adapter`, and `serial_baudrate`.

- [ ] **Step 1: Run render assertions that expose the current radio-allocation failure**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
cm=docs.find { |d| d.is_a?(Hash) && d["kind"]=="ConfigMap" && d.dig("metadata","name")=="zigbee2mqtt-adapter" };
abort "missing adapter ConfigMap" unless cm;
abort "Zigbee must use zstack" unless cm.dig("data","serial_adapter")=="zstack";
abort "missing baud" unless cm.dig("data","serial_baudrate");
' /tmp/home-automation.yaml
```

Expected: FAIL with `Zigbee must use zstack` because the current manifest uses the EFR32/`ember` radio.

- [ ] **Step 2: Make the Zigbee endpoint explicit and fail safely before hardware configuration**

Change `zigbee2mqtt-adapter.data` to:

```yaml
data:
  # Radio 2 / CC2674P10 is reserved for Zigbee. Replace port 0 with the
  # endpoint shown by the configured MR3U; never point this at Radio 1.
  serial_port: tcp://slzb-mr3u.home.arpa:0
  serial_adapter: zstack
  serial_baudrate: "115200"
```

Add this init container before the Zigbee2MQTT container:

```yaml
initContainers:
  - name: validate-radio-config
    image: busybox:1.37.0
    command:
      - sh
      - -ec
      - |
        case "${SERIAL_PORT}" in
          tcp://*:0)
            echo "Set zigbee2mqtt-adapter serial_port to the MR3U CC2674P10 Zigbee endpoint" >&2
            exit 1
            ;;
          tcp://*:*) ;;
          *)
            echo "serial_port must be a tcp:// URL" >&2
            exit 1
            ;;
        esac
    env:
      - name: SERIAL_PORT
        valueFrom:
          configMapKeyRef:
            name: zigbee2mqtt-adapter
            key: serial_port
```

Add `ZIGBEE2MQTT_CONFIG_SERIAL_BAUDRATE` from `serial_baudrate`, use the fully qualified MQTT URL, and keep all runtime-owned files on `/app/data`:

```yaml
- name: ZIGBEE2MQTT_CONFIG_MQTT_SERVER
  value: mqtt://mosquitto.apps.svc.cluster.local:1883
- name: ZIGBEE2MQTT_CONFIG_SERIAL_BAUDRATE
  valueFrom:
    configMapKeyRef:
      name: zigbee2mqtt-adapter
      key: serial_baudrate
```

- [ ] **Step 3: Make Mosquitto persistence bounds explicit**

Keep `eclipse-mosquitto:2.0.22`, authentication, the password file, and stdout logging. Add:

```text
autosave_on_changes true
persistent_client_expiration 14d
max_queued_messages 1000
max_queued_bytes 10485760
```

These settings retain device state while preventing abandoned clients from growing the broker database without bound.

- [ ] **Step 4: Ensure both MQTT Secrets trigger the correct singleton rollouts**

Retain the existing `mosquitto-passwd` replacement targeting `Deployment/mosquitto`. Extend the `mosquitto-clients` replacement so it targets both `Deployment/zigbee2mqtt` and `Deployment/mosquitto`, using annotation key `mosquitto-clients-mac`. Do not inject plaintext Secret values into annotations.

- [ ] **Step 5: Re-run the focused and full render checks**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
cm=docs.find { |d| d.is_a?(Hash) && d["kind"]=="ConfigMap" && d.dig("metadata","name")=="zigbee2mqtt-adapter" };
abort unless cm.dig("data","serial_adapter")=="zstack";
abort unless cm.dig("data","serial_port")=="tcp://slzb-mr3u.home.arpa:0";
abort unless cm.dig("data","serial_baudrate")=="115200";
' /tmp/home-automation.yaml
```

Expected: PASS. `kubectl kustomize` must emit no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/base/home-automation/mosquitto.yaml apps/base/home-automation/zigbee2mqtt.yaml clusters/homelab/apps/kustomization.yaml
git commit -m "feat(home-automation): harden MQTT and Zigbee radio config"
```

### Task 2: Enable Home Assistant LAN Discovery and UI Persistence

**Files:**
- Modify: `apps/base/home-automation/home-assistant.yaml`

**Interfaces:**
- Consumes: Traefik requests through `Service/home-assistant`; LAN multicast on the selected node.
- Produces: Home Assistant HTTP/WebSocket on port 8123; persistent Lovelace dashboards, automations, scripts, scenes, integrations, and HomeKit pairing state under `/config`.

- [ ] **Step 1: Prove the current pod does not use the required discovery network mode**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
d=docs.find { |x| x.is_a?(Hash) && x["kind"]=="Deployment" && x.dig("metadata","name")=="home-assistant" };
abort "Home Assistant must use hostNetwork" unless d.dig("spec","template","spec","hostNetwork")==true;
abort "wrong DNS policy" unless d.dig("spec","template","spec","dnsPolicy")=="ClusterFirstWithHostNet";
' /tmp/home-automation.yaml
```

Expected: FAIL with `Home Assistant must use hostNetwork`.

- [ ] **Step 2: Add host networking without adding device privileges**

Under the Home Assistant pod spec add:

```yaml
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
terminationGracePeriodSeconds: 60
securityContext:
  runAsUser: 0
  runAsGroup: 0
  fsGroup: 0
  seccompProfile:
    type: RuntimeDefault
```

Do not add `privileged`, `hostPID`, `hostIPC`, capabilities, hostPath volumes, or USB devices. Keep `default_config`, the Git-owned base configuration, the `/config` PVC, the ClusterIP Service, and the existing internal Ingress.

- [ ] **Step 3: Update Home Assistant to the current patch release**

Set:

```yaml
image: ghcr.io/home-assistant/home-assistant:2026.8.2
```

Keep `Recreate`, one replica, and the existing startup/readiness/liveness probes.

- [ ] **Step 4: Verify host networking, dashboard enablement, and ingress**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
d=docs.find { |x| x.is_a?(Hash) && x["kind"]=="Deployment" && x.dig("metadata","name")=="home-assistant" };
abort unless d.dig("spec","template","spec","hostNetwork")==true;
abort unless d.dig("spec","template","spec","dnsPolicy")=="ClusterFirstWithHostNet";
abort if d.dig("spec","template","spec","containers",0,"securityContext","privileged");
cm=docs.find { |x| x.is_a?(Hash) && x["kind"]=="ConfigMap" && x.dig("metadata","name")=="home-assistant-configuration" };
abort "default_config missing" unless cm.dig("data","configuration.yaml").include?("default_config:");
' /tmp/home-automation.yaml
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/base/home-automation/home-assistant.yaml
git commit -m "feat(home-automation): enable Home Assistant LAN discovery"
```

### Task 3: Add the Current Matter Server

**Files:**
- Create: `apps/base/home-automation/matter-server.yaml`
- Modify: `apps/base/home-automation/kustomization.yaml`

**Interfaces:**
- Consumes: LAN IPv6/mDNS and OTBR-advertised Thread routes.
- Produces: Python-compatible Matter WebSocket API at `ws://matter-server.apps.svc.cluster.local:5580/ws`; internal-LAN dashboard/API on the scheduled node's host-network port 5580, with no Ingress.

- [ ] **Step 1: Write a render assertion for the absent Matter workload**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
abort "matter-server missing" unless docs.any? { |d| d.is_a?(Hash) && d["kind"]=="Deployment" && d.dig("metadata","name")=="matter-server" };
' /tmp/home-automation.yaml
```

Expected: FAIL with `matter-server missing`.

- [ ] **Step 2: Create the Matter PVC, singleton Deployment, and Service**

Create `matter-server.yaml` with these resource contracts:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: matter-server-data
  namespace: apps
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-retain
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: matter-server
  namespace: apps
  labels: &labels
    app: matter-server
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: *labels
  template:
    metadata:
      labels: *labels
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      enableServiceLinks: false
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: matter-server
          image: ghcr.io/matter-js/matterjs-server:1.4.0@sha256:54232d0d3e7dff5a54759469d2753399270412b4c30c55b31750a4595e4cb236
          ports:
            - name: websocket
              containerPort: 5580
          env:
            - name: STORAGE_PATH
              value: /data
            - name: PORT
              value: "5580"
            - name: LOG_LEVEL
              value: info
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              memory: 2Gi
          startupProbe:
            httpGet:
              path: /
              port: websocket
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /
              port: websocket
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: websocket
            periodSeconds: 30
            failureThreshold: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: matter-server-data
---
apiVersion: v1
kind: Service
metadata:
  name: matter-server
  namespace: apps
spec:
  selector:
    app: matter-server
  ports:
    - name: websocket
      port: 5580
      targetPort: websocket
```

- [ ] **Step 3: Register the Matter resource**

Add `matter-server.yaml` to `apps/base/home-automation/kustomization.yaml`. Do not add an Ingress.

- [ ] **Step 4: Verify the Matter contract**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
d=docs.find { |x| x.is_a?(Hash) && x["kind"]=="Deployment" && x.dig("metadata","name")=="matter-server" };
abort unless d.dig("spec","strategy","type")=="Recreate";
abort unless d.dig("spec","template","spec","hostNetwork")==true;
abort unless d.dig("spec","template","spec","dnsPolicy")=="ClusterFirstWithHostNet";
image=d.dig("spec","template","spec","containers",0,"image");
abort unless image.include?("matterjs-server:1.4.0@sha256:");
abort if docs.any? { |x| x.is_a?(Hash) && x["kind"]=="Ingress" && x.dig("metadata","name")=="matter-server" };
' /tmp/home-automation.yaml
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/base/home-automation/matter-server.yaml apps/base/home-automation/kustomization.yaml
git commit -m "feat(home-automation): add Matter server"
```

### Task 4: Prepare `thinkcentre-01` for OTBR in Talos and Omni

**Files:**
- Create: `talos/omni/patches/otbr-host.yaml`
- Modify: `talos/omni/cluster-template.yaml`
- Modify: `terraform/omni/locals.tf`
- Modify: `terraform/omni/patches.tf`

**Interfaces:**
- Consumes: worker machine ID `9ba21500-a881-11e5-ae5a-d524518f0c00` (`thinkcentre-01`).
- Produces: node label `home.harville.dev/otbr=true`, IPv4/IPv6 forwarding, IPv6 RA route-information acceptance, and a selector target for `Deployment/otbr`.

- [ ] **Step 1: Prove the topology does not yet assign an OTBR patch**

Run:

```bash
rg -n 'otbr-host|otbr_nodes|home.harville.dev/otbr' talos/omni terraform/omni
```

Expected: FAIL with no matches and exit status 1.

- [ ] **Step 2: Create the reusable Talos host patch**

Create `talos/omni/patches/otbr-host.yaml`:

```yaml
# OTBR needs host routing and a scheduling capability label. Talos already
# exposes /dev/net/tun; the pod maps that character device explicitly.
---
machine:
  nodeLabels:
    home.harville.dev/otbr: "true"
  sysctls:
    net.ipv4.ip_forward: "1"
    net.ipv6.conf.all.forwarding: "1"
    net.ipv6.conf.default.forwarding: "1"
    net.ipv6.conf.all.accept_ra: "2"
    net.ipv6.conf.default.accept_ra: "2"
    net.ipv6.conf.all.accept_ra_rt_info_max_plen: "64"
    net.ipv6.conf.default.accept_ra_rt_info_max_plen: "64"
```

- [ ] **Step 3: Assign the patch in the manual Omni template**

Under the `thinkcentre-01` Machine entry in `talos/omni/cluster-template.yaml`, add:

```yaml
  - name: otbr-host
    file: patches/otbr-host.yaml
```

Do not assign it to `dl380` or any control-plane node.

- [ ] **Step 4: Declare the identical Terraform selection**

Add to `terraform/omni/locals.tf`:

```hcl
  otbr_nodes = [
    "9ba21500-a881-11e5-ae5a-d524518f0c00", # thinkcentre-01
  ]
```

Add to `terraform/omni/patches.tf`:

```hcl
resource "omni_config_patch" "otbr_host" {
  for_each = toset(local.otbr_nodes)

  name    = "otbr-host"
  cluster = omni_cluster.homelab.name
  weight  = 403
  selector = {
    cluster_machine = each.value
  }
  data = file("${local.patch_dir}/otbr-host.yaml")
}
```

- [ ] **Step 5: Verify topology parity and Terraform formatting**

Run:

```bash
terraform -chdir=terraform/omni fmt -check -recursive
ruby -e '
t=File.read("talos/omni/cluster-template.yaml");
f=File.read("terraform/omni/locals.tf");
p=File.read("terraform/omni/patches.tf");
id="9ba21500-a881-11e5-ae5a-d524518f0c00";
abort unless t.include?("name: otbr-host") && t.include?(id);
abort unless f.include?("otbr_nodes") && f.include?(id);
abort unless p.include?("omni_config_patch\" \"otbr_host") && p.include?("otbr-host.yaml");
'
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add talos/omni/patches/otbr-host.yaml talos/omni/cluster-template.yaml terraform/omni/locals.tf terraform/omni/patches.tf
git commit -m "feat(talos): prepare thinkcentre for OTBR"
```

### Task 5: Add Singleton Kubernetes OTBR

**Files:**
- Create: `apps/base/home-automation/otbr.yaml`
- Modify: `apps/base/home-automation/kustomization.yaml`

**Interfaces:**
- Consumes: MR3U EFR32MG24 Thread TCP endpoint; host label `home.harville.dev/otbr=true`; host `/dev/net/tun`; Longhorn.
- Produces: standard OTBR REST API at `http://otbr.apps.svc.cluster.local:8081`; persisted Thread operational dataset under `/var/lib/thread`.

- [ ] **Step 1: Write a render assertion for singleton and privilege invariants**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
d=docs.find { |x| x.is_a?(Hash) && x["kind"]=="Deployment" && x.dig("metadata","name")=="otbr" };
abort "otbr missing" unless d;
' /tmp/home-automation.yaml
```

Expected: FAIL with `otbr missing`.

- [ ] **Step 2: Create OTBR configuration, state, Deployment, and Service**

Create `otbr.yaml` containing:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otbr-config
  namespace: apps
data:
  RCP_USE_TCP: "1"
  RCP_HOST: slzb-mr3u.home.arpa
  # Replace 0 with the configured EFR32MG24 Thread RCP endpoint.
  RCP_PORT: "0"
  RCP_TTY: /tmp/ttyOTBR
  RCP_BAUDRATE: "460800"
  # Network RCP mode normally does not use UART hardware flow control. Keep
  # this configurable if the installed firmware requires it.
  OTBR_RCP_ADDITIONAL_ARGS: ""
  # Replace with thinkcentre-01's physical LAN interface after verification.
  OTBR_BACKBONE_IF: change-me
  OTBR_THREAD_IF: wpan0
  OTBR_REST_LISTEN_ADDRESS: 0.0.0.0
  OTBR_REST_LISTEN_PORT: "8081"
  OTBR_LOG_LEVEL_INT: "6"
  OTBR_WEB_ENABLE: "0"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: otbr-data
  namespace: apps
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-retain
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otbr
  namespace: apps
  labels: &labels
    app: otbr
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: *labels
  template:
    metadata:
      labels: *labels
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      enableServiceLinks: false
      terminationGracePeriodSeconds: 60
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: home.harville.dev/otbr
                    operator: In
                    values: ["true"]
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values: [thinkcentre-01]
      initContainers:
        - name: validate-host-and-radio
          image: busybox:1.37.0
          command:
            - sh
            - -ec
            - |
              test "${RCP_PORT}" -ge 1 && test "${RCP_PORT}" -le 65535 || {
                echo "Set otbr-config RCP_PORT to the MR3U EFR32MG24 Thread endpoint" >&2
                exit 1
              }
              test "${OTBR_BACKBONE_IF}" != change-me || {
                echo "Set otbr-config OTBR_BACKBONE_IF to thinkcentre-01's LAN interface" >&2
                exit 1
              }
              test -c /dev/net/tun
              test -d "/sys/class/net/${OTBR_BACKBONE_IF}"
              test "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1
          envFrom:
            - configMapRef:
                name: otbr-config
          volumeMounts:
            - name: tun
              mountPath: /dev/net/tun
      containers:
        - name: otbr
          image: docker.io/bnutzer/otbr-tcp:sha-a04da0c@sha256:881514caacf0829ffac7edca44f538010af0c098e9f817b939612e66a21f4004
          envFrom:
            - configMapRef:
                name: otbr-config
          ports:
            - name: rest
              containerPort: 8081
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
              add: [IPC_LOCK, NET_ADMIN]
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: data
              mountPath: /var/lib/thread
            - name: tun
              mountPath: /dev/net/tun
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
          startupProbe:
            exec:
              command: [wrap-ot-ctl, state]
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            exec:
              command: [wrap-ot-ctl, state]
            periodSeconds: 10
          livenessProbe:
            exec:
              command: [wrap-ot-ctl, state]
            periodSeconds: 30
            failureThreshold: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: otbr-data
        - name: tun
          hostPath:
            path: /dev/net/tun
            type: CharDevice
---
apiVersion: v1
kind: Service
metadata:
  name: otbr
  namespace: apps
spec:
  selector:
    app: otbr
  ports:
    - name: rest
      port: 8081
      targetPort: rest
```

- [ ] **Step 3: Register OTBR without adding an Ingress or PDB**

Add `otbr.yaml` to `apps/base/home-automation/kustomization.yaml`. Do not add a PodDisruptionBudget while only one node is eligible.

- [ ] **Step 4: Verify singleton, scheduling, state, networking, and privilege invariants**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
d=docs.find { |x| x.is_a?(Hash) && x["kind"]=="Deployment" && x.dig("metadata","name")=="otbr" };
abort unless d.dig("spec","replicas")==1;
abort unless d.dig("spec","strategy","type")=="Recreate";
s=d.dig("spec","template","spec");
abort unless s["hostNetwork"]==true && s["dnsPolicy"]=="ClusterFirstWithHostNet";
abort unless s.dig("affinity","nodeAffinity","requiredDuringSchedulingIgnoredDuringExecution").to_s.include?("home.harville.dev/otbr");
c=s["containers"].find { |x| x["name"]=="otbr" };
abort if c.dig("securityContext","privileged");
caps=c.dig("securityContext","capabilities","add");
abort unless caps.sort==["IPC_LOCK","NET_ADMIN"];
abort unless c["image"].include?("@sha256:");
abort if docs.any? { |x| x.is_a?(Hash) && x["kind"]=="Ingress" && x.dig("metadata","name")=="otbr" };
' /tmp/home-automation.yaml
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/base/home-automation/otbr.yaml apps/base/home-automation/kustomization.yaml
git commit -m "feat(home-automation): add singleton Kubernetes OTBR"
```

### Task 6: Add Smart-Home Availability Monitoring

**Files:**
- Create: `apps/base/home-automation/monitoring.yaml`
- Modify: `apps/base/home-automation/kustomization.yaml`

**Interfaces:**
- Consumes: kube-state-metrics series already scraped by kube-prometheus-stack.
- Produces: `HomeAutomationWorkloadUnavailable` and `HomeAutomationContainerRestarting` alerts for the five Deployments.

- [ ] **Step 1: Prove no smart-home PrometheusRule exists**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
abort "monitoring missing" unless docs.any? { |d| d.is_a?(Hash) && d["kind"]=="PrometheusRule" && d.dig("metadata","name")=="home-automation" };
' /tmp/home-automation.yaml
```

Expected: FAIL with `monitoring missing`.

- [ ] **Step 2: Create availability and restart alerts**

Create `monitoring.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: home-automation
  namespace: apps
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: home-automation
      rules:
        - alert: HomeAutomationWorkloadUnavailable
          expr: |
            kube_deployment_status_replicas_available{
              namespace="apps",
              deployment=~"home-assistant|matter-server|mosquitto|otbr|zigbee2mqtt"
            } < 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.deployment }} is unavailable"
            description: >-
              The home-automation Deployment has had no available replica for
              15 minutes. OTBR and Zigbee2MQTT are expected to remain
              unavailable while their MR3U endpoint uses the port-0 sentinel.
        - alert: HomeAutomationContainerRestarting
          expr: |
            increase(kube_pod_container_status_restarts_total{
              namespace="apps",
              container=~"home-assistant|matter-server|mosquitto|otbr|zigbee2mqtt"
            }[30m]) > 3
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.container }} is restarting repeatedly"
            description: >-
              The smart-home container restarted more than three times in the
              last 30 minutes.
```

- [ ] **Step 3: Register and render the rule**

Add `monitoring.yaml` to the component Kustomization, then run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0]));
r=docs.find { |d| d.is_a?(Hash) && d["kind"]=="PrometheusRule" && d.dig("metadata","name")=="home-automation" };
names=r.dig("spec","groups").flat_map { |g| g["rules"] }.map { |x| x["alert"] };
abort unless names==["HomeAutomationWorkloadUnavailable","HomeAutomationContainerRestarting"];
' /tmp/home-automation.yaml
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/base/home-automation/monitoring.yaml apps/base/home-automation/kustomization.yaml
git commit -m "feat(home-automation): monitor smart-home workloads"
```

### Task 7: Write Installation, Pairing, Integration, and Recovery Runbooks

**Files:**
- Create: `docs/apps/home-automation.md`
- Modify: `docs/apps/README.md`
- Modify: `docs/operations/backups.md`

**Interfaces:**
- Consumes: the manifest ConfigMaps, Services, PVCs, SOPS Secrets, and Home Assistant UI.
- Produces: the exact post-hardware workflow and migration/recovery procedures operators follow.

- [ ] **Step 1: Prove the app runbook is absent**

Run:

```bash
test -f docs/apps/home-automation.md
```

Expected: FAIL.

- [ ] **Step 2: Write the home-automation runbook**

Create `docs/apps/home-automation.md` with these concrete sections and commands:

```markdown
# Home automation

## Architecture and service names
## Before enabling the MR3U workloads
## MR3U radio allocation and firmware modes
## Configure Zigbee2MQTT
## Configure OTBR and verify IPv6/TUN
## Add MQTT, Matter, Thread, and OTBR integrations
## Home Assistant dashboards and automation editors
## THIRDREALITY pairing and naming workflow
## HomeKit Device and HomeKit Bridge
## ecobee authorization
## UniFi Protect service account
## VLAN and firewall flows
## Persistent volumes, snapshots, and restore order
## Failure behavior
## Migrate the Thread dataset to MR3U-hosted OTBR
## Runtime verification
```

The runbook must state the exact edits:

```text
apps/base/home-automation/zigbee2mqtt.yaml:
  zigbee2mqtt-adapter.data.serial_port

apps/base/home-automation/otbr.yaml:
  otbr-config.data.RCP_HOST
  otbr-config.data.RCP_PORT
  otbr-config.data.RCP_BAUDRATE
  otbr-config.data.OTBR_RCP_ADDITIONAL_ARGS
  otbr-config.data.OTBR_BACKBONE_IF
```

Include these verification commands:

```bash
kubectl -n apps get pods -l 'app in (home-assistant,matter-server,mosquitto,otbr,zigbee2mqtt)' -o wide
kubectl -n apps logs deployment/zigbee2mqtt
kubectl -n apps logs deployment/otbr
kubectl -n apps exec deployment/otbr -- wrap-ot-ctl state
kubectl -n apps exec deployment/otbr -- wrap-ot-ctl dataset active -x
kubectl -n apps port-forward service/matter-server 5580:5580
```

Document the UI URLs and settings:

```text
Home Assistant: https://home-assistant.int.harville.dev
Zigbee2MQTT:    https://zigbee2mqtt.int.harville.dev
MQTT broker:   mqtt://mosquitto.apps.svc.cluster.local:1883
Matter Server: ws://matter-server.apps.svc.cluster.local:5580/ws
OTBR API:      http://otbr.apps.svc.cluster.local:8081
```

For UniFi Protect, specify a dedicated local account with Protect viewer access and no UniFi OS administrator role. For HomeKit, explain HomeKit Device versus HomeKit Bridge and prohibit re-exporting imported accessories. State that host-network ports 5580 and 8081 are reachable on their nodes' LAN addresses even without Ingress, and require future UniFi firewall rules to limit them to Home Assistant and cluster-node sources. For Thread migration, require exporting the current active dataset, stopping Kubernetes OTBR before enabling MR3U OTBR, importing the same dataset, changing only the Home Assistant OTBR URL, and verifying existing devices before deleting anything.

- [ ] **Step 3: Register the runbook and record the backup gap**

Add this link to `docs/apps/README.md`:

```markdown
- [Home automation](home-automation.md)
```

Extend `docs/operations/backups.md` with a `Home automation` section naming all five PVCs, their restore order, seven-day Longhorn snapshot coverage, and the absence of off-cluster disaster recovery.

- [ ] **Step 4: Verify required operational topics are present**

Run:

```bash
for term in HomeKit ecobee 'UniFi Protect' THIRDREALITY 'Thread dataset' 'port 0' 'longhorn-retain'; do
  rg -q "$term" docs/apps/home-automation.md || exit 1
done
rg -q 'home-assistant-config' docs/operations/backups.md
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/apps/home-automation.md docs/apps/README.md docs/operations/backups.md
git commit -m "docs(home-automation): add setup and recovery runbook"
```

### Task 8: Final Static and Runtime-Safe Verification

**Files:**
- Modify only if validation reveals a defect in files changed by Tasks 1–7.

**Interfaces:**
- Consumes: the complete rendered repo and Terraform/Talos declarations.
- Produces: evidence that the GitOps configuration is internally consistent and safe to reconcile before the hardware arrives.

- [ ] **Step 1: Validate every Kustomization**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/dev/null
kubectl kustomize clusters/homelab/infra >/dev/null
kubectl kustomize clusters/homelab/flux-system >/dev/null
```

Expected: all exit 0.

- [ ] **Step 2: Validate the complete smart-home contract**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/home-automation.yaml
ruby -ryaml -e '
docs=YAML.load_stream(File.read(ARGV[0])).select { |d| d.is_a?(Hash) };
names=%w[home-assistant matter-server mosquitto otbr zigbee2mqtt];
deploys=docs.select { |d| d["kind"]=="Deployment" }.to_h { |d| [d.dig("metadata","name"),d] };
abort "missing Deployment" unless names.all? { |n| deploys.key?(n) };
%w[home-assistant matter-server otbr].each do |n|
  s=deploys[n].dig("spec","template","spec");
  abort "#{n} host networking" unless s["hostNetwork"]==true && s["dnsPolicy"]=="ClusterFirstWithHostNet";
end;
o=deploys["otbr"];
abort "OTBR singleton" unless o.dig("spec","replicas")==1 && o.dig("spec","strategy","type")=="Recreate";
images=deploys.values.flat_map { |d| d.dig("spec","template","spec","containers") }.map { |c| c["image"] };
abort "latest image" if images.any? { |i| i.end_with?(":latest") || i.end_with?(":stable") };
ingresses=docs.select { |d| d["kind"]=="Ingress" }.map { |d| d.dig("metadata","name") };
abort "internal service exposed" if (ingresses & %w[matter-server mosquitto otbr]).any?;
pvcs=docs.select { |d| d["kind"]=="PersistentVolumeClaim" && %w[home-assistant-config matter-server-data mosquitto-data otbr-data zigbee2mqtt-data].include?(d.dig("metadata","name")) };
abort "PVC storage class" unless pvcs.length==5 && pvcs.all? { |p| p.dig("spec","storageClassName")=="longhorn-retain" };
' /tmp/home-automation.yaml
```

Expected: PASS.

- [ ] **Step 3: Validate Terraform and repository policy**

Run:

```bash
terraform -chdir=terraform/omni fmt -check -recursive
uvx pre-commit run --all-files
git diff --check
```

Expected: all exit 0 with no warnings requiring changes.

- [ ] **Step 4: Review secrets and intended pre-hardware failure state**

Run:

```bash
rg -n 'password:|token:|api[_-]?key:|pairing' apps/base/home-automation docs/apps/home-automation.md
rg -n 'RCP_PORT: "0"|serial_port: tcp://slzb-mr3u.home.arpa:0|OTBR_BACKBONE_IF: change-me' apps/base/home-automation
```

Expected: the first command finds only documentation/configuration-key references and no credentials. The second finds exactly the intentional startup-blocking sentinels documented in the runbook.

- [ ] **Step 5: Confirm the worktree and commit any validation corrections**

Run:

```bash
git status --short
```

If validation required corrections, commit only those scoped corrections:

```bash
git add apps/base/home-automation clusters/homelab/apps talos/omni terraform/omni docs/apps docs/operations/backups.md
git commit -m "fix(home-automation): satisfy final validation"
```

If no corrections were required, do not create an empty commit.
