#!/usr/bin/env ruby

require "open3"
require "yaml"


def render(path)
  output, status = Open3.capture2e("kubectl", "kustomize", path)
  abort "failed to render #{path}:\n#{output}" unless status.success?
  YAML.load_stream(output).compact
end


def resource!(documents, kind, name, namespace)
  resource = documents.find do |document|
    document["kind"] == kind &&
      document.dig("metadata", "name") == name &&
      document.dig("metadata", "namespace") == namespace
  end
  abort "missing #{kind} #{namespace}/#{name}" unless resource
  resource
end


def excludes_hostname?(pod_spec, hostname)
  terms = pod_spec.dig(
    "affinity", "nodeAffinity", "requiredDuringSchedulingIgnoredDuringExecution",
    "nodeSelectorTerms"
  ) || []
  terms.any? do |term|
    (term["matchExpressions"] || []).any? do |expression|
      expression["key"] == "kubernetes.io/hostname" &&
        expression["operator"] == "NotIn" &&
        Array(expression["values"]).include?(hostname)
    end
  end
end


apps = render("clusters/homelab/apps")
deployment = resource!(apps, "Deployment", "qbittorrent", "apps")
pod_spec = deployment.dig("spec", "template", "spec")
gluetun = pod_spec.fetch("initContainers").find { |item| item["name"] == "gluetun" }
qbit = pod_spec.fetch("containers").find { |item| item["name"] == "qbittorrent" }
abort "missing Gluetun sidecar" unless gluetun
abort "missing qBittorrent container" unless qbit
abort "Gluetun is not a native sidecar" unless gluetun["restartPolicy"] == "Always"
gluetun_caps = Array(gluetun.dig("securityContext", "capabilities", "add")).sort
abort "Gluetun missing required capabilities" unless gluetun_caps == %w[CHOWN DAC_OVERRIDE NET_ADMIN SETUID]
abort "qBittorrent unexpectedly privileged" if qbit.dig("securityContext", "privileged")
abort "qBittorrent must let s6 initialize as root" if qbit.dig("securityContext", "runAsUser")
abort "qBittorrent must drop service privileges" unless qbit.fetch("env").any? { |item| item == { "name" => "PUID", "value" => "1000" } }
qbit_caps = Array(qbit.dig("securityContext", "capabilities", "add")).sort
abort "qBittorrent missing s6 capabilities" unless qbit_caps == %w[CHOWN DAC_OVERRIDE SETGID SETUID]
abort "DL380 exclusion missing" unless excludes_hostname?(pod_spec, "talos-rwj-wvp")

downloads = resource!(apps, "PersistentVolumeClaim", "qbittorrent-downloads", "apps")
abort "downloads must be RWX" unless downloads.dig("spec", "accessModes") == ["ReadWriteMany"]
abort "downloads must be 50Gi" unless downloads.dig("spec", "resources", "requests", "storage") == "50Gi"

ingress = resource!(apps, "Ingress", "qbittorrent", "apps")
abort "wrong qBittorrent host" unless ingress.dig("spec", "rules", 0, "host") == "torrent.int.harville.dev"
abort "wrong qBittorrent ingress class" unless ingress.dig("spec", "ingressClassName") == "traefik-internal"
middleware = ingress.dig("metadata", "annotations", "traefik.ingress.kubernetes.io/router.middlewares")
abort "missing Authentik middleware" unless middleware == "apps-authentik-forwardauth@kubernetescrd"

cronjob = resource!(apps, "CronJob", "qbittorrent-cleanup", "apps")
abort "cleanup must run daily" unless cronjob.dig("spec", "schedule") == "15 6 * * *"
abort "cleanup pod label missing" unless cronjob.dig(
  "spec", "jobTemplate", "spec", "template", "metadata", "labels",
  "app.kubernetes.io/name"
) == "qbittorrent-cleanup"

network_policy = resource!(apps, "NetworkPolicy", "qbittorrent-webui", "apps")
abort "qBittorrent NetworkPolicy selector missing" unless network_policy.dig(
  "spec", "podSelector", "matchLabels", "app.kubernetes.io/name"
) == "qbittorrent"

scripts = apps.find do |document|
  document["kind"] == "ConfigMap" &&
    document.dig("metadata", "namespace") == "apps" &&
    document.dig("metadata", "name").start_with?("qbittorrent-scripts-")
end
abort "missing qBittorrent scripts ConfigMap" unless scripts
bootstrap = scripts.dig("data", "bootstrap.py")
abort "qBittorrent Authentik subnet bypass missing" unless bootstrap.include?(
  '"WebUI\\\\AuthSubnetWhitelist": "10.244.0.0/16"'
)

books = resource!(apps, "Deployment", "books", "apps")
books_spec = books.dig("spec", "template", "spec")
shelfmark = books_spec.fetch("containers").find { |item| item["name"] == "shelfmark" }
shelfmark_env = shelfmark.fetch("env").to_h { |item| [item["name"], item] }
expected_env = {
  "PROWLARR_TORRENT_CLIENT" => "qbittorrent",
  "QBITTORRENT_URL" => "http://qbittorrent.apps.svc:8080",
  "QBITTORRENT_CATEGORY" => "books",
  "QBITTORRENT_DOWNLOAD_DIR" => "/data/torrents",
  "PROWLARR_TORRENT_ACTION" => "change_category",
  "PROWLARR_TORRENT_POST_IMPORT_CATEGORY" => "imported"
}
expected_env.each do |name, value|
  abort "Shelfmark missing #{name}=#{value}" unless shelfmark_env.dig(name, "value") == value
end
%w[QBITTORRENT_USERNAME QBITTORRENT_PASSWORD].each do |name|
  abort "Shelfmark #{name} must use qbittorrent Secret" unless shelfmark_env.dig(
    name, "valueFrom", "secretKeyRef", "name"
  ) == "qbittorrent"
end
download_mount = shelfmark.fetch("volumeMounts").find { |item| item["mountPath"] == "/data/torrents" }
abort "Shelfmark missing shared downloads mount" unless download_mount&.dig("name") == "qbittorrent-downloads"
download_volume = books_spec.fetch("volumes").find { |item| item["name"] == "qbittorrent-downloads" }
abort "Books missing shared downloads PVC" unless download_volume&.dig(
  "persistentVolumeClaim", "claimName"
) == "qbittorrent-downloads"

infra = render("clusters/homelab/infra")
apps_namespace = resource!(infra, "Namespace", "apps", nil)
%w[enforce audit warn].each do |mode|
  label = "pod-security.kubernetes.io/#{mode}"
  abort "apps namespace missing #{label}=privileged" unless apps_namespace.dig(
    "metadata", "labels", label
  ) == "privileged"
end

images = render("clusters/homelab/image-automation")
resource!(images, "ImageRepository", "qbittorrent", "flux-system")
resource!(images, "ImagePolicy", "qbittorrent", "flux-system")

blueprint = resource!(apps, "ConfigMap", "authentik-blueprint", "apps").dig(
  "data", "homelab.yaml"
)
[
  "qbittorrent-provider",
  "slug: qbittorrent",
  "https://torrent.int.harville.dev"
].each do |entry|
  abort "Authentik blueprint missing #{entry}" unless blueprint.include?(entry)
end
abort "Authentik blueprint missing qBittorrent admin binding" unless blueprint.match?(
  /slug, qbittorrent.*?authentik Admins/m
)
abort "CWA blueprint missing Books Users binding" unless blueprint.match?(
  /slug, calibre-web-automated.*?group: !KeyOf books-users/m
)
abort "Authentik outpost missing qBittorrent provider" unless blueprint.include?(
  "- !KeyOf qbittorrent-provider"
)
group_entries = blueprint.split(/\n      - model: /).select do |entry|
  entry.start_with?("authentik_core.group")
end
abort "unexpected qBittorrent group" if group_entries.any? { |entry| entry.include?("qBittorrent") }

puts "qBittorrent manifest contract passed"
