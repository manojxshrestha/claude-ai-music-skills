#!/usr/bin/env bash
#
# setup-opencode.sh — wire the bitwize-music skills, MCP server, and slash
# commands into OpenCode.
#
# Usage:
#   ./scripts/setup-opencode.sh
#   ./scripts/setup-opencode.sh --artist pwn --content-root ~/music-projects
#   ./scripts/setup-opencode.sh --yes --skip-deps
#   ./scripts/setup-opencode.sh --check
#
# Options:
#   --artist <slug>        Artist slug for a new config (default: prompt, then my-artist)
#   --content-root <path>  Library root for a new config (default: prompt, then ~/music-projects)
#   -y, --yes              Never prompt; take the defaults
#   --skip-deps            Reuse the existing venv instead of running pip
#   --python <exe>         Python 3.11+ interpreter used to build the venv
#   --commands "a b c"     Generate only these slash commands (default: every skill)
#   --no-commands          Do not generate slash commands
#   --no-global            Write the project config only; leave ~/.config/opencode alone
#   --force-config         Overwrite an existing ~/.bitwize-music/config.yaml
#   --check                Report status and exit; changes nothing
#   -h, --help             Show this help
#
# Linux, macOS, and WSL are supported. Native Windows (cmd/PowerShell) is not
# covered by this script; the MCP server itself still works there.
#
# Safe to re-run: it merges the OpenCode config instead of replacing it, keeps
# an existing ~/.bitwize-music/config.yaml, and regenerates only the files it
# owns.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_PATH=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PLUGIN_ROOT="$REPO_ROOT"

CONFIG_DIR="$HOME/.bitwize-music"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
VENV_DIR="$CONFIG_DIR/venv"
CACHE_FILE="$CONFIG_DIR/cache/state.json"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) VENV_PY="$VENV_DIR/Scripts/python.exe" ;;
  *)                    VENV_PY="$VENV_DIR/bin/python3" ;;
esac

GLOBAL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
GLOBAL_CONFIG="$GLOBAL_DIR/opencode.json"
GLOBAL_COMMANDS="$GLOBAL_DIR/commands/bitwize-music"

PROJECT_CONFIG="$REPO_ROOT/opencode.json"
PROJECT_COMMANDS="$REPO_ROOT/.opencode/commands/bitwize-music"

SKILLS_DIR="$REPO_ROOT/skills"
AGENTS_FILE="$REPO_ROOT/AGENTS.md"
CLAUDE_FILE="$REPO_ROOT/CLAUDE.md"
SERVER_PY="$REPO_ROOT/servers/bitwize-music-server/server.py"
REQUIREMENTS="$REPO_ROOT/requirements.txt"
INDEXER="$REPO_ROOT/tools/state/indexer.py"

DEFAULT_ARTIST="my-artist"
DEFAULT_ROOT="~/music-projects"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

ARTIST=""
CONTENT_ROOT=""
PYTHON_OVERRIDE=""
COMMAND_LIST=""
ASSUME_YES=false
SKIP_DEPS=false
NO_GLOBAL=false
NO_COMMANDS=false
FORCE_CONFIG=false
CHECK_ONLY=false

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_DIM=""
fi

log()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}  ok${C_RESET}  $*"; }
warn() { printf '%s\n' "${C_YELLOW}  !!${C_RESET}  $*" >&2; }
fail() { printf '%s\n' "${C_RED}  xx${C_RESET}  $*" >&2; }
die()  { fail "$*"; exit 1; }

usage() {
  cat <<'EOF'
Wire the bitwize-music skills, MCP server, and slash commands into OpenCode.

Usage:
  ./scripts/setup-opencode.sh                       # prompts for missing values
  ./scripts/setup-opencode.sh --yes                 # take every default
  ./scripts/setup-opencode.sh --artist pwn --content-root ~/music-projects
  ./scripts/setup-opencode.sh --check               # verify, change nothing

Options:
  --artist <slug>        Artist slug for a new config (default: my-artist)
  --content-root <path>  Library root for a new config (default: ~/music-projects)
  -y, --yes              Never prompt; take the defaults
  --skip-deps            Reuse the existing venv instead of running pip
  --python <exe>         Python 3.11+ interpreter used to build the venv
  --commands "a b c"     Generate only these slash commands (default: every skill)
  --no-commands          Do not generate slash commands
  --no-global            Write the project config only
  --force-config         Overwrite an existing ~/.bitwize-music/config.yaml
  --check                Report status and exit; changes nothing
  -h, --help             Show this help
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --artist)         ARTIST="${2:-}"; shift 2 ;;
    --artist=*)       ARTIST="${1#*=}"; shift ;;
    --content-root)   CONTENT_ROOT="${2:-}"; shift 2 ;;
    --content-root=*) CONTENT_ROOT="${1#*=}"; shift ;;
    --python)         PYTHON_OVERRIDE="${2:-}"; shift 2 ;;
    --python=*)       PYTHON_OVERRIDE="${1#*=}"; shift ;;
    --commands)       COMMAND_LIST="${2:-}"; shift 2 ;;
    --commands=*)     COMMAND_LIST="${1#*=}"; shift ;;
    -y|--yes)         ASSUME_YES=true; shift ;;
    --skip-deps)      SKIP_DEPS=true; shift ;;
    --no-global)      NO_GLOBAL=true; shift ;;
    --no-commands)    NO_COMMANDS=true; shift ;;
    --force-config)   FORCE_CONFIG=true; shift ;;
    --check)          CHECK_ONLY=true; shift ;;
    -h|--help)        usage ;;
    *)                die "Unknown option: $1 (try --help)" ;;
  esac
done

if [ "$NO_COMMANDS" = true ] && [ -n "$COMMAND_LIST" ]; then
  die "--commands and --no-commands contradict each other"
fi

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

expand_home() {
  case "$1" in
    "~")   printf '%s' "$HOME" ;;
    "~/")  printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

tildify() {
  case "$1" in
    "$HOME")   printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *)         printf '%s' "$1" ;;
  esac
}

find_python() {
  local candidate
  for candidate in ${PYTHON_OVERRIDE:+"$PYTHON_OVERRIDE"} python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

sanitize_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[[:space:]]\+/-/g' -e 's/[^a-z0-9-]//g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

# config_value <dotted.key> — reads from CONFIG_FILE through the venv Python so
# quoting, comments, and nesting are handled by a real YAML parser.
config_value() {
  local key="$1"
  [ -f "$CONFIG_FILE" ] || return 0
  [ -x "$VENV_PY" ] || return 0
  "$VENV_PY" - "$CONFIG_FILE" "$key" <<'PY' 2>/dev/null || true
import sys
import yaml

path, key = sys.argv[1], sys.argv[2]
try:
    data = yaml.safe_load(open(path, encoding="utf-8")) or {}
except Exception:
    sys.exit(0)

cur = data
for part in key.split("."):
    if not isinstance(cur, dict):
        sys.exit(0)
    cur = cur.get(part)

if cur is not None:
    print(cur)
PY
}

# ---------------------------------------------------------------------------
# Check mode
# ---------------------------------------------------------------------------

run_checks() {
  local failures=0 skills=0 cmds=0

  log "Checking OpenCode setup"
  printf '    repo: %s\n' "$PLUGIN_ROOT"

  if [ -x "$VENV_PY" ]; then
    ok "venv: $VENV_DIR"
  else
    fail "venv missing: $VENV_DIR — run without --check"; failures=$((failures + 1))
  fi

  if [ -x "$VENV_PY" ] && "$VENV_PY" -c 'import yaml' >/dev/null 2>&1; then
    ok "dependency: pyyaml"
  else
    fail "dependency missing: pyyaml"; failures=$((failures + 1))
  fi

  if [ -x "$VENV_PY" ] && { "$VENV_PY" -c 'import mcp.server.mcpserver' >/dev/null 2>&1 ||
                            "$VENV_PY" -c 'import mcp.server.fastmcp' >/dev/null 2>&1; }; then
    ok "dependency: mcp SDK"
  else
    fail "dependency missing: mcp SDK — run without --check"; failures=$((failures + 1))
  fi

  if [ -x "$VENV_PY" ] && "$VENV_PY" -c 'import scipy' >/dev/null 2>&1; then
    ok "dependency: scipy (needed at server boot)"
  else
    fail "dependency missing: scipy — run without --check"; failures=$((failures + 1))
  fi

  [ -f "$SERVER_PY" ] && ok "MCP server: $SERVER_PY" || { fail "MCP server missing: $SERVER_PY"; failures=$((failures + 1)); }
  [ -f "$AGENTS_FILE" ] && ok "OpenCode adapter: AGENTS.md" || { fail "AGENTS.md missing"; failures=$((failures + 1)); }
  [ -f "$CLAUDE_FILE" ] && ok "workflow rules: CLAUDE.md" || { warn "CLAUDE.md missing (workflow rules absent)"; }

  if [ -f "$CONFIG_FILE" ]; then
    local artist content missing
    artist=$(config_value artist.name)
    content=$(config_value paths.content_root)
    missing=$("$VENV_PY" - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import sys
import yaml

try:
    data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    print("config.yaml is not valid YAML")
    sys.exit(0)

missing = []
for key in ("artist.name", "paths.content_root", "paths.audio_root", "paths.documents_root"):
    cur = data
    for part in key.split("."):
        cur = cur.get(part) if isinstance(cur, dict) else None
    if not cur:
        missing.append(key)
if missing:
    print(", ".join(missing))
PY
)
    if [ -n "$missing" ]; then
      fail "config: $CONFIG_FILE missing $missing"; failures=$((failures + 1))
    else
      ok "config: $CONFIG_FILE (artist: ${artist:-?}, root: ${content:-?})"
    fi
  else
    fail "config missing: $CONFIG_FILE — run without --check"; failures=$((failures + 1))
  fi

  if [ -f "$PROJECT_CONFIG" ] && grep -q 'bitwize-music-mcp' "$PROJECT_CONFIG"; then
    ok "project config: $PROJECT_CONFIG"
  else
    fail "project config missing or lacks the MCP server: $PROJECT_CONFIG"; failures=$((failures + 1))
  fi

  if [ "$NO_GLOBAL" = false ]; then
    if [ -f "$GLOBAL_CONFIG" ] && grep -q 'bitwize-music-mcp' "$GLOBAL_CONFIG"; then
      ok "global config: $GLOBAL_CONFIG"
    else
      fail "global config missing or lacks the MCP server: $GLOBAL_CONFIG"; failures=$((failures + 1))
    fi
  fi

  [ -d "$SKILLS_DIR" ] && skills=$(find "$SKILLS_DIR" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')

  if [ "$NO_COMMANDS" = false ]; then
    local repo_cmds=0 global_cmds=0
    [ -d "$PROJECT_COMMANDS" ] && repo_cmds=$(find "$PROJECT_COMMANDS" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    [ -d "$GLOBAL_COMMANDS" ] && global_cmds=$(find "$GLOBAL_COMMANDS" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    cmds=$repo_cmds
    ok "commands: $repo_cmds repo / $global_cmds global (skills: $skills)"
    if [ -n "$COMMAND_LIST" ]; then
      : # explicit subset requested; count mismatch is expected
    elif [ "$skills" -gt 0 ] && [ "$repo_cmds" -ne "$skills" ]; then
      warn "command count ($repo_cmds) differs from skill count ($skills) — rerun to regenerate"
    fi
    if [ "$NO_GLOBAL" = false ] && [ "$global_cmds" -ne "$repo_cmds" ]; then
      warn "global commands ($global_cmds) differ from repo commands ($repo_cmds)"
    fi
  fi

  if [ -f "$CACHE_FILE" ]; then
    ok "state cache: $CACHE_FILE"
  else
    warn "state cache missing (run without --check to build it)"
  fi

  if command -v opencode >/dev/null 2>&1; then
    if (cd "$REPO_ROOT" && opencode mcp list 2>/dev/null | grep -q 'bitwize-music-mcp.*connected'); then
      ok "opencode: bitwize-music-mcp connected"
    else
      fail "opencode: bitwize-music-mcp not connected"; failures=$((failures + 1))
    fi
  else
    warn "opencode not on PATH — install it before using the skills"
  fi

  if command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1 ||
     command -v wl-copy >/dev/null 2>&1 || command -v pbcopy >/dev/null 2>&1; then
    ok "clipboard utility available"
  else
    warn "no clipboard utility (xclip/wl-copy/pbcopy) — /bitwize-music/clipboard will print instead of copy"
  fi

  if [ "$failures" -eq 0 ]; then
    log "All checks passed"
    return 0
  fi
  log "$failures check(s) failed"
  return 1
}

if [ "$CHECK_ONLY" = true ]; then
  run_checks
  exit $?
fi

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

log "bitwize-music → OpenCode setup"
printf '    repo: %s\n' "$PLUGIN_ROOT"

[ -d "$SKILLS_DIR" ] || die "skills/ not found — run this from a clone of the repository"
[ -f "$SERVER_PY" ] || die "MCP server not found at $SERVER_PY"
[ -f "$REQUIREMENTS" ] || die "requirements.txt not found at $REQUIREMENTS"
[ -f "$AGENTS_FILE" ] || warn "AGENTS.md is missing; skills referencing \${CLAUDE_PLUGIN_ROOT} may misbehave"
[ -f "$CLAUDE_FILE" ] || warn "CLAUDE.md is missing; workflow and status rules will be absent"

command -v opencode >/dev/null 2>&1 || warn "opencode is not on PATH — config will be written, but run OpenCode from a shell that has it"

mkdir -p "$CONFIG_DIR"

# ---------------------------------------------------------------------------
# Python + venv
# ---------------------------------------------------------------------------

if [ "$SKIP_DEPS" = false ]; then
  PYTHON=$(find_python) || die "Python 3.11+ not found (tried python3.13/3.12/3.11/python3; use --python)"
  log "Python: $("$PYTHON" --version 2>&1)"

  if [ -x "$VENV_PY" ]; then
    ok "reusing venv: $VENV_DIR"
  else
    log "Creating venv: $VENV_DIR"
    rm -rf "$VENV_DIR"
    if ! "$PYTHON" -m venv "$VENV_DIR" 2>/dev/null; then
      warn "venv with pip failed (missing ensurepip?) — bootstrapping pip manually"
      "$PYTHON" -m venv --without-pip "$VENV_DIR" ||
        die "Could not create a venv. On Debian/Ubuntu install python3-venv."
    fi
  fi

  if ! "$VENV_PY" -m pip --version >/dev/null 2>&1; then
    GET_PIP=$(mktemp "${TMPDIR:-/tmp}/get-pip.XXXXXX")
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$GET_PIP" ||
      die "Could not download get-pip.py (no network?)"
    "$VENV_PY" "$GET_PIP" -q || die "get-pip.py failed"
    rm -f "$GET_PIP"
  fi

  log "Installing Python dependencies (the MCP server imports scipy at boot)"
  "$VENV_PY" -m pip install -q --upgrade pip
  "$VENV_PY" -m pip install -q -r "$REQUIREMENTS"
  ok "dependencies installed"
else
  [ -x "$VENV_PY" ] || die "--skip-deps was set but no venv exists at $VENV_PY"
  ok "skipping dependency installation"
fi

"$VENV_PY" -c 'import yaml' >/dev/null 2>&1 || die "PyYAML is missing from $VENV_PY (rerun without --skip-deps)"
if ! { "$VENV_PY" -c 'import mcp.server.mcpserver' >/dev/null 2>&1 ||
       "$VENV_PY" -c 'import mcp.server.fastmcp' >/dev/null 2>&1; }; then
  die "MCP SDK is missing from $VENV_PY (rerun without --skip-deps)"
fi
if ! "$VENV_PY" -c 'import scipy' >/dev/null 2>&1; then
  die "scipy is missing from $VENV_PY — the server cannot boot (rerun without --skip-deps)"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

if [ -f "$CONFIG_FILE" ] && [ "$FORCE_CONFIG" = false ]; then
  ok "keeping existing config: $CONFIG_FILE"
  EXISTING_ARTIST=$(config_value artist.name || true)
  EXISTING_ROOT=$(config_value paths.content_root || true)
  [ -n "$EXISTING_ARTIST" ] && printf '    artist: %s\n' "$EXISTING_ARTIST"
  [ -n "$EXISTING_ROOT" ] && printf '    content_root: %s\n' "$EXISTING_ROOT"

  if [ -n "$ARTIST" ] && [ "$ARTIST" != "$EXISTING_ARTIST" ]; then
    warn "--artist '$ARTIST' ignored; config exists (use --force-config to rewrite)"
  fi
  if [ -n "$CONTENT_ROOT" ] && [ "$(expand_home "$CONTENT_ROOT")" != "$(expand_home "$EXISTING_ROOT")" ]; then
    warn "--content-root '$CONTENT_ROOT' ignored; config exists (use --force-config to rewrite)"
  fi
else
  if [ -z "$ARTIST" ]; then
    if [ "$ASSUME_YES" = false ] && [ -t 0 ]; then
      printf 'Artist slug [%s]: ' "$DEFAULT_ARTIST"
      read -r ARTIST || true
    fi
    ARTIST="${ARTIST:-$DEFAULT_ARTIST}"
  fi
  if [ -z "$CONTENT_ROOT" ]; then
    if [ "$ASSUME_YES" = false ] && [ -t 0 ]; then
      printf 'Library root [%s]: ' "$DEFAULT_ROOT"
      read -r CONTENT_ROOT || true
    fi
    CONTENT_ROOT="${CONTENT_ROOT:-$DEFAULT_ROOT}"
  fi

  ARTIST=$(sanitize_slug "$ARTIST")
  [ -n "$ARTIST" ] || die "Artist slug is empty after sanitising; use lowercase letters, digits, hyphens"

  CONTENT_ROOT=$(expand_home "$CONTENT_ROOT")
  case "$CONTENT_ROOT" in
    /*) ;;
    *) die "content_root must be an absolute path or start with ~ (got: $CONTENT_ROOT)" ;;
  esac

  NEW_ROOT_CFG=$(tildify "$CONTENT_ROOT")

  log "Writing config: $CONFIG_FILE"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
# bitwize-music configuration
# Generated by scripts/setup-opencode.sh — re-running keeps this file as-is.
#
# Full reference with every optional key:
#   $PLUGIN_ROOT/config/config.example.yaml

artist:
  name: "$ARTIST"
  # genres: ["electronic"]          # defaults for new albums
  # style: "describe your sound"    # informs lyric + prompt suggestions

paths:
  content_root: "$NEW_ROOT_CFG"
  audio_root: "$NEW_ROOT_CFG/audio"
  documents_root: "$NEW_ROOT_CFG/documents"
  overrides: "$NEW_ROOT_CFG/overrides"
  ideas_file: "$NEW_ROOT_CFG/IDEAS.md"

generation:
  service: suno
  require_suno_link_for_final: true
  max_lyric_words: 800

sheet_music:
  enabled: true
  page_size: "letter"
  section_headers: false

# urls:
#   soundcloud: "https://soundcloud.com/$ARTIST"
#   spotify: "https://open.spotify.com/artist/..."
EOF
  ok "artist: $ARTIST"
  ok "content_root: $CONTENT_ROOT"
fi

ARTIST=$(config_value artist.name || true)
[ -n "$ARTIST" ] || die "artist.name is missing from $CONFIG_FILE"

CONTENT_ROOT=$(expand_home "$(config_value paths.content_root || echo "$HOME/music-projects")")
AUDIO_ROOT=$(expand_home "$(config_value paths.audio_root || echo "$CONTENT_ROOT/audio")")
DOCS_ROOT=$(expand_home "$(config_value paths.documents_root || echo "$CONTENT_ROOT/documents")")
OVERRIDES_ROOT=$(expand_home "$(config_value paths.overrides || echo "$CONTENT_ROOT/overrides")")

mkdir -p "$CONTENT_ROOT/artists" "$AUDIO_ROOT" "$DOCS_ROOT" "$OVERRIDES_ROOT"
ok "library directories: $CONTENT_ROOT"

# ---------------------------------------------------------------------------
# OpenCode configs — merge, never clobber unrelated settings
# ---------------------------------------------------------------------------

log "Updating OpenCode configuration"

"$VENV_PY" - "$REPO_ROOT" "$VENV_PY" "$SERVER_PY" "$AGENTS_FILE" "$CLAUDE_FILE" \
  "$PROJECT_CONFIG" "$GLOBAL_CONFIG" "$NO_GLOBAL" <<'PY'
import json
import sys
import time
from pathlib import Path

(repo, venv_py, server_py, agents_file, claude_file,
 project_config, global_config, no_global) = sys.argv[1:]

repo = Path(repo)
skills_dir = repo / "skills"

server = {
    "type": "local",
    "command": [venv_py, server_py],
    "cwd": str(repo),
    # Long-running audio jobs (mixing, mastering) exceed a default MCP timeout.
    "timeout": {"execution": 14400000},
}

def load(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        backup = path.with_name(path.name + ".bak." + time.strftime("%Y%m%d%H%M%S"))
        path.replace(backup)
        print(f"  !!  {path} was not valid JSON; backed up to {backup.name}")
        return {}
    return data if isinstance(data, dict) else {}

def ensure_list(cfg: dict, key: str, values: list[str]) -> None:
    current = cfg.get(key)
    if not isinstance(current, list):
        current = []
    for value in values:
        if value and value not in current:
            current.append(value)
    cfg[key] = current

def write(path: Path, cfg: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
    print(f"  ok  {path}")

# Project config: skills + MCP. Instructions stay in the global config so they
# also apply when the session starts from an album folder outside this repo.
project = load(Path(project_config))
project.setdefault("$schema", "https://opencode.ai/config.json")
ensure_list(project, "skills", [str(skills_dir)])
project.setdefault("mcp", {}).setdefault("servers", {})["bitwize-music-mcp"] = server
write(Path(project_config), project)

if no_global.lower() != "true":
    global_cfg = load(Path(global_config))
    global_cfg.setdefault("$schema", "https://opencode.ai/config.json")
    ensure_list(global_cfg, "skills", [str(skills_dir)])
    ensure_list(global_cfg, "instructions", [str(agents_file), str(claude_file)])
    global_cfg.setdefault("mcp", {}).setdefault("servers", {})["bitwize-music-mcp"] = server
    write(Path(global_config), global_cfg)
PY

# ---------------------------------------------------------------------------
# Slash commands
# ---------------------------------------------------------------------------

if [ "$NO_COMMANDS" = false ]; then
  log "Generating slash commands"
  mkdir -p "$PROJECT_COMMANDS"
  [ "$NO_GLOBAL" = false ] && mkdir -p "$GLOBAL_COMMANDS"

  "$VENV_PY" - "$REPO_ROOT" "$PROJECT_COMMANDS" "$GLOBAL_COMMANDS" "$NO_GLOBAL" "$COMMAND_LIST" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

import yaml

repo, project_dir, global_dir, no_global, requested = sys.argv[1:]
repo = Path(repo)
project_dir = Path(project_dir)
global_dir = Path(global_dir)
skills_root = repo / "skills"

def discover() -> list[str]:
    names = []
    for skill_file in sorted(skills_root.glob("*/SKILL.md")):
        names.append(skill_file.parent.name)
    return names

if requested.strip():
    names = []
    for raw in re.split(r"[\s,]+", requested.strip()):
        if raw and raw not in names:
            names.append(raw)
else:
    names = discover()

MARKER = "Use the `skill` tool to load the skill with ID"

body_template = """---
description: {description}
---

Use the `skill` tool to load the skill with ID `{name}`, then follow that skill's
instructions exactly. Do not paraphrase it from memory.

- Treat `{repo}` as the plugin root wherever the skill says `${{CLAUDE_PLUGIN_ROOT}}`.
- Read any supporting files the skill points at before acting.
- Use the `bitwize-music-mcp` tools for album, track, gate, and audio state
  instead of reading state files by hand.

Arguments: $ARGUMENTS
"""

written = 0
unknown = []
for name in names:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        unknown.append(f"{name} (invalid name)")
        continue
    skill_file = skills_root / name / "SKILL.md"
    if not skill_file.exists():
        unknown.append(name)
        continue

    text = skill_file.read_text(encoding="utf-8")
    frontmatter = {}
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            try:
                frontmatter = yaml.safe_load(parts[1]) or {}
            except Exception:
                frontmatter = {}
    description = " ".join(str(frontmatter.get("description") or f"Run the {name} skill").split())

    body = body_template.format(
        description=json.dumps(description, ensure_ascii=False),
        name=name,
        repo=repo,
    )
    target = project_dir / f"{name}.md"
    target.write_text(body, encoding="utf-8")
    if no_global.lower() != "true":
        shutil.copy2(target, global_dir / f"{name}.md")
    written += 1

print(f"  ok  {written} commands in {project_dir}")
if no_global.lower() != "true":
    print(f"  ok  {written} commands in {global_dir}")
if unknown:
    print("  !!  skipped unknown skill(s): " + ", ".join(unknown))

# Prune wrappers this script generated earlier but no longer emits. Only files
# carrying the marker are touched, so a hand-written command in the same folder
# survives.
keep = {f"{name}.md" for name in names}
dirs = [project_dir]
if no_global.lower() != "true":
    dirs.append(global_dir)
for directory in dirs:
    removed = 0
    for stale in directory.glob("*.md"):
        if stale.name in keep:
            continue
        try:
            if MARKER not in stale.read_text(encoding="utf-8"):
                continue
        except OSError:
            continue
        stale.unlink()
        removed += 1
    if removed:
        print(f"  ok  removed {removed} stale command(s) from {directory}")
PY
fi

# ---------------------------------------------------------------------------
# State cache
# ---------------------------------------------------------------------------

if [ -f "$INDEXER" ]; then
  log "Rebuilding state cache"
  if "$VENV_PY" "$INDEXER" rebuild >/dev/null; then
    ok "cache: $CACHE_FILE"
  else
    warn "state cache rebuild failed — albums will not appear until it is fixed"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log "Setup complete"
printf '\n'
printf '%sTry it:%s\n' "$C_BOLD" "$C_RESET"
printf '  %s/bitwize-music/resume%s <album-name>\n' "$C_GREEN" "$C_RESET"
printf '  %s/bitwize-music/new-album%s <name> <genre>\n' "$C_GREEN" "$C_RESET"
printf '  %s/bitwize-music/suno-engineer%s <track-path>\n' "$C_GREEN" "$C_RESET"
printf '\n'
printf 'Skills also load from plain English — the agent routes by description.\n\n'
printf '%sConfiguration%s\n' "$C_BOLD" "$C_RESET"
printf '  artist        %s\n' "$ARTIST"
printf '  content root  %s\n' "$CONTENT_ROOT"
printf '  audio root    %s\n' "$AUDIO_ROOT"
printf '  documents     %s\n' "$DOCS_ROOT"
printf '  project cfg   %s\n' "$PROJECT_CONFIG"
[ "$NO_GLOBAL" = false ] && printf '  global cfg    %s\n' "$GLOBAL_CONFIG"
printf '  venv          %s\n' "$VENV_PY"
printf '  config        %s\n' "$CONFIG_FILE"
printf '\n'
printf '%sVerify any time:%s %s --check\n' "$C_DIM" "$C_RESET" "$0"
