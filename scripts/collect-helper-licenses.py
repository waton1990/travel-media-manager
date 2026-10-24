"""Keep dependency versions and upstream license notices beside the helper."""
import importlib.metadata
import json
import pathlib
import shutil
import sys

destination = pathlib.Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
packages = []
for dist in sorted(importlib.metadata.distributions(), key=lambda x: x.metadata['Name'].lower()):
    name = dist.metadata['Name']
    packages.append({'name': name, 'version': dist.version,
                     'homepage': dist.metadata.get('Home-page', ''),
                     'project_urls': dist.metadata.get_all('Project-URL') or [],
                     'license': dist.metadata.get('License-Expression') or dist.metadata.get('License', '')})
    for file in dist.files or []:
        if any(word in file.name.lower() for word in ('license', 'copying', 'notice')) and '.dist-info' in str(file):
            source = pathlib.Path(dist.locate_file(file))
            if source.is_file():
                target = destination / name / file.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
(destination / 'dependencies.json').write_text(json.dumps(packages, indent=2, ensure_ascii=False), encoding='utf-8')
