#!/usr/bin/env bash
# Build the test VM's Ignition config and install ISO.
#   WORK=<dir> test/build.sh
# WORK holds the throwaway age key (test.agekey), the SOPS-encrypted test
# secrets (secrets.sops.yaml, encrypted to that key), the CA and the outputs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${WORK:?set WORK to a scratch directory}"
VERSIONS=${VERSIONS:-$WORK/versions.yaml}
FCOS_ISO=${FCOS_ISO:?set FCOS_ISO to a Fedora CoreOS live ISO}
export SOPS_AGE_KEY_FILE=$WORK/test.agekey

# Throwaway CA and *.fcos.test certificate.
if [[ ! -f $WORK/ca.pem ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
    -subj "/CN=fcos.test throwaway CA" -keyout "$WORK/ca.key" -out "$WORK/ca.pem"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=*.fcos.test" -keyout "$WORK/server-key.pem" -out "$WORK/server.csr"
  openssl x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" \
    -CAcreateserial -days 30 -out "$WORK/server.pem" \
    -extfile <(printf 'subjectAltName=DNS:*.fcos.test,DNS:fcos.test\nextendedKeyUsage=serverAuth\n')
  cat "$WORK/server.pem" "$WORK/ca.pem" > "$WORK/server-chain.pem"
fi

sed "s|^BACKUP_AGE_RECIPIENT=.*|BACKUP_AGE_RECIPIENT=$(age-keygen -y "$WORK/test.agekey")|" \
  "$here/host.env" > "$WORK/host.env"
HOST_ENV=$WORK/host.env SECRETS=$WORK/secrets.sops.yaml VERSIONS=$VERSIONS \
  OUT=$WORK/render "$here/../render.sh"

sed -E -e '/--machine-api-(cert|key)=/d' \
  -e 's|--machine-api-advertised-url=https://[^ ]*|--machine-api-advertised-url=grpc://10.0.2.2:8090/|' \
  -e 's|--etcd-backup-s3$|--etcd-backup-s3 \\\n  --create-initial-service-account \\\n  --initial-service-account-role=Admin \\\n  --initial-service-account-lifetime=720h \\\n  --initial-service-account-key-path=/_out/initial-sa.key|' \
  "$WORK/render/files/units/omni.service" > "$WORK/omni.service"
# Patch the rendered file and re-run Butane: a file in the overlay would
# lose, because Ignition lets a merged config override the one merging it.
cp "$WORK/omni.service" "$WORK/render/files/units/omni.service"
butane --strict --files-dir "$WORK/render" "$WORK/render/omni.bu" > "$WORK/omni.ign"
butane --strict --files-dir "$WORK" "$here/overlay.bu" > "$WORK/test.ign"

# coreos-installer refuses to replace an existing output file.
[[ -f $WORK/install.iso ]] && mv -f "$WORK/install.iso" "$WORK/install.iso.old"
docker run --rm -v "$WORK:/work" -v "$here/..:/src:ro" -v "$(dirname "$FCOS_ISO"):/iso:ro" \
  quay.io/coreos/coreos-installer:release iso customize --force \
  --dest-device /dev/vda --dest-ignition /work/test.ign \
  --dest-console ttyAMA0,115200n8 \
  --installer-config /src/installer.yaml \
  -o /work/install.iso "/iso/$(basename "$FCOS_ISO")"
echo "wrote $WORK/install.iso"
