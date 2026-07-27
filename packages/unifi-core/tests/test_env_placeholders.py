"""Tests for unexpanded shell placeholder env sanitization."""

from unifi_core.env_placeholders import (
    escape_interpolation,
    find_placeholder_env,
    is_unexpanded_placeholder,
    sanitize_placeholder_env,
)


class TestIsUnexpandedPlaceholder:
    def test_bare_placeholder(self):
        assert is_unexpanded_placeholder("${UNIFI_NETWORK_HOST}")

    def test_placeholder_with_empty_default(self):
        assert is_unexpanded_placeholder("${UNIFI_NETWORK_HOST:-}")

    def test_placeholder_with_default(self):
        assert is_unexpanded_placeholder("${UNIFI_NETWORK_PORT:-443}")

    def test_surrounding_whitespace_still_matches(self):
        assert is_unexpanded_placeholder("  ${UNIFI_NETWORK_SITE:-default}  ")

    def test_real_value(self):
        assert not is_unexpanded_placeholder("192.168.1.1")

    def test_partial_match_is_not_a_placeholder(self):
        # A password that merely contains the syntax is not dropped; it is made
        # opaque at the merge boundary instead (see escape_interpolation).
        assert not is_unexpanded_placeholder("prefix${VAR}suffix")

    def test_empty_string(self):
        assert not is_unexpanded_placeholder("")

    def test_nested_braces_are_not_treated_as_placeholders(self):
        assert not is_unexpanded_placeholder("${${VAR}}")


class TestSanitizePlaceholderEnv:
    def _plugin_env(self):
        """The env block a non-expanding MCP client passes through literally."""
        return {
            "UNIFI_HOST": "${UNIFI_NETWORK_HOST:-}",
            "UNIFI_USERNAME": "${UNIFI_NETWORK_USERNAME:-}",
            "UNIFI_PASSWORD": "${UNIFI_NETWORK_PASSWORD:-}",
            "UNIFI_PORT": "${UNIFI_NETWORK_PORT:-443}",
            "UNIFI_SITE": "${UNIFI_NETWORK_SITE:-default}",
            "UNIFI_VERIFY_SSL": "${UNIFI_NETWORK_VERIFY_SSL:-false}",
            "UNIFI_TOOL_REGISTRATION_MODE": "${UNIFI_TOOL_REGISTRATION_MODE:-lazy}",
        }

    def test_removes_every_placeholder(self):
        env = self._plugin_env()
        removed = sanitize_placeholder_env(env)
        assert env == {}
        assert removed == sorted(self._plugin_env())

    def test_returns_sorted_names_only(self):
        env = {"UNIFI_PASSWORD": "${UNIFI_NETWORK_PASSWORD:-}", "UNIFI_HOST": "${UNIFI_NETWORK_HOST:-}"}
        assert sanitize_placeholder_env(env) == ["UNIFI_HOST", "UNIFI_PASSWORD"]

    def test_preserves_real_values(self):
        env = {
            "UNIFI_HOST": "192.168.1.1",
            "UNIFI_PASSWORD": "hunter2",
            "UNIFI_PORT": "${UNIFI_NETWORK_PORT:-443}",
        }
        assert sanitize_placeholder_env(env) == ["UNIFI_PORT"]
        assert env == {"UNIFI_HOST": "192.168.1.1", "UNIFI_PASSWORD": "hunter2"}

    def test_ignores_variables_outside_the_prefix(self):
        env = {"PATH": "${PATH}", "HOME": "${HOME}"}
        assert sanitize_placeholder_env(env) == []
        assert env == {"PATH": "${PATH}", "HOME": "${HOME}"}

    def test_custom_prefix(self):
        env = {"OTHER_HOST": "${HOST}", "UNIFI_HOST": "${HOST}"}
        assert sanitize_placeholder_env(env, prefix="OTHER_") == ["OTHER_HOST"]
        assert env == {"UNIFI_HOST": "${HOST}"}

    def test_no_placeholders_is_a_no_op(self):
        env = {"UNIFI_HOST": "192.168.1.1"}
        assert sanitize_placeholder_env(env) == []
        assert env == {"UNIFI_HOST": "192.168.1.1"}

    def test_find_does_not_mutate(self):
        env = self._plugin_env()
        found = find_placeholder_env(env)
        assert found == sorted(self._plugin_env())
        assert env == self._plugin_env()


class TestEscapeInterpolation:
    def test_embedded_placeholder_is_escaped(self):
        assert escape_interpolation("pre${VAR}suf") == "pre\\${VAR}suf"

    def test_plain_value_is_unchanged(self):
        assert escape_interpolation("192.168.1.1") == "192.168.1.1"
