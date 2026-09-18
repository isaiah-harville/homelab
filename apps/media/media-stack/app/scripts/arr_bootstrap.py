#!/usr/bin/env python3
import os
from pathlib import Path
import tempfile
import xml.etree.ElementTree as ET


def set_value(root, name, value):
    element = root.find(name)
    if element is None:
        element = ET.SubElement(root, name)
    element.text = str(value)


def main():
    config_dir = Path(os.environ.get("ARR_CONFIG_DIR", "/config"))
    config_path = config_dir / "config.xml"
    config_dir.mkdir(parents=True, exist_ok=True, mode=0o750)

    if config_path.exists():
        root = ET.parse(config_path).getroot()
    else:
        root = ET.Element("Config")

    values = {
        "BindAddress": "*",
        "Port": os.environ["ARR_PORT"],
        "EnableSsl": "False",
        "LaunchBrowser": "False",
        "ApiKey": os.environ["ARR_API_KEY"],
        "AuthenticationMethod": "External",
        "AuthenticationRequired": "DisabledForLocalAddresses",
        "Branch": "master",
        "LogLevel": "info",
        "UrlBase": "",
        "InstanceName": os.environ["ARR_NAME"],
    }
    for name, value in values.items():
        set_value(root, name, value)

    ET.indent(root, space="  ")
    with tempfile.NamedTemporaryFile(
        mode="wb", dir=config_dir, prefix="config.xml.", delete=False
    ) as temporary:
        ET.ElementTree(root).write(temporary, encoding="utf-8", xml_declaration=True)
        temporary_path = Path(temporary.name)
    temporary_path.chmod(0o600)
    os.replace(temporary_path, config_path)


if __name__ == "__main__":
    main()
