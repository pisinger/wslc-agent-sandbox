#!/bin/sh
# Agent entrypoint for opencode or GitHub Copilot CLI (selected by AGENT, baked into the image).
#
#   Root phase:  session packages, egress self-test, privilege drop.
#   Agent phase: agent-specific config from env, then exec the CLI.
#
# Env contract:
#   AGENT                 opencode | copilot (set by the image build)
#   OLLAMA_API_KEY        required. With API key injection this is a placeholder; the real key
#                         lives only in the API proxy container.
#   OLLAMA_MODELS         comma list, e.g. "deepseek-v4.1-flash,qwen3-coder:480b"
#   OLLAMA_DEFAULT_MODEL  optional, defaults to first entry of OLLAMA_MODELS
#   OLLAMA_BASE_URL       optional, defaults to https://ollama.com/v1 (API proxy URL with injection)
#   EXTRA_APK_PACKAGES    optional, space list installed as root before the self-test + privilege drop
#   AGENT_RUN_AS_ROOT     1 = run the agent CLI as root (e.g. to install tools with apk). Still no
#                         NET_RAW/SETUID/... and no_new_privs; only file-ownership capabilities are kept.
#   EGRESS_MODE           "proxy" (default): verify sidecar isolation, fail closed.
#                         "none": skip the check (explicit opt-out, e.g. debugging without isolation)
#   OPENCODE_AUTO         1 (default) = auto mode (opencode --auto / copilot --allow-all), 0 = approvals
#   COPILOT_AUTH          copilot only: "byok" (default, Ollama via BYOK, offline from GitHub) or
#                         "github" (GitHub Copilot models; token via COPILOT_GITHUB_TOKEN or /login)
#   COPILOT_MODEL         copilot github mode only: optional model override (e.g. claude-sonnet-4.6)
#   COPILOT_WIRE_API      copilot byok only: "responses" (default) or "completions"
#   COPILOT_NODE_OPTIONS  copilot only: Node runtime flags (default: larger heap + young generation)
#   COPILOT_UV_THREADPOOL copilot only: libuv thread pool size (default 16)
set -eu

# ---- Root phase ------------------------------------------------------------------------
# Verifies egress isolation, then drops ALL capabilities and re-execs this script as "agent"
# (or as root with a minimal capability set when AGENT_RUN_AS_ROOT=1).
# ENTRYPOINT_AGENT_PHASE marks the re-exec, so a root agent doesn't run this phase twice.
if [ "$(id -u)" = "0" ] && [ -z "${ENTRYPOINT_AGENT_PHASE:-}" ]; then
  # Session packages: installed as root before the privilege drop, so the agent never gets apk rights.
  if [ -n "${EXTRA_APK_PACKAGES:-}" ]; then
    for pkg in $EXTRA_APK_PACKAGES; do
      echo "$pkg" | grep -Eq '^[a-z0-9][a-z0-9._+-]*$' \
        || { echo "apk: rejected package name '$pkg'" >&2; exit 1; }
    done
    # shellcheck disable=SC2086
    apk add --no-cache $EXTRA_APK_PACKAGES
  fi
  # Agent CLIs need a real bash for their shell tools; fail loudly instead of a broken session.
  [ -x /bin/bash ] || { echo "entrypoint: /bin/bash missing; rebuild the image from agent/Dockerfile" >&2; exit 1; }

  case "${EGRESS_MODE:-proxy}" in
    proxy) /usr/local/bin/check-proxy-egress.sh ;;
    none)  echo "WARNING: EGRESS_MODE=none, egress isolation NOT verified" >&2 ;;
    *)     echo "entrypoint: unknown EGRESS_MODE '${EGRESS_MODE}'" >&2; exit 1 ;;
  esac
  export ENTRYPOINT_AGENT_PHASE=1

  if [ "${AGENT_RUN_AS_ROOT:-0}" = "1" ]; then
    # Root agent: can run apk and write anywhere in the container. Kept: only the capabilities apk
    # needs for package files (chown, override file permissions, set file modes). Dropped: NET_RAW,
    # NET_BIND_SERVICE, SETUID/SETGID, KILL, MKNOD, SYS_CHROOT, ... ; no_new_privs stays on.
    echo "WARNING: AGENT_RUN_AS_ROOT=1, the agent runs as root (apk available)" >&2
    exec setpriv --inh-caps=-all \
         --bounding-set=-all,+chown,+dac_override,+fowner,+fsetid --no-new-privs \
         /usr/local/bin/entrypoint.sh "$@"
  fi

  chown agent:agent /home/agent/.cache/opencode /home/agent/.copilot 2>/dev/null || true
  # Existing folders or volumes may be read-only or owned by another UID. Warn, never chown user data.
  if ! setpriv --reuid=agent --regid=agent --init-groups test -w /workspace 2>/dev/null; then
    echo "WARNING: /workspace is not writable for the agent (read-only mount, or owned by another UID)." >&2
  fi
  exec setpriv --reuid=agent --regid=agent --init-groups \
       --inh-caps=-all --bounding-set=-all --no-new-privs \
       /usr/local/bin/entrypoint.sh "$@"
fi

# ---- Agent phase -----------------------------------------------------------------------
: "${OLLAMA_MODELS:=deepseek-v4.1-flash}"
: "${OLLAMA_BASE_URL:=https://ollama.com/v1}"
DEFAULT_MODEL="${OLLAMA_DEFAULT_MODEL:-$(printf '%s' "$OLLAMA_MODELS" | cut -d, -f1 | tr -d ' ')}"
AUTO="${OPENCODE_AUTO:-1}"

case "${AGENT:-opencode}" in
  copilot)
    case "${COPILOT_AUTH:-byok}" in
      byok)
        # BYOK against an OpenAI-compatible endpoint, fully offline from GitHub.
        : "${OLLAMA_API_KEY:?OLLAMA_API_KEY not set}"
        export COPILOT_OFFLINE=true
        export COPILOT_PROVIDER_TYPE=openai
        export COPILOT_PROVIDER_BASE_URL="$OLLAMA_BASE_URL"
        export COPILOT_PROVIDER_API_KEY="$OLLAMA_API_KEY"
        export COPILOT_PROVIDER_WIRE_API="${COPILOT_WIRE_API:-responses}"
        export COPILOT_MODEL="$DEFAULT_MODEL"
        # No GitHub identity in this container in BYOK mode.
        unset OLLAMA_API_KEY GH_TOKEN GITHUB_TOKEN COPILOT_GITHUB_TOKEN
        ;;
      github)
        # GitHub Copilot models via the user's subscription. No BYOK, no offline mode.
        unset OLLAMA_API_KEY OLLAMA_BASE_URL COPILOT_OFFLINE COPILOT_PROVIDER_TYPE \
              COPILOT_PROVIDER_BASE_URL COPILOT_PROVIDER_API_KEY COPILOT_PROVIDER_WIRE_API \
              COPILOT_PROVIDER_MODEL_ID
        [ -n "${COPILOT_MODEL:-}" ] || unset COPILOT_MODEL
        # One token variable only, to avoid ambiguity in the CLI's precedence order.
        if [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then
          unset GH_TOKEN GITHUB_TOKEN
          echo "copilot: GitHub auth via COPILOT_GITHUB_TOKEN"
        elif [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
          echo "copilot: GitHub auth via GH_TOKEN/GITHUB_TOKEN"
        else
          echo "copilot: no GitHub token provided; run /login in the CLI (device flow: open the shown URL on your host)."
          [ -w "$HOME/.copilot" ] || echo "copilot: WARNING, $HOME/.copilot not writable; login cannot be stored" >&2
        fi
        ;;
      *)
        echo "entrypoint: unknown COPILOT_AUTH '${COPILOT_AUTH}' (byok|github)" >&2; exit 1 ;;
    esac
    # Node runtime tuning: trade memory for fewer GC pauses and more parallel file/DNS work.
    # An explicit NODE_OPTIONS from the environment wins.
    export NODE_OPTIONS="${NODE_OPTIONS:-${COPILOT_NODE_OPTIONS:---max-old-space-size=3072 --max-semi-space-size=64}}"
    export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-${COPILOT_UV_THREADPOOL:-16}}"
    echo "copilot: NODE_OPTIONS=$NODE_OPTIONS UV_THREADPOOL_SIZE=$UV_THREADPOOL_SIZE"
    [ "$AUTO" = "1" ] && set -- --allow-all "$@"
    exec copilot "$@"
    ;;
  opencode)
    : "${OLLAMA_API_KEY:?OLLAMA_API_KEY not set}"
    CFG_DIR="$HOME/.config/opencode"
    mkdir -p "$CFG_DIR"
    MODELS_JSON=$(printf '%s' "$OLLAMA_MODELS" | jq -R '
      split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))
      | map({(.): {name: .}}) | add')
    # The key is NOT written to disk: config keeps the literal {env:OLLAMA_API_KEY} placeholder.
    jq -n \
      --arg url "$OLLAMA_BASE_URL" \
      --arg def "ollama-cloud/$DEFAULT_MODEL" \
      --argjson models "$MODELS_JSON" '{
        "$schema": "https://opencode.ai/config.json",
        model: $def,
        autoupdate: false,
        share: "disabled",
        permission: {
          "*": "allow",
          read: { "*": "allow", "*.env": "deny", "*.env.*": "deny", "*.env.example": "allow" },
          bash: { "*": "allow", "env": "deny", "env *": "deny", "printenv*": "deny", "cat /proc/*": "deny" }
        },
        provider: {
          "ollama-cloud": {
            npm: "@ai-sdk/openai-compatible",
            name: "Ollama Cloud",
            options: { baseURL: $url, apiKey: "{env:OLLAMA_API_KEY}", includeUsage: true },
            models: $models
          }
        }
      }' > "$CFG_DIR/opencode.json"
    [ "$AUTO" = "1" ] && set -- --auto "$@"
    exec opencode "$@"
    ;;
  *)
    echo "entrypoint: unknown AGENT '${AGENT:-}'" >&2
    exit 1
    ;;
esac
