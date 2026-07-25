from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
from typing import Any

import mkdocs_gen_files
import yaml

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_ROOTS = ("apps", "clusters", "infrastructure")
SOURCE_URL = "https://github.com/isaiah-harville/homelab/blob/main"


def manifests() -> Iterator[tuple[Path, dict[str, Any]]]:
    for root_name in MANIFEST_ROOTS:
        for path in sorted((ROOT / root_name).rglob("*.yaml")):
            relative = path.relative_to(ROOT)
            if "secrets" in relative.parts or path.name == "gotk-components.yaml":
                continue

            try:
                documents = yaml.safe_load_all(path.read_text())
                for document in documents:
                    if isinstance(document, dict):
                        yield relative, document
            except yaml.YAMLError as error:
                raise RuntimeError(f"Unable to parse {relative}") from error


def value(document: dict[str, Any], *keys: str, default: Any = "—") -> Any:
    current: Any = document
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current if current not in (None, "") else default


def cell(item: Any) -> str:
    if isinstance(item, list):
        item = ", ".join(str(part) for part in item)
    return str(item).replace("|", r"\|").replace("\n", "<br>")


def source_link(path: Path) -> str:
    return f"[`{path}`]({SOURCE_URL}/{path.as_posix()})"


documents = list(manifests())

helm_releases: list[list[Any]] = []
sources: list[list[Any]] = []
flux_kustomizations: list[list[Any]] = []

for path, document in documents:
    kind = value(document, "kind")
    api_version = value(document, "apiVersion")

    if kind == "HelmRelease":
        helm_releases.append(
            [
                value(document, "metadata", "name"),
                value(document, "metadata", "namespace"),
                value(document, "spec", "chart", "spec", "chart"),
                value(document, "spec", "chart", "spec", "version"),
                value(document, "spec", "chart", "spec", "sourceRef", "name"),
                source_link(path),
            ]
        )

    if kind in {"GitRepository", "HelmRepository", "OCIRepository"}:
        sources.append(
            [
                kind,
                value(document, "metadata", "name"),
                value(document, "metadata", "namespace"),
                value(document, "spec", "interval"),
                source_link(path),
            ]
        )

    if kind == "Kustomization" and str(api_version).startswith(
        "kustomize.toolkit.fluxcd.io/"
    ):
        dependencies = [
            dependency.get("name", "—")
            for dependency in value(document, "spec", "dependsOn", default=[])
            if isinstance(dependency, dict)
        ]
        flux_kustomizations.append(
            [
                value(document, "metadata", "name"),
                value(document, "metadata", "namespace"),
                value(document, "spec", "path"),
                dependencies,
                source_link(path),
            ]
        )


def write_table(
    output: str,
    title: str,
    introduction: str,
    headers: list[str],
    rows: list[list[Any]],
) -> None:
    with mkdocs_gen_files.open(output, "w") as page:
        print(f"# {title}\n", file=page)
        print(f"{introduction}\n", file=page)
        print(
            "_Generated from repository manifests during the documentation build._\n",
            file=page,
        )
        print("| " + " | ".join(headers) + " |", file=page)
        print("| " + " | ".join("---" for _ in headers) + " |", file=page)
        for row in sorted(rows, key=lambda item: tuple(str(part) for part in item[:2])):
            print("| " + " | ".join(cell(item) for item in row) + " |", file=page)

    mkdocs_gen_files.set_edit_path(output, "scripts/generate_reference.py")


write_table(
    "reference/helm-releases.md",
    "Helm releases",
    "Charts reconciled by Flux `HelmRelease` resources.",
    ["Release", "Namespace", "Chart", "Version", "Source", "Manifest"],
    helm_releases,
)

write_table(
    "reference/sources.md",
    "Flux sources",
    "Artifact sources consumed by Flux.",
    ["Kind", "Name", "Namespace", "Interval", "Manifest"],
    sources,
)

write_table(
    "reference/flux-kustomizations.md",
    "Flux reconciliation",
    "Flux `Kustomization` entrypoints and their declared dependencies.",
    ["Name", "Namespace", "Path", "Depends on", "Manifest"],
    flux_kustomizations,
)
