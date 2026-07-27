"""Tests for the shared bootstrap module."""

import logging

import pytest
from omegaconf import OmegaConf
from unifi_mcp_shared.bootstrap import (
    assert_credentials_configured,
    drop_unexpanded_placeholder_env,
    load_server_config,
    validate_registration_mode,
)


class TestValidateRegistrationMode:
    """Tests for validate_registration_mode."""

    def test_default_is_lazy(self, monkeypatch):
        monkeypatch.delenv("UNIFI_TOOL_REGISTRATION_MODE", raising=False)
        mode = validate_registration_mode(logging.getLogger("test"))
        assert mode == "lazy"

    def test_eager(self, monkeypatch):
        monkeypatch.setenv("UNIFI_TOOL_REGISTRATION_MODE", "eager")
        assert validate_registration_mode(logging.getLogger("test")) == "eager"

    def test_meta_only(self, monkeypatch):
        monkeypatch.setenv("UNIFI_TOOL_REGISTRATION_MODE", "meta_only")
        assert validate_registration_mode(logging.getLogger("test")) == "meta_only"

    def test_invalid_falls_back_to_lazy(self, monkeypatch):
        monkeypatch.setenv("UNIFI_TOOL_REGISTRATION_MODE", "invalid_mode")
        mode = validate_registration_mode(logging.getLogger("test"))
        assert mode == "lazy"

    def test_case_insensitive(self, monkeypatch):
        monkeypatch.setenv("UNIFI_TOOL_REGISTRATION_MODE", "EAGER")
        assert validate_registration_mode(logging.getLogger("test")) == "eager"


class TestAssertCredentialsConfigured:
    """Tests for assert_credentials_configured."""

    def _cfg(self, host: str = ""):
        return OmegaConf.create({"unifi": {"host": host}})

    def test_passes_when_host_set(self):
        assert_credentials_configured(
            self._cfg("10.0.0.1"),
            plugin_name="unifi-network",
            env_prefix="NETWORK",
            logger=logging.getLogger("test"),
        )

    def test_exits_when_host_empty(self, caplog):
        with caplog.at_level(logging.ERROR), pytest.raises(SystemExit) as exc:
            assert_credentials_configured(
                self._cfg(""),
                plugin_name="unifi-network",
                env_prefix="NETWORK",
                logger=logging.getLogger("test"),
            )
        assert exc.value.code == 5
        joined = "\n".join(r.getMessage() for r in caplog.records)
        assert "unifi-network" in joined
        assert "UNIFI_NETWORK_HOST" in joined
        assert "/setup" in joined

    def test_exits_when_host_whitespace(self):
        with pytest.raises(SystemExit):
            assert_credentials_configured(
                self._cfg("   "),
                plugin_name="unifi-protect",
                env_prefix="PROTECT",
                logger=logging.getLogger("test"),
            )

    def test_exits_when_unifi_section_missing(self):
        cfg = OmegaConf.create({})
        with pytest.raises(SystemExit):
            assert_credentials_configured(
                cfg,
                plugin_name="unifi-access",
                env_prefix="ACCESS",
                logger=logging.getLogger("test"),
            )


PLUGIN_PLACEHOLDER_ENV = {
    "UNIFI_HOST": "${UNIFI_NETWORK_HOST:-}",
    "UNIFI_USERNAME": "${UNIFI_NETWORK_USERNAME:-}",
    "UNIFI_PASSWORD": "${UNIFI_NETWORK_PASSWORD:-}",
    "UNIFI_PORT": "${UNIFI_NETWORK_PORT:-443}",
    "UNIFI_SITE": "${UNIFI_NETWORK_SITE:-default}",
    "UNIFI_VERIFY_SSL": "${UNIFI_NETWORK_VERIFY_SSL:-false}",
}

CONFIG_YAML = """
unifi:
  host: ${oc.env:UNIFI_HOST,""}
  username: ${oc.env:UNIFI_USERNAME,""}
  password: ${oc.env:UNIFI_PASSWORD,""}
  port: ${oc.env:UNIFI_PORT,443}
  site: ${oc.env:UNIFI_SITE,default}
  verify_ssl: ${oc.env:UNIFI_VERIFY_SSL,false}
"""


class TestDropUnexpandedPlaceholderEnv:
    """Clients that do not expand ${VAR:-default} must not crash the server."""

    def _apply(self, monkeypatch, env):
        for name, value in env.items():
            monkeypatch.setenv(name, value)

    def test_removes_placeholders_from_os_environ(self, monkeypatch):
        import os

        self._apply(monkeypatch, PLUGIN_PLACEHOLDER_ENV)
        ignored = drop_unexpanded_placeholder_env(logger=logging.getLogger("test"))

        assert ignored == sorted(PLUGIN_PLACEHOLDER_ENV)
        for name in PLUGIN_PLACEHOLDER_ENV:
            assert name not in os.environ

    def test_warns_with_names_but_never_values(self, monkeypatch, caplog):
        self._apply(monkeypatch, {"UNIFI_PASSWORD": "${UNIFI_NETWORK_PASSWORD:-}"})

        with caplog.at_level(logging.WARNING):
            drop_unexpanded_placeholder_env(logger=logging.getLogger("test"))

        joined = "\n".join(r.getMessage() for r in caplog.records)
        assert "UNIFI_PASSWORD" in joined
        assert "${UNIFI_NETWORK_PASSWORD:-}" not in joined
        assert "copilot mcp add" in joined

    def test_preserves_configured_values(self, monkeypatch):
        import os

        self._apply(monkeypatch, {"UNIFI_HOST": "192.168.1.1", "UNIFI_PORT": "${UNIFI_NETWORK_PORT:-443}"})
        ignored = drop_unexpanded_placeholder_env(logger=logging.getLogger("test"))

        assert ignored == ["UNIFI_PORT"]
        assert os.environ["UNIFI_HOST"] == "192.168.1.1"

    def test_silent_when_nothing_to_drop(self, monkeypatch, caplog):
        self._apply(monkeypatch, {"UNIFI_HOST": "192.168.1.1"})

        with caplog.at_level(logging.WARNING):
            assert drop_unexpanded_placeholder_env(logger=logging.getLogger("test")) == []

        assert caplog.records == []


class TestLoadServerConfigWithPlaceholderEnv:
    """Regression guard for the Copilot CLI startup crash.

    Before sanitization, OmegaConf re-interpolated the literal ``${...}`` value
    returned by ``oc.env`` and raised ``UnsupportedInterpolationType`` before the
    server could report actionable setup guidance.
    """

    def _config_file(self, tmp_path):
        path = tmp_path / "config.yaml"
        path.write_text(CONFIG_YAML)
        return path

    def _apply_plugin_env(self, monkeypatch, tmp_path):
        monkeypatch.setenv("CONFIG_PATH", str(self._config_file(tmp_path)))
        for name, value in PLUGIN_PLACEHOLDER_ENV.items():
            monkeypatch.setenv(name, value)

    def test_falls_back_to_yaml_defaults(self, monkeypatch, tmp_path):
        self._apply_plugin_env(monkeypatch, tmp_path)

        cfg = load_server_config(
            package_name="unifi_mcp_shared",
            env_prefix="NETWORK",
            logger=logging.getLogger("test"),
        )

        assert cfg.unifi.host == ""
        assert str(cfg.unifi.port) == "443"
        assert cfg.unifi.site == "default"
        assert str(cfg.unifi.verify_ssl).lower() == "false"

    def test_empty_host_still_reaches_the_setup_guidance(self, monkeypatch, tmp_path):
        self._apply_plugin_env(monkeypatch, tmp_path)

        cfg = load_server_config(
            package_name="unifi_mcp_shared",
            env_prefix="NETWORK",
            logger=logging.getLogger("test"),
        )

        with pytest.raises(SystemExit) as exc:
            assert_credentials_configured(
                cfg,
                plugin_name="unifi-network",
                env_prefix="NETWORK",
                logger=logging.getLogger("test"),
            )
        assert exc.value.code == 5

    def test_unsanitized_placeholders_would_fail_to_resolve(self, tmp_path):
        """Documents the underlying OmegaConf behaviour the sanitizer defends against.

        ``load_server_config`` merges env values into the config tree. A merged
        value that still contains ``${...}`` becomes an interpolation node, and
        resolving it raises before any tool can run.
        """
        from omegaconf import OmegaConf
        from omegaconf.errors import UnsupportedInterpolationType

        cfg = OmegaConf.load(str(self._config_file(tmp_path)))
        cfg.unifi = OmegaConf.merge(cfg.unifi, {"host": "${UNIFI_NETWORK_HOST:-}"})

        with pytest.raises(UnsupportedInterpolationType):
            _ = cfg.unifi.host

    def test_real_values_are_used(self, monkeypatch, tmp_path):
        monkeypatch.setenv("CONFIG_PATH", str(self._config_file(tmp_path)))
        monkeypatch.setenv("UNIFI_HOST", "10.0.0.1")
        monkeypatch.setenv("UNIFI_PORT", "8443")

        cfg = load_server_config(
            package_name="unifi_mcp_shared",
            env_prefix="NETWORK",
            logger=logging.getLogger("test"),
        )

        assert cfg.unifi.host == "10.0.0.1"
        assert str(cfg.unifi.port) == "8443"
