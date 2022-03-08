"""
Retrieves external configuration files for opmon projects.

Opmon configuration files are stored in https://github.com/mozilla/opmon-config/
"""

from pathlib import Path
from typing import Dict, List, Optional

import attr
import toml
from git import Repo

from opmon import experimenter
from opmon.config import MonitoringSpec
from opmon.monitoring import Monitoring
from opmon.utils import TemporaryDirectory

DEFINITIONS_DIR = "definitions"


@attr.s(auto_attribs=True)
class ExternalConfig:
    """Represent an external config file."""

    slug: str
    spec: MonitoringSpec

    def validate(self, experiment: Optional[experimenter.Experiment] = None) -> None:
        conf = self.spec.resolve(experiment)
        Monitoring("no project", "no dataset", conf).validate()


def entity_from_path(path: Path) -> ExternalConfig:
    slug = path.stem
    config_dict = toml.loads(path.read_text())
    return ExternalConfig(
        slug=slug,
        spec=MonitoringSpec.from_dict(config_dict),
    )


@attr.s(auto_attribs=True)
class ExternalConfigCollection:
    """
    Collection of experiment-specific configurations pulled in
    from an external GitHub repository.
    """

    configs: List[ExternalConfig] = attr.Factory(list)
    definitions: Dict[str, ExternalConfig] = attr.Factory(dict)

    CONFIG_URL = "https://github.com/mozilla/opmon-config"

    @classmethod
    def from_github_repo(cls) -> "ExternalConfigCollection":
        """Pull in external config files."""
        # download files to tmp directory
        with TemporaryDirectory() as tmp_dir:
            Repo.clone_from(cls.CONFIG_URL, tmp_dir)

            external_configs = []

            for config_file in tmp_dir.glob("*.toml"):
                external_configs.append(
                    ExternalConfig(
                        config_file.stem,
                        MonitoringSpec.from_dict(toml.load(config_file)),
                    )
                )

            definitions = []

            for definition_file in tmp_dir.glob(f"**/{DEFINITIONS_DIR}/*.toml"):
                definitions[definition_file.stem] = ExternalConfig(
                    slug=definition_file.stem,
                    spec=MonitoringSpec.from_dict(toml.load(definition_file)),
                )

        return cls(external_configs, definitions)

    def spec_for_experiment(self, slug: str) -> Optional[MonitoringSpec]:
        """Return the spec for a specific experiment."""
        for config in self.configs:
            if config.slug == slug:
                return config.spec

        return None
