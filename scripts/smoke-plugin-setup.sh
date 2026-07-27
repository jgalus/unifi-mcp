#!/bin/bash
# Smoke test the plugin setup scripts (check-prereqs.sh, set-env.sh) for all
# three UniFi MCP plugin bundles.
#
# Run with the system bash to specifically pin macOS bash 3.2 compatibility:
#   /bin/bash scripts/smoke-plugin-setup.sh
#
# Or with whatever is on PATH (typically Homebrew bash 5+):
#   bash scripts/smoke-plugin-setup.sh
#
# Exits 0 if all assertions pass, non-zero otherwise.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGINS=(unifi-network unifi-protect unifi-access)

passes=0
fails=0
fail_messages=""

assert() {
  local desc="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  [OK]   $desc"
    passes=$((passes + 1))
  else
    echo "  [FAIL] $desc (got '$actual', expected '$expected')"
    fails=$((fails + 1))
    fail_messages="$fail_messages\n  - $desc: got '$actual', expected '$expected'"
  fi
}

assert_file_valid_json() {
  local desc="$1"
  local file="$2"
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$file" 2>/dev/null; then
    echo "  [OK]   $desc"
    passes=$((passes + 1))
  else
    echo "  [FAIL] $desc (file is not valid JSON: $file)"
    fails=$((fails + 1))
    fail_messages="$fail_messages\n  - $desc"
  fi
}

assert_contains() {
  local desc="$1"
  local haystack="$2"
  local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  [OK]   $desc"
    passes=$((passes + 1))
  else
    echo "  [FAIL] $desc (output did not contain '$needle')"
    fails=$((fails + 1))
    fail_messages="$fail_messages\n  - $desc"
  fi
}

assert_not_contains() {
  local desc="$1"
  local haystack="$2"
  local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  [FAIL] $desc (output unexpectedly contained '$needle')"
    fails=$((fails + 1))
    fail_messages="$fail_messages\n  - $desc"
  else
    echo "  [OK]   $desc"
    passes=$((passes + 1))
  fi
}

assert_no_crlf() {
  local desc="$1"
  local file="$2"
  if LC_ALL=C grep -q $'\r' "$file"; then
    echo "  [FAIL] $desc (CRLF byte found in $file)"
    fails=$((fails + 1))
    fail_messages="$fail_messages\n  - $desc"
  else
    echo "  [OK]   $desc"
    passes=$((passes + 1))
  fi
}

# The happy-path assertions below require a real uvx on PATH, since
# check-prereqs.sh probes for it. Fail loudly here instead of leaking a
# confusing "happy path exits 0" assertion failure.
if ! command -v uvx >/dev/null 2>&1; then
  echo "ERROR: uvx not found on PATH — install uv (https://astral.sh/uv) before running this smoke test." >&2
  exit 1
fi

# --- 1. Scripts are byte-identical across all three plugins (drift guard) ---
echo ""
echo "== 1. Cross-plugin script parity =="
for script in check-prereqs.sh set-env.sh check-prereqs.ps1 set-env.ps1; do
  reference="$REPO_ROOT/plugins/${PLUGINS[0]}/scripts/$script"
  for plugin in "${PLUGINS[@]:1}"; do
    other="$REPO_ROOT/plugins/$plugin/scripts/$script"
    if diff -q "$reference" "$other" >/dev/null 2>&1; then
      echo "  [OK]   $script identical between ${PLUGINS[0]} and $plugin"
      passes=$((passes + 1))
    else
      echo "  [FAIL] $script differs between ${PLUGINS[0]} and $plugin"
      fails=$((fails + 1))
      fail_messages="$fail_messages\n  - $script drift: ${PLUGINS[0]} vs $plugin"
    fi
  done
done

echo ""
echo "== 1b. Script line endings =="
for plugin in "${PLUGINS[@]}"; do
  assert_no_crlf "$plugin check-prereqs.sh uses LF" "$REPO_ROOT/plugins/$plugin/scripts/check-prereqs.sh"
  assert_no_crlf "$plugin set-env.sh uses LF" "$REPO_ROOT/plugins/$plugin/scripts/set-env.sh"
done

echo ""
echo "== 1c. Copilot CLI plugin manifests =="
for plugin in "${PLUGINS[@]}"; do
  copilot_manifest="$REPO_ROOT/plugins/$plugin/.github/plugin/plugin.json"
  claude_manifest="$REPO_ROOT/plugins/$plugin/.claude-plugin/plugin.json"
  assert_file_valid_json "$plugin Copilot manifest is valid JSON" "$copilot_manifest"

  got_name=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$copilot_manifest" 2>/dev/null || echo "MISSING")
  assert "$plugin Copilot manifest name matches plugin dir" "$got_name" "$plugin"

  # Copilot CLI does not expand ${VAR:-default}, so the Copilot manifest must
  # not declare an MCP server; setup registers it with `copilot mcp add`.
  has_servers=$(python3 -c "import json,sys; print('yes' if 'mcpServers' in json.load(open(sys.argv[1])) else 'no')" "$copilot_manifest" 2>/dev/null || echo "MISSING")
  assert "$plugin Copilot manifest declares no mcpServers" "$has_servers" "no"

  copilot_version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$copilot_manifest" 2>/dev/null || echo "MISSING")
  claude_version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$claude_manifest" 2>/dev/null || echo "MISSING")
  assert "$plugin Copilot manifest version matches Claude manifest" "$copilot_version" "$claude_version"

  # Copilot CLI auto-loads these paths and any plugin-scoped server it finds
  # shadows the same-named user-scope entry created by `copilot mcp add`, so the
  # Codex server definition must stay inside .codex-plugin/. The files may exist
  # but MUST declare zero servers: .mcp.json is also what stops Copilot falling
  # back to the mcpServers block in .claude-plugin/plugin.json, whose
  # ${VAR:-default} values it does not expand.
  for shadow in .mcp.json .github/mcp.json; do
    shadow_path="$REPO_ROOT/plugins/$plugin/$shadow"
    if [ ! -f "$shadow_path" ]; then
      echo "  [OK]   $plugin has no $shadow"
      passes=$((passes + 1))
      continue
    fi
    shadow_servers=$(python3 -c "import json,sys; print('yes' if json.load(open(sys.argv[1])).get('mcpServers') else 'no')" "$shadow_path" 2>/dev/null || echo "INVALID")
    assert "$plugin $shadow declares no mcpServers" "$shadow_servers" "no"
  done
  assert_file_valid_json "$plugin has .mcp.json blocking the Claude manifest fallback" "$REPO_ROOT/plugins/$plugin/.mcp.json"
  assert_file_valid_json "$plugin Codex MCP definition is valid JSON" "$REPO_ROOT/plugins/$plugin/.codex-plugin/mcp.json"
  codex_pointer=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('mcpServers',''))" "$REPO_ROOT/plugins/$plugin/.codex-plugin/plugin.json" 2>/dev/null || echo "MISSING")
  assert "$plugin Codex manifest points at .codex-plugin/mcp.json" "$codex_pointer" "./.codex-plugin/mcp.json"
done

# --- 2. check-prereqs.sh behavior ---
echo ""
echo "== 2. check-prereqs.sh =="
PREREQS="$REPO_ROOT/plugins/${PLUGINS[0]}/scripts/check-prereqs.sh"

# 2a. Happy path: uvx present, no settings file
work=$(mktemp -d) && trap 'rm -rf "$work"' EXIT
cd "$work"
set +e
out=$(/bin/bash "$PREREQS" "unifi-network" 2>&1)
ec=$?
set -e
assert "happy path exits 0" "$ec" "0"
assert_contains "happy path mentions uvx found" "$out" "uvx found"

# 2b. Failure: uvx missing
rm -rf "$work"/*
set +e
out=$(PATH="/usr/bin:/bin" /bin/bash "$PREREQS" "unifi-network" 2>&1)
ec=$?
set -e
assert "missing uvx exits non-zero" "$ec" "1"
assert_contains "missing uvx surfaces install instructions" "$out" "astral.sh/uv/install.sh"

# 2c. Failure: malformed settings.local.json
mkdir -p "$work/.claude"
echo "{ malformed" > "$work/.claude/settings.local.json"
cd "$work"
set +e
out=$(/bin/bash "$PREREQS" "unifi-network" 2>&1)
ec=$?
set -e
assert "malformed settings exits non-zero" "$ec" "1"
assert_contains "malformed settings names the offending file" "$out" "settings.local.json"

# 2d. Copilot target: missing copilot CLI fails with install guidance
rm -rf "$work"/* 2>/dev/null || true
cd "$work"
set +e
out=$(PATH="$work/empty-bin:/usr/bin:/bin" /bin/bash "$PREREQS" --target copilot "unifi-network" 2>&1)
ec=$?
set -e
assert "copilot target without copilot CLI exits non-zero" "$ec" "1"
assert_contains "copilot target names copilot mcp add" "$out" "copilot mcp add"

# 2e. Unknown target is rejected
set +e
out=$(/bin/bash "$PREREQS" --target bogus "unifi-network" 2>&1)
ec=$?
set -e
assert "unknown target exits non-zero" "$ec" "1"
assert_contains "unknown target lists copilot as valid" "$out" "copilot"

# --- 3. set-env.sh behavior ---
echo ""
echo "== 3. set-env.sh =="
SETENV="$REPO_ROOT/plugins/${PLUGINS[0]}/scripts/set-env.sh"

# 3a. Empty workspace -> creates valid JSON with all keys
rm -rf "$work" && mkdir "$work" && cd "$work"
set +e
out=$(/bin/bash "$SETENV" \
  UNIFI_NETWORK_HOST=10.0.0.1 \
  UNIFI_NETWORK_USERNAME=admin \
  UNIFI_NETWORK_PASSWORD=hunter2secret 2>&1)
ec=$?
set -e
assert "empty-workspace write exits 0" "$ec" "0"
assert_file_valid_json "empty-workspace produces valid JSON" "$work/.claude/settings.local.json"
got_host=$(python3 -c "import json; print(json.load(open('.claude/settings.local.json'))['env']['UNIFI_NETWORK_HOST'])")
assert "host written correctly" "$got_host" "10.0.0.1"
got_pw=$(python3 -c "import json; print(json.load(open('.claude/settings.local.json'))['env']['UNIFI_NETWORK_PASSWORD'])")
assert "password written correctly" "$got_pw" "hunter2secret"

# 3b. Sensitive values masked in stdout
assert_contains "password is masked in output" "$out" "hu***et"
assert_not_contains "raw password not in output" "$out" "hunter2secret"

# 3c. Update existing key + insert new key
set +e
out=$(/bin/bash "$SETENV" \
  UNIFI_NETWORK_HOST=10.0.0.99 \
  UNIFI_POLICY_NETWORK_FIREWALL_POLICIES_CREATE=true 2>&1)
ec=$?
set -e
assert "update+insert exits 0" "$ec" "0"
assert_file_valid_json "update+insert produces valid JSON" "$work/.claude/settings.local.json"
got_host=$(python3 -c "import json; print(json.load(open('.claude/settings.local.json'))['env']['UNIFI_NETWORK_HOST'])")
assert "existing key was updated" "$got_host" "10.0.0.99"
got_perm=$(python3 -c "import json; print(json.load(open('.claude/settings.local.json'))['env']['UNIFI_POLICY_NETWORK_FIREWALL_POLICIES_CREATE'])")
assert "new key was inserted" "$got_perm" "true"
got_pw=$(python3 -c "import json; print(json.load(open('.claude/settings.local.json'))['env']['UNIFI_NETWORK_PASSWORD'])")
assert "untouched key preserved" "$got_pw" "hunter2secret"

# 3d. Refuses to clobber malformed existing JSON
echo "{ broken" > "$work/.claude/settings.local.json"
original=$(cat "$work/.claude/settings.local.json")
set +e
out=$(/bin/bash "$SETENV" UNIFI_NETWORK_HOST=10.0.0.1 2>&1)
ec=$?
set -e
assert "refuses malformed exits non-zero" "$ec" "1"
after=$(cat "$work/.claude/settings.local.json")
assert "malformed file is left untouched" "$after" "$original"

# 3e. Bad input (no =) is rejected
rm -rf "$work" && mkdir "$work" && cd "$work"
set +e
out=$(/bin/bash "$SETENV" notakeyvalue 2>&1)
ec=$?
set -e
assert "bad input exits non-zero" "$ec" "1"
assert_contains "bad input names the offending arg" "$out" "notakeyvalue"

# 3f. OpenClaw dry-run emits the expected registry command without leaking secrets
rm -rf "$work" && mkdir "$work" && cd "$work"
set +e
out=$(/bin/bash "$SETENV" --target openclaw --dry-run \
  UNIFI_NETWORK_HOST=10.0.0.1 \
  UNIFI_NETWORK_USERNAME=admin \
  UNIFI_NETWORK_PASSWORD=hunter2secret 2>&1)
ec=$?
set -e
assert "openclaw dry-run exits 0" "$ec" "0"
assert_contains "openclaw dry-run uses mcp set" "$out" "openclaw mcp set unifi-network"
assert_contains "openclaw dry-run uses uvx command" "$out" '"command":"uvx"'
assert_contains "openclaw dry-run masks password" "$out" "hu***et"
assert_not_contains "openclaw dry-run hides raw password" "$out" "hunter2secret"

# 3g. OpenClaw target writes valid MCP JSON through the CLI
rm -rf "$work" && mkdir -p "$work/bin" && cd "$work"
cat > "$work/bin/uvx" <<'SH'
#!/bin/sh
echo "uvx 0.0.0"
SH
cat > "$work/bin/openclaw" <<'SH'
#!/bin/sh
if [ "$1" = "mcp" ] && [ "$2" = "set" ]; then
  printf '%s\n' "$3" > "$OPENCLAW_CAPTURE_NAME"
  printf '%s\n' "$4" > "$OPENCLAW_CAPTURE_JSON"
  exit 0
fi
echo "openclaw 0.0.0"
SH
chmod +x "$work/bin/uvx" "$work/bin/openclaw"
set +e
out=$(PATH="$work/bin:$PATH" OPENCLAW_CAPTURE_NAME="$work/name.txt" OPENCLAW_CAPTURE_JSON="$work/mcp.json" /bin/bash "$SETENV" --target openclaw \
  UNIFI_NETWORK_HOST=10.0.0.1 \
  UNIFI_NETWORK_USERNAME=admin \
  UNIFI_NETWORK_PASSWORD=hunter2secret 2>&1)
ec=$?
set -e
assert "openclaw write exits 0" "$ec" "0"
got_name=$(cat "$work/name.txt")
assert "openclaw write targets plugin name" "$got_name" "unifi-network"
assert_file_valid_json "openclaw write produces valid MCP JSON" "$work/mcp.json"
got_command=$(python3 -c "import json; print(json.load(open('mcp.json'))['command'])")
assert "openclaw JSON uses uvx command" "$got_command" "uvx"
got_host=$(python3 -c "import json; print(json.load(open('mcp.json'))['env']['UNIFI_NETWORK_HOST'])")
assert "openclaw JSON includes host env" "$got_host" "10.0.0.1"
assert_not_contains "openclaw write stdout hides raw password" "$out" "hunter2secret"

# 3h. Copilot CLI dry-run emits the expected registry command without leaking secrets
rm -rf "$work" && mkdir "$work" && cd "$work"
set +e
out=$(/bin/bash "$SETENV" --target copilot --dry-run \
  UNIFI_NETWORK_HOST=10.0.0.1 \
  UNIFI_NETWORK_USERNAME=admin \
  UNIFI_NETWORK_PASSWORD=hunter2secret 2>&1)
ec=$?
set -e
assert "copilot dry-run exits 0" "$ec" "0"
assert_contains "copilot dry-run uses mcp add" "$out" "copilot mcp add unifi-network"
assert_contains "copilot dry-run pins the uvx command" "$out" "uvx --python-preference system"
assert_contains "copilot dry-run masks password" "$out" "hu***et"
assert_not_contains "copilot dry-run hides raw password" "$out" "hunter2secret"

# 3i. Copilot target registers the server through the CLI
rm -rf "$work" && mkdir -p "$work/bin" && cd "$work"
cat > "$work/bin/uvx" <<'SH'
#!/bin/sh
echo "uvx 0.0.0"
SH
cat > "$work/bin/copilot" <<'SH'
#!/bin/sh
if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
  shift 2
  for arg in "$@"; do
    printf '%s\n' "$arg" >> "$COPILOT_CAPTURE_ARGS"
  done
  exit 0
fi
if [ "$1" = "mcp" ] && [ "$2" = "remove" ]; then
  exit 0
fi
echo "copilot 0.0.0"
SH
chmod +x "$work/bin/uvx" "$work/bin/copilot"
set +e
out=$(PATH="$work/bin:$PATH" COPILOT_CAPTURE_ARGS="$work/args.txt" /bin/bash "$SETENV" --target copilot \
  UNIFI_NETWORK_HOST=10.0.0.1 \
  UNIFI_NETWORK_USERNAME=admin \
  UNIFI_NETWORK_PASSWORD=hunter2secret 2>&1)
ec=$?
set -e
assert "copilot write exits 0" "$ec" "0"
args=$(cat "$work/args.txt" 2>/dev/null || echo "")
assert "copilot write targets plugin name" "$(head -1 "$work/args.txt" 2>/dev/null)" "unifi-network"
assert_contains "copilot write passes host env literally" "$args" "UNIFI_NETWORK_HOST=10.0.0.1"
assert_contains "copilot write passes password env literally" "$args" "UNIFI_NETWORK_PASSWORD=hunter2secret"
assert_contains "copilot write passes the uvx command" "$args" "uvx"
assert_not_contains "copilot write passes no unexpanded placeholders" "$args" '${UNIFI_'
assert_not_contains "copilot write stdout hides raw password" "$out" "hunter2secret"

# --- 4. Bash version this test ran under (informational) ---
echo ""
echo "== 4. Test run info =="
bv=$(/bin/bash -c 'echo $BASH_VERSION')
echo "  /bin/bash version: $bv"

# --- Report ---
echo ""
echo "==============================="
echo "Smoke test: $passes passed, $fails failed"
if [ $fails -gt 0 ]; then
  echo ""
  echo "Failures:"
  printf "$fail_messages\n"
  exit 1
fi
echo "All assertions passed."
