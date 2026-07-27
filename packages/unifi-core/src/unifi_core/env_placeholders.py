"""Drop environment variables whose values are unexpanded shell placeholders.

Plugin manifests for Claude Code, Codex, and OpenClaw declare the server's
environment with shell-style interpolation, e.g.::

    "UNIFI_PORT": "${UNIFI_NETWORK_PORT:-443}"

Those clients expand the placeholder before spawning the server. Clients that
do not — GitHub Copilot CLI only expands a fixed placeholder set such as
``${PLUGIN_ROOT}`` — pass the literal string through instead. OmegaConf then
re-interprets the ``${...}`` it finds in the resolved value and the server dies
at startup with ``UnsupportedInterpolationType`` before any of the friendly
"run setup first" guidance can be printed.

Treating such values as unset restores the intended behaviour: the config falls
back to the defaults declared in ``config.yaml``, and the missing-credentials
check reports actionable setup instructions.
"""

from __future__ import annotations

import re
from typing import MutableMapping

# A value is a placeholder only when the interpolation spans the whole string.
# Partial matches (e.g. a password that merely contains "${") are left alone.
_PLACEHOLDER_RE = re.compile(r"^\$\{[^{}]*\}$")

DEFAULT_PREFIX = "UNIFI_"


def is_unexpanded_placeholder(value: str) -> bool:
    """Return True when *value* is an entirely unexpanded shell placeholder."""
    return bool(_PLACEHOLDER_RE.match(value.strip()))


def escape_interpolation(value: str) -> str:
    """Escape ``${`` so OmegaConf stores the literal text instead of an interpolation.

    Values that merely *contain* ``${`` (a legitimate password, say) survive
    sanitization, but merging them raw into the config tree turns the embedded
    ``${...}`` into an interpolation node that raises on first access. Escaping
    at the merge boundary keeps the value opaque; OmegaConf yields the original
    text on read.
    """
    # ponytail: a literal backslash before "${" would double-escape. Not worth
    # a parser until an env value actually needs it.
    return value.replace("${", "\\${")


def find_placeholder_env(
    environ: MutableMapping[str, str],
    *,
    prefix: str = DEFAULT_PREFIX,
) -> list[str]:
    """Return the sorted names of *prefix* variables holding placeholder values."""
    return sorted(
        name
        for name, value in environ.items()
        if name.startswith(prefix) and isinstance(value, str) and is_unexpanded_placeholder(value)
    )


def sanitize_placeholder_env(
    environ: MutableMapping[str, str],
    *,
    prefix: str = DEFAULT_PREFIX,
) -> list[str]:
    """Remove *prefix* variables whose values are unexpanded placeholders.

    Args:
        environ: Mutable environment mapping (normally ``os.environ``).
        prefix: Only variables starting with this prefix are considered, so a
            malformed value elsewhere in the environment is never touched.

    Returns:
        The sorted names of the removed variables. Names only — values may be
        placeholders for secrets and are never returned or logged.
    """
    removed = find_placeholder_env(environ, prefix=prefix)
    for name in removed:
        del environ[name]
    return removed
