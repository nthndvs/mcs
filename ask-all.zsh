#!/bin/zsh
# Send one read-only prompt to the official, logged-in model CLIs in parallel.
# Results are written to a timestamped directory under ./results.

emulate -LR zsh
setopt err_return no_unset pipe_fail

usage() {
  cat <<'EOF'
Usage: ./ask-all.zsh [--allow-tools] [--no-web-search] [--context-file path] [--attachment path] [--provider name] [--summary-model none|codex|claude|grok|glm|kimi|qwen|google|meta|deepseek] "your prompt"

Provider options: --codex-model/--codex-effort, --claude-model/--claude-effort,
--grok-model/--grok-effort, --glm-model/--glm-effort, --kimi-model,
--qwen-model, --google-model/--google-effort, --meta-model/--meta-effort, and
--deepseek-model/--deepseek-effort. Qwen Code's current reasoning effort is configured in its own
persisted CLI settings rather than by a per-request command-line option.
Summary options: --summary-model-id and --summary-effort.

Runs each installed and authenticated CLI in parallel:
  Codex, Claude Code, Grok Build, optionally GLM via Claude Code, Kimi Code,
  Qwen Code, Google Antigravity CLI, Meta Model API, and DeepSeek API.

Meta and DeepSeek are direct, pay-as-you-go API providers rather than CLIs.
Set META_API_KEY and/or DEEPSEEK_API_KEY before invoking the script. The
desktop app stores those keys in macOS Keychain and supplies them only to a run.

Google AI Pro/Ultra subscriptions are served through Antigravity CLI (`agy`).
Antigravity supports the documented `--print`/`-p` one-prompt mode used here;
the older Gemini CLI does not serve consumer subscriptions.

Online research is enabled by default for every supported provider. Use
--no-web-search to disable it. A read-only restriction is also enabled by
default to protect the current project; use --allow-tools only when you
intentionally want coding agents to change files or run commands.

Kimi Code's non-interactive mode auto-approves regular tools, so it is launched
only with --allow-tools. This prevents a "safe" comparison from granting it
filesystem or terminal access implicitly.

To include GLM, export ZAI_API_KEY for this session. The request is then made
through Claude Code, an officially supported GLM Coding Plan tool.

Repeat --attachment to add files. Text and common office documents are safely
embedded in the request (up to 750 KB total). Image files are sent natively to
Codex; Kimi can inspect selected images when --allow-tools is enabled.

Repeat --provider (codex, claude, grok, glm, kimi, qwen, google, meta, or deepseek) to run only a selected
subset. With no --provider flags, the launcher preserves the default of trying
every available provider.
EOF
}

allow_tools=false
web_search=true
context_file=""
summary_model=none
summary_model_id=default
summary_effort=default
codex_model=default
codex_effort=default
claude_model=default
claude_effort=default
grok_model=default
grok_effort=default
glm_model=default
glm_effort=default
kimi_model=default
qwen_model=default
google_model=default
google_effort=default
meta_model=default
meta_effort=default
deepseek_model=default
deepseek_effort=default
tavily_key=${TAVILY_API_KEY:-}
typeset -a attachments
typeset -a included_providers
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --allow-tools)
      allow_tools=true
      shift
      ;;
    --no-web-search)
      web_search=false
      shift
      ;;
    --web-search)
      web_search=true
      shift
      ;;
    --context-file)
      if (( $# < 2 )); then
        usage >&2
        exit 64
      fi
      context_file=$2
      shift 2
      ;;
    --attachment)
      if (( $# < 2 )); then
        usage >&2
        exit 64
      fi
      attachments+=("$2")
      shift 2
      ;;
    --provider)
      if (( $# < 2 )); then
        usage >&2
        exit 64
      fi
      case "${2:l}" in
        codex|claude|grok|glm|kimi|qwen|google|meta|deepseek) included_providers+=("${2:l}") ;;
        *)
          print -r -- "Unknown provider: $2" >&2
          usage >&2
          exit 64
          ;;
      esac
      shift 2
      ;;
    --summary-model)
      if (( $# < 2 )); then
        usage >&2
        exit 64
      fi
      summary_model=${2:l}
      shift 2
      ;;
    --summary-model-id) summary_model_id=${2:l}; shift 2 ;;
    --summary-effort) summary_effort=${2:l}; shift 2 ;;
    --codex-model) codex_model=${2:l}; shift 2 ;;
    --codex-effort) codex_effort=${2:l}; shift 2 ;;
    --claude-model) claude_model=${2:l}; shift 2 ;;
    --claude-effort) claude_effort=${2:l}; shift 2 ;;
    --grok-model) grok_model=${2:l}; shift 2 ;;
    --grok-effort) grok_effort=${2:l}; shift 2 ;;
    --glm-model) glm_model=${2:l}; shift 2 ;;
    --glm-effort) glm_effort=${2:l}; shift 2 ;;
    --kimi-model) kimi_model=${2:l}; shift 2 ;;
    --qwen-model) qwen_model=${2:l}; shift 2 ;;
    --google-model) google_model=${2:l}; shift 2 ;;
    --google-effort) google_effort=${2:l}; shift 2 ;;
    --meta-model) meta_model=${2:l}; shift 2 ;;
    --meta-effort) meta_effort=${2:l}; shift 2 ;;
    --deepseek-model) deepseek_model=${2:l}; shift 2 ;;
    --deepseek-effort) deepseek_effort=${2:l}; shift 2 ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if (( $# != 1 )); then
  usage >&2
  exit 64
fi

request=$1
conversation_context=""
if [[ -n $context_file ]]; then
  if [[ -f $context_file ]]; then
    conversation_context=$(<"$context_file")
  else
    print -r -- "WARNING: Conversation context file was not found: $context_file" >&2
  fi
fi

# Files chosen in the desktop app are explicit, per-request context. Plain
# text is available to every provider without granting local filesystem tools.
# Common document formats are converted with macOS' built-in text utility.
# Images are passed to Codex with its documented native image option; Kimi can
# read their paths with ReadMediaFile only when the user explicitly enables
# --allow-tools.
is_image_attachment() {
  local extension=${1:e:l}
  case "$extension" in
    png|jpg|jpeg|gif|webp|heic|heif|avif|tif|tiff|bmp) return 0 ;;
    *) return 1 ;;
  esac
}

is_plain_text_attachment() {
  local filename=${1:t:l}
  local extension=${1:e:l}
  case "$filename" in
    .env|.gitignore|.dockerignore|makefile|dockerfile|gemfile|rakefile) return 0 ;;
  esac
  case "$extension" in
    txt|md|markdown|rst|csv|tsv|json|yaml|yml|xml|html|htm|css|js|jsx|ts|tsx|py|rb|go|rs|swift|java|c|h|cc|cpp|cxx|hpp|sh|zsh|bash|fish|sql|toml|ini|cfg|conf|log|tex|r|m|scala|php|vue|svelte|graphql|gql|lock) return 0 ;;
    *) return 1 ;;
  esac
}

is_convertible_document() {
  local extension=${1:e:l}
  case "$extension" in
    rtf|rtfd|doc|docx|odt|pages|pdf) return 0 ;;
    *) return 1 ;;
  esac
}

typeset -a image_attachments
attachment_context=""
kimi_attachment_context=""
attachment_notes=""
integer attachment_count=0
integer included_text_bytes=0
integer max_attachment_count=12
integer max_file_text_bytes=262144
integer max_total_text_bytes=786432

for attachment in "${attachments[@]}"; do
  (( attachment_count += 1 ))
  attachment_name=${attachment:t}
  if (( attachment_count > max_attachment_count )); then
    attachment_notes+="\n- ${attachment_name}: not included (limit is ${max_attachment_count} attachments per request)."
    continue
  fi
  if [[ ! -f $attachment || ! -r $attachment ]]; then
    attachment_notes+="\n- ${attachment_name}: could not be read."
    continue
  fi
  if is_image_attachment "$attachment"; then
    image_attachments+=("$attachment")
    attachment_notes+="\n- Image: ${attachment_name} (provided natively to compatible vision models)."
    kimi_attachment_context+="\n- ${attachment}"
    continue
  fi

  attachment_text=""
  if is_plain_text_attachment "$attachment"; then
    attachment_size=$(wc -c <"$attachment" 2>/dev/null | tr -d '[:space:]')
    if [[ -z $attachment_size || $attachment_size != <-> ]]; then
      attachment_notes+="\n- ${attachment_name}: its size could not be determined."
      continue
    fi
    if (( attachment_size > max_file_text_bytes )); then
      attachment_text=$(<"$attachment")
      attachment_text=${attachment_text[1,max_file_text_bytes]}
      attachment_text+="\n\n[Attachment truncated at 256 KB.]"
    else
      attachment_text=$(<"$attachment")
    fi
  elif is_convertible_document "$attachment"; then
    if [[ ${attachment:e:l} == pdf ]]; then
      attachment_text=$(/usr/bin/mdls -raw -name kMDItemTextContent "$attachment" 2>/dev/null)
      [[ $attachment_text == "(null)" ]] && attachment_text=""
    else
      attachment_text=$(/usr/bin/textutil -convert txt -stdout "$attachment" 2>/dev/null)
    fi
    if [[ -n $attachment_text && ${#attachment_text} -gt max_file_text_bytes ]]; then
      attachment_text=${attachment_text[1,max_file_text_bytes]}
      attachment_text+="\n\n[Attachment text truncated at 256 KB.]"
    fi
  else
    attachment_notes+="\n- ${attachment_name}: unsupported binary file (supported: text, common office documents, and images)."
    continue
  fi

  if [[ -z $attachment_text ]]; then
    attachment_notes+="\n- ${attachment_name}: no extractable text was found."
    continue
  fi
  if (( included_text_bytes >= max_total_text_bytes )); then
    attachment_notes+="\n- ${attachment_name}: not included (the 750 KB text limit was reached)."
    continue
  fi
  remaining_text_bytes=$(( max_total_text_bytes - included_text_bytes ))
  if (( ${#attachment_text} > remaining_text_bytes )); then
    attachment_text=${attachment_text[1,remaining_text_bytes]}
    attachment_text+="\n\n[Attachment text truncated because the request reached its 750 KB total limit.]"
  fi
  (( included_text_bytes += ${#attachment_text} ))
  attachment_context+="\n\n===== ATTACHED FILE: ${attachment_name} =====\n${attachment_text}\n===== END ATTACHED FILE: ${attachment_name} ====="
done

if [[ -n $attachment_context || -n $attachment_notes ]]; then
  attachment_context="\n\nUSER-SUPPLIED ATTACHMENTS (the user intentionally selected these items as request context):${attachment_notes}${attachment_context}"
fi
if [[ -n $kimi_attachment_context ]]; then
  kimi_attachment_context="\n\nUSER-SELECTED IMAGE FILES: The user authorized these images for this request. Use ReadMediaFile only for the paths below when visual details are needed; do not inspect any other local files.${kimi_attachment_context}"
fi

prompt=$request
if [[ -n $conversation_context ]]; then
  prompt="The following is the complete prior conversation context. Use it as background for the new request, and do not discard relevant details.\n\n${conversation_context}\n\nNEW FOLLOW-UP REQUEST:\n${request}"
fi
if [[ $allow_tools == false ]]; then
  prompt="Reply to the request below. Do not modify files, execute commands, or make external changes. Do not read, inspect, quote, or report credential material or its paths, including .env files, private-key files, .ssh, keychains, or secrets directories. Give a self-contained answer.\n\nREQUEST:\n${prompt}"
fi
if [[ -n $attachment_context ]]; then
  prompt+="$attachment_context"
fi
if [[ $web_search == true ]]; then
  prompt="${prompt}\n\nONLINE RESEARCH: Use the available web-search and page-fetch tools when current, factual, or source-backed information would improve the answer. Qwen and GLM may have access to Tavily Search and Tavily Extract; prefer those tools when present. When a Tavily key is configured, Meta and DeepSeek receive a shared Tavily research brief. State when you did not search, and cite the sources you relied on."
fi

root=${0:A:h}
timestamp=$(date +%Y%m%d-%H%M%S)
# The app bundle is read-only after distribution. Its desktop shell supplies an
# Application Support directory here, while terminal users retain the familiar
# local `./results` behavior.
results_root=${MODEL_COMPARE_RESULTS_DIR:-"$root/results"}
results_dir="$results_root/$timestamp"
mkdir -p "$results_dir"
# The desktop app uses this notification to enable per-model cancellation as
# soon as the run folder exists, rather than having to wait for a response.
print -r -- "RESULTS_DIR:${results_dir}"

typeset -A pids
typeset -A labels
typeset -A statuses

# The macOS app listens for these small, line-oriented notifications while the
# providers continue running. Responses are still written atomically enough for
# display because each notification is emitted only after its command exits.
response_ready() {
  local key=$1
  print -r -- "RESPONSE_READY:${key}:${results_dir}/${key}.txt"
}

# A per-provider marker is a small, local control channel from the desktop
# app. It lets a person exclude a slow answer without terminating the entire
# comparison or losing the responses that are already complete.
cancellation_requested() {
  local key=$1
  [[ -f "$results_dir/.stop-waiting-${key}" ]]
}

write_manual_skip() {
  local key=$1
  print -r -- "SKIPPED: Waiting for this model was stopped manually. Its response was not included in the synthesis." >"$results_dir/$key.txt"
  print -r -- "130" >"$results_dir/$key.exit"
  response_ready "$key"
}

# Kimi Code returns a provider-side 403 when its subscription's billing-cycle
# allowance has been consumed. That is distinct from a bad key, a malformed
# prompt, or a Model Compare fault, so present it as an actionable skip rather
# than burying the useful explanation in the diagnostics file.
kimi_quota_exhausted() {
  local response_path=$1
  local diagnostics_path=$2
  grep -Eqi \
    -e 'provider\.api_error:[[:space:]]*403.*usage limit' \
    -e 'reached your usage limit for this billing cycle' \
    -e 'quota will be refreshed in the next cycle' \
    "$response_path" "$diagnostics_path" 2>/dev/null
}

write_kimi_quota_skip() {
  local response_path=$1
  local key=${2:-kimi}
  print -r -- "SKIPPED: Kimi Code’s subscription quota is exhausted for the current billing cycle. This is not an authentication or prompt error. Wait for the plan to refresh, or purchase additional Kimi Code usage. In Kimi Code, use /usage to view the reset information." >"$response_path"
  : >"$results_dir/.${key}-quota-exhausted"
}

# Run a provider command while watching for its per-provider cancellation
# marker. Output is written to a temporary path first so a manually stopped
# response never leaks a partial answer into the comparison or synthesis.
run_cancellable_command() {
  local key=$1
  local response_path=$2
  local diagnostics_path=$3
  shift 3
  "$@" >"$response_path" 2>"$diagnostics_path" &
  local command_pid=$!
  print -r -- "$command_pid" >"$results_dir/.${key}.command-pid"

  while kill -0 "$command_pid" 2>/dev/null; do
    if cancellation_requested "$key"; then
      kill -TERM "$command_pid" 2>/dev/null || true
      sleep 0.3
      if kill -0 "$command_pid" 2>/dev/null; then
        kill -KILL "$command_pid" 2>/dev/null || true
      fi
      wait "$command_pid" 2>/dev/null || true
      return 130
    fi
    sleep 0.2
  done
  wait "$command_pid"
}

find_cli() {
  local name=$1
  local candidate
  if (( $+commands[$name] )); then
    print -r -- "$commands[$name]"
    return 0
  fi
  # Finder-launched apps do not inherit a user's shell PATH, so check the
  # documented standalone installer locations before PATH fallbacks.
  for candidate in "$HOME/.kimi-code/bin/$name" \
    "$HOME/.qwen/bin/$name" \
    "$HOME/.local/bin/$name" \
    "/opt/homebrew/bin/$name" \
    "/usr/local/bin/$name"; do
    if [[ -x $candidate ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

# An omitted --provider list retains the script's historical behavior of
# trying every supported CLI. The desktop app always sends an explicit list
# based on its per-provider Include checkboxes.
provider_is_enabled() {
  local key=$1
  local provider
  (( ${#included_providers} == 0 )) && return 0
  for provider in "${included_providers[@]}"; do
    [[ $provider == "$key" ]] && return 0
  done
  return 1
}

run() {
  local key=$1
  shift
  labels[$key]=$key
  (
    setopt local_options no_err_return
    local partial_response="$results_dir/$key.partial.txt"
    local command_status
    if run_cancellable_command "$key" "$partial_response" "$results_dir/$key.stderr" "$@"; then
      command_status=0
    else
      command_status=$?
    fi
    if cancellation_requested "$key"; then
      rm -f "$partial_response"
      write_manual_skip "$key"
      exit 0
    fi
    if [[ $key == kimi && $command_status != 0 ]] && kimi_quota_exhausted "$partial_response" "$results_dir/$key.stderr"; then
      write_kimi_quota_skip "$partial_response" "$key"
      command_status=0
    fi
    mv "$partial_response" "$results_dir/$key.txt"
    print -r -- "$command_status" >"$results_dir/$key.exit"
    # Some CLIs produce a complete answer but still return a non-zero status
    # for a warning or an interrupted optional tool. Preserve that answer and
    # let the report distinguish it from a run with no response at all.
    response_ready "$key"
    exit 0
  ) &
  local child_pid=$!
  # zsh can leave $! unexpanded when a background child cannot be created
  # (notably from a Finder-launched app). Never pass that literal to wait.
  if [[ -z $child_pid || $child_pid == '$!' ]]; then
    statuses[$key]=failed
    print -r -- "FAILED: Could not start the provider process." >"$results_dir/$key.txt"
    response_ready "$key"
    return 0
  fi
  pids[$key]=$child_pid
}

# Meta Model API and DeepSeek API both expose the OpenAI-compatible Chat
# Completions wire format. Keeping this small adapter in the launcher avoids a
# second agent harness, and never puts either key in a command argument or a
# result file. Raw JSON is retained only for response diagnostics.
invoke_openai_compatible_api() {
  local key=$1
  local endpoint=$2
  local model=$3
  local effort=$4
  local request_prompt=$5
  local api_key=""
  local request_body
  local raw_response="$results_dir/$key.raw.json"
  local curl_status

  case "$key" in
    meta) api_key=${META_API_KEY:-} ;;
    deepseek) api_key=${DEEPSEEK_API_KEY:-} ;;
  esac
  if [[ -z $api_key ]]; then
    print -r -- "SKIPPED: Set the ${key:u}_API_KEY to use this API provider."
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    print -r -- "SKIPPED: This API provider needs jq, which is not available on this Mac."
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    print -r -- "SKIPPED: This API provider needs curl, which is not available on this Mac."
    return 1
  fi

  request_body=$(jq -cn \
    --arg model "$model" \
    --arg prompt "$request_prompt" \
    --arg effort "$effort" \
    '{model: $model, messages: [{role: "user", content: $prompt}], stream: false}
     + (if $effort == "default" then {} else {reasoning_effort: $effort} end)') || {
      print -r -- "FAILED: Could not prepare the API request."
      return 1
    }

  /usr/bin/curl --silent --show-error --fail-with-body \
    --connect-timeout 20 --max-time 900 \
    -X POST "$endpoint" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    --data-binary "$request_body" >"$raw_response"
  curl_status=$?

  if [[ -s $raw_response ]] && jq -e 'has("error") and .error != null' "$raw_response" >/dev/null 2>&1; then
    jq -r '"FAILED: " + ((.error.message? // .error // "The API returned an error.") | if type == "string" then . else tostring end)' "$raw_response"
    return 1
  fi
  if (( curl_status != 0 )); then
    print -r -- "FAILED: The API request could not complete. See ${key}.stderr for connection details."
    return "$curl_status"
  fi
  if ! jq -er '.choices[0].message.content // empty' "$raw_response"; then
    print -r -- "FAILED: The API returned no text response. See ${key}.raw.json for diagnostics."
    return 1
  fi
}

# Meta Model API and DeepSeek's OpenAI-compatible endpoint do not share the
# CLI/MCP tool harnesses used by Qwen and GLM. For them, perform one bounded
# Tavily Search request per comparison and attach its answer and sources to
# each direct API request. This keeps web research available without charging
# separate Tavily searches for Meta, DeepSeek, and their possible synthesis.
# Only the new user request is sent to Tavily: prior chat context, attachments,
# API keys, and model responses stay local to Model Compare.
tavily_research_context=""
prepare_direct_api_tavily_research() {
  tavily_research_context=""
  [[ $web_search == true && -n $tavily_key ]] || return 0
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    print -r -- "Tavily research is unavailable because jq or curl is missing; continuing without it."
    return 0
  fi

  local query=$request
  query="${query//$'\n'/ }"
  query="${query[1,4000]}"
  [[ -n ${query//[[:space:]]/} ]] || return 0

  local request_body
  local raw_response="$results_dir/tavily-research.raw.json"
  local diagnostics="$results_dir/tavily-research.stderr"
  local brief="$results_dir/tavily-research.txt"
  request_body=$(jq -cn --arg query "$query" \
    '{query: $query, search_depth: "basic", max_results: 5, include_answer: true, include_raw_content: false}') || {
      print -r -- "Tavily research could not prepare its request; continuing without it."
      return 0
    }

  if ! /usr/bin/curl --silent --show-error --fail-with-body \
    --connect-timeout 15 --max-time 60 \
    -X POST "https://api.tavily.com/search" \
    -H "Authorization: Bearer $tavily_key" \
    -H "Content-Type: application/json" \
    --data-binary "$request_body" >"$raw_response" 2>"$diagnostics"; then
    print -r -- "Tavily research could not complete; Meta and DeepSeek will continue without it."
    return 0
  fi
  if jq -e 'has("error") and .error != null' "$raw_response" >/dev/null 2>&1; then
    local message
    message=$(jq -r '(.error.message? // .error // "unknown error") | if type == "string" then . else tostring end' "$raw_response")
    print -r -- "Tavily research was unavailable ($message); Meta and DeepSeek will continue without it."
    return 0
  fi
  if ! jq -e '((.answer? // "") | type == "string" and length > 0) or ((.results? | type) == "array" and (.results | length) > 0)' "$raw_response" >/dev/null 2>&1; then
    print -r -- "Tavily returned no usable research; Meta and DeepSeek will continue without it."
    return 0
  fi

  jq -r '
    def nonempty_string: type == "string" and length > 0;
    "TAVILY WEB RESEARCH (shared source brief; cite the URLs below when using these facts):" +
    (if (.answer? | nonempty_string) then "\n\nTavily overview:\n" + .answer else "" end) +
    (if ((.results? | type) == "array") and (.results | length) > 0 then
      "\n\nSources:\n" +
      ([.results[]? |
        "- " + (.title // "Untitled source") + "\n  " + (.url // "") +
        (if ((.content? // "") | nonempty_string) then "\n  " + .content else "" end)
      ] | join("\n\n"))
    else "" end) +
    "\n\nUse this brief as external evidence when it is relevant. Do not claim to have searched beyond these supplied sources."
  ' "$raw_response" >"$brief"
  tavily_research_context=$(<"$brief")
  print -r -- "TAVILY_RESEARCH_READY:${brief}"
}

is_retryable_api_error() {
  local response_file=$1
  local diagnostics_file=$2
  # Keep HTTP recognition deliberately strict. The old pattern treated the
  # "http" in an ordinary https:// URL as an HTTP response, then matched a
  # later phrase such as "S&P 500". That made a successful Kimi synthesis look
  # like a 500-level API failure and needlessly ran it again.
  grep -Eqi \
    -e '(^|[^[:alnum:]])API[[:space:]]+Error[[:space:]]*:[[:space:]]*(429|5[0-9]{2})([^[:digit:]]|$)' \
    -e '(^|[^[:alnum:]])HTTP([[:space:]]+(status|error|code))?[[:space:]]*[:=]?[[:space:]]*(429|5[0-9]{2})([^[:digit:]]|$)' \
    -e '(^|[^[:alnum:]])status[[:space:]]+(code[[:space:]]*)?[:=]?[[:space:]]*(429|5[0-9]{2})([^[:digit:]]|$)' \
    -e 'rate limit exceeded|temporar(il)?y (unavailable|overloaded)|server-side issue|try again (later|in a moment)' \
    "$response_file" "$diagnostics_file" 2>/dev/null
}

# Summary providers can occasionally return a transient gateway or overload
# error (for example, Z.AI's 529). Retry only those known temporary failures;
# auth, validation, and other non-transient errors are returned immediately.
run_summary() {
  local key=summary
  labels[$key]=$key
  (
    setopt local_options no_err_return
    local attempt=1
    local max_attempts=3
    local command_status=1
    local attempt_response
    local attempt_diagnostics
    while (( attempt <= max_attempts )); do
      attempt_response="$results_dir/$key.attempt$attempt.txt"
      attempt_diagnostics="$results_dir/$key.attempt$attempt.stderr"
      "$@" >"$attempt_response" 2>"$attempt_diagnostics"
      command_status=$?
      # A completed response can legitimately contain links and discussion of
      # HTTP errors. Only retry when the provider process itself failed and the
      # failure is one of the known transient API conditions.
      if (( attempt < max_attempts && command_status != 0 )) && is_retryable_api_error "$attempt_response" "$attempt_diagnostics"; then
        print -r -- "Temporary summary API error on attempt $attempt of $max_attempts; retrying…" >>"$attempt_diagnostics"
        print -r -- "Temporary summary API error on attempt $attempt of $max_attempts; retrying…"
        sleep $(( attempt * 2 ))
        (( attempt += 1 ))
        continue
      fi
      break
    done
    if [[ $summary_model == kimi && $command_status != 0 ]] && kimi_quota_exhausted "$attempt_response" "$attempt_diagnostics"; then
      write_kimi_quota_skip "$attempt_response" "$key"
      command_status=0
    fi
    cp "$attempt_response" "$results_dir/$key.txt"
    cp "$attempt_diagnostics" "$results_dir/$key.stderr"
    print -r -- "$command_status" >"$results_dir/$key.exit"
    response_ready "$key"
    exit 0
  ) &
  local child_pid=$!
  if [[ -z $child_pid || $child_pid == '$!' ]]; then
    statuses[$key]=failed
    print -r -- "FAILED: Could not start the summary process." >"$results_dir/$key.txt"
    response_ready "$key"
    return 0
  fi
  pids[$key]=$child_pid
}

# Grok Build's plain headless output can contain an initial planning update and
# still exit successfully before a final answer is emitted. JSON mode gives us
# one completed response object; extract only its final `text` field for the
# comparison pane and retain the raw response beside it for troubleshooting.
run_grok() {
  local key=$1
  shift
  local stop_reason
  labels[$key]=$key
  (
    setopt local_options no_err_return
    local raw="$results_dir/$key.raw.json"
    local response="$results_dir/$key.txt"
    local diagnostics="$results_dir/$key.stderr"
    local command_status=1
    local api_attempt=1
    local max_api_attempts=1
    if [[ $key == summary ]]; then max_api_attempts=3; fi
    while (( api_attempt <= max_api_attempts )); do
      if run_cancellable_command "$key" "$raw" "$diagnostics" "$@"; then
        command_status=0
      else
        command_status=$?
      fi
      if cancellation_requested "$key"; then
        write_manual_skip "$key"
        exit 0
      fi
    # Grok occasionally reports a cancelled tool turn but succeeds immediately
    # on a new headless session. Retry that transient condition once and retain
    # the first response for inspection.
      if [[ -s $raw ]] && command -v jq >/dev/null 2>&1 && jq -e '.stopReason == "Cancelled"' "$raw" >/dev/null 2>&1; then
        mv "$raw" "$results_dir/$key.first.raw.json"
        print -r -- "Grok returned a cancelled turn; retrying once…" >>"$diagnostics"
        if run_cancellable_command "$key" "$raw" "$diagnostics" "$@"; then
          command_status=0
        else
          command_status=$?
        fi
        if cancellation_requested "$key"; then
          write_manual_skip "$key"
          exit 0
        fi
      fi
      if (( api_attempt < max_api_attempts )) && is_retryable_api_error "$raw" "$diagnostics"; then
        cp "$raw" "$results_dir/$key.attempt$api_attempt.raw.json"
        cp "$diagnostics" "$results_dir/$key.attempt$api_attempt.stderr"
        print -r -- "Temporary Grok summary API error on attempt $api_attempt of $max_api_attempts; retrying…" >>"$diagnostics"
        print -r -- "Temporary Grok summary API error on attempt $api_attempt of $max_api_attempts; retrying…"
        sleep $(( api_attempt * 2 ))
        (( api_attempt += 1 ))
        continue
      fi
      break
    done
    if [[ -s $raw ]] && command -v jq >/dev/null 2>&1; then
      if ! jq -er 'select(.stopReason == "EndTurn") | .text // empty' "$raw" >"$response" || [[ ! -s $response ]]; then
        if jq -er '.text // empty' "$raw" >"$response" && [[ -s $response ]]; then
          stop_reason=$(jq -r '.stopReason // "unknown"' "$raw")
          print -r -- "\n\n[INCOMPLETE: Grok ended with ${stop_reason}. See grok.raw.json for diagnostics.]" >>"$response"
        else
          jq -r 'if .type == "error" then "FAILED: " + (.message // "Grok returned an error.") else "FAILED: Grok returned an unexpected response. See the raw JSON diagnostics for details." end' "$raw" >"$response" 2>/dev/null
        fi
        if [[ ! -s $response ]]; then cp "$raw" "$response"; fi
        (( command_status == 0 )) && command_status=1
      fi
    elif [[ -s $raw ]]; then
      cp "$raw" "$response"
    else
      : >"$response"
    fi
    print -r -- "$command_status" >"$results_dir/$key.exit"
    response_ready "$key"
    exit 0
  ) &
  local child_pid=$!
  if [[ -z $child_pid || $child_pid == '$!' ]]; then
    statuses[$key]=failed
    print -r -- "FAILED: Could not start the Grok process." >"$results_dir/$key.txt"
    response_ready "$key"
    return 0
  fi
  pids[$key]=$child_pid
}

skip() {
  local key=$1
  local reason=$2
  print -r -- "SKIPPED: $reason" >"$results_dir/$key.txt"
  response_ready "$key"
}

wait_for() {
  local key=$1
  local pid=${pids[$key]:-}
  [[ -n $pid ]] || return 0
  wait "$pid"
  local exit_code=1
  if [[ -f "$results_dir/$key.exit" ]]; then
    exit_code=$(<"$results_dir/$key.exit")
  fi
  if cancellation_requested "$key"; then
    statuses[$key]=skipped
  elif [[ -f "$results_dir/.${key}-quota-exhausted" ]]; then
    statuses[$key]=skipped
  elif [[ $exit_code == 0 ]]; then
    statuses[$key]=ok
  elif [[ -s "$results_dir/$key.txt" ]]; then
    statuses[$key]=completed-with-warning
    print -r -- "Command exited with status $exit_code; see diagnostics if needed." >>"$results_dir/$key.stderr"
  else
    statuses[$key]=failed
    print -r -- "FAILED (exit status $exit_code): See $key.stderr for details." >>"$results_dir/$key.txt"
  fi
}

build_summary_prompt() {
  local summary="You are the synthesis model for a multi-model comparison.\n\n"
  summary+="Analyze the current request and the responses below. Clearly identify where the models agree, where they disagree, important omissions or contradictions, and an overall best answer. Use the prior conversation context when present. Do not claim consensus where there is none. Keep the synthesis self-contained and label model-specific views.\n\n"
  if [[ $web_search == true ]]; then
    summary+="ONLINE RESEARCH: Use the available web-search and page-fetch tools when they help fact-check or reconcile the responses. Qwen and GLM may have access to Tavily Search and Tavily Extract; prefer those tools when present. Cite sources for new factual claims.\n\n"
  fi
  if [[ -n $tavily_research_context ]]; then
    summary+="${tavily_research_context}\n\n"
  fi
  if [[ -n $conversation_context ]]; then
    summary+="PRIOR CONVERSATION CONTEXT:\n${conversation_context}\n\n"
  fi
  summary+="CURRENT REQUEST:\n${request}\n\nMODEL RESPONSES:"
  local key
  for key in codex claude grok glm kimi qwen google meta deepseek; do
    if ! provider_is_enabled "$key"; then
      continue
    fi
    summary+="\n\n===== ${key:u} =====\n"
    if [[ -f "$results_dir/$key.txt" ]]; then
      summary+="$(<"$results_dir/$key.txt")"
    else
      summary+="No response was produced."
    fi
  done
  print -r -- "$summary"
}

codex_bin=${CODEX_BIN:-${commands[codex]:-}}
if [[ -z $codex_bin && -x /Applications/ChatGPT.app/Contents/Resources/codex ]]; then
  codex_bin=/Applications/ChatGPT.app/Contents/Resources/codex
fi

typeset -a codex_args claude_args grok_args glm_args kimi_args qwen_args google_args
typeset -a summary_codex_args summary_claude_args summary_grok_args summary_glm_args summary_kimi_args summary_qwen_args summary_google_args
if [[ $codex_model != default ]]; then codex_args+=(--model "$codex_model"); fi
if [[ $codex_effort != default ]]; then codex_args+=(-c "model_reasoning_effort=$codex_effort"); fi
if [[ $claude_model != default ]]; then claude_args+=(--model "$claude_model"); fi
if [[ $claude_effort != default ]]; then claude_args+=(--effort "$claude_effort"); fi
if [[ $grok_model != default ]]; then grok_args+=(--model "$grok_model"); fi
if [[ $grok_effort != default ]]; then grok_args+=(--reasoning-effort "$grok_effort"); fi
if [[ $glm_effort != default ]]; then glm_args+=(--effort "$glm_effort"); fi
if [[ $kimi_model != default ]]; then kimi_args+=(--model "$kimi_model"); fi
if [[ $qwen_model != default ]]; then qwen_args+=(--model "$qwen_model"); fi
if [[ $google_model != default ]]; then google_args+=(--model "$google_model"); fi
if [[ $google_effort != default ]]; then google_args+=(--effort "$google_effort"); fi
if [[ $summary_model_id != default ]]; then
  case "$summary_model" in
    codex) summary_codex_args+=(--model "$summary_model_id") ;;
    claude) summary_claude_args+=(--model "$summary_model_id") ;;
    grok) summary_grok_args+=(--model "$summary_model_id") ;;
    # GLM's Claude Code-compatible route maps the selected model through the
    # environment below, while the client itself continues to request sonnet.
    glm) ;;
    kimi) summary_kimi_args+=(--model "$summary_model_id") ;;
    qwen) summary_qwen_args+=(--model "$summary_model_id") ;;
    google) summary_google_args+=(--model "$summary_model_id") ;;
  esac
fi
if [[ $summary_effort != default ]]; then
  case "$summary_model" in
    codex) summary_codex_args+=(-c "model_reasoning_effort=$summary_effort") ;;
    claude) summary_claude_args+=(--effort "$summary_effort") ;;
    grok) summary_grok_args+=(--reasoning-effort "$summary_effort") ;;
    glm) summary_glm_args+=(--effort "$summary_effort") ;;
    google) summary_google_args+=(--effort "$summary_effort") ;;
  esac
fi

# Codex offers native live web search through its global --search switch.
# Claude Code's WebSearch/WebFetch tools are intentionally the only tools
# available in safe mode. In `-p` (headless) mode a tool must also be explicitly
# allowed or Claude cannot answer its approval prompt. `dontAsk` then denies
# anything other than those two read-only web tools.
typeset -a codex_headless_args claude_headless_args glm_headless_args glm_mcp_args
if [[ $web_search == true ]]; then
  codex_headless_args+=(--search)
  if [[ $allow_tools == false ]]; then
    claude_headless_args+=(--tools "WebSearch,WebFetch" --allowed-tools "WebSearch,WebFetch" --permission-mode dontAsk)
  else
    claude_headless_args+=(--tools default --allowed-tools "WebSearch,WebFetch")
  fi
elif [[ $allow_tools == false ]]; then
  claude_headless_args+=(--tools "" --permission-mode dontAsk)
else
  claude_headless_args+=(--disallowed-tools "WebSearch,WebFetch")
fi
if [[ $allow_tools == false ]]; then
  codex_headless_args+=(--sandbox read-only --ask-for-approval never)
fi

# GLM is served through Claude Code. When an external Tavily key is present,
# give this temporary GLM process only Tavily's remote MCP plus the existing
# read-only web tools. The key is written to a 600-permission temporary JSON
# file for this launcher only, then removed on exit; it is never added to the
# user's Claude Code configuration.
glm_headless_args=("${claude_headless_args[@]}")
tavily_mcp_config=""
if [[ $web_search == true && -n $tavily_key ]]; then
  # BSD/macOS mktemp requires the XXXXXX placeholder to end the template.
  # The MCP loader does not require a .json extension.
  tavily_mcp_config=$(mktemp "${TMPDIR%/}/model-compare-tavily.XXXXXX")
  chmod 600 "$tavily_mcp_config"
  printf '{"mcpServers":{"tavily":{"type":"http","url":"https://mcp.tavily.com/mcp/?tavilyApiKey=%s"}}}\n' "$tavily_key" > "$tavily_mcp_config"
  glm_mcp_args=(--mcp-config "$tavily_mcp_config" --strict-mcp-config)
  if [[ $allow_tools == false ]]; then
    glm_headless_args=(--tools "WebSearch,WebFetch" --allowed-tools "WebSearch,WebFetch,mcp__tavily" --permission-mode dontAsk)
  else
    glm_headless_args=(--tools default --allowed-tools "WebSearch,WebFetch,mcp__tavily")
  fi
fi
cleanup_tavily_mcp_config() {
  [[ -n $tavily_mcp_config && -f $tavily_mcp_config ]] && rm -f -- "$tavily_mcp_config"
}
trap cleanup_tavily_mcp_config EXIT
# Codex accepts image files as global options before `exec`. Keep this separate
# from the prompt so images retain their original visual fidelity.
for attachment in "${image_attachments[@]}"; do
  codex_headless_args+=(--image "$attachment")
done

# Qwen Code's Alibaba ModelStudio Coding Plan and Token Plan use the
# OpenAI-compatible `openai` auth type. Supplying it prevents headless Qwen
# from asking the user to choose an auth type, while its prior interactive
# /auth setup supplies the plan-specific key, model configuration, and regional
# endpoint. Plan approval mode keeps the default comparison read-only; with
# --allow-tools, Auto mode lets Qwen approve only actions its policy classifies
# as safe. Qwen's research capability is supplied by configured MCP servers.
# Model Compare passes the remembered Tavily key only to this child process; its
# persistent Qwen MCP definition holds an environment-variable placeholder,
# never the key itself. The legacy Z.AI search variable remains compatible.
typeset -a qwen_headless_args
qwen_headless_args=(--auth-type openai)
if [[ $allow_tools == false ]]; then
  qwen_headless_args+=(--approval-mode plan)
else
  # Qwen's Auto mode can still deny a web fetch in a non-interactive run,
  # leaving no way for the approval prompt to be answered. The user has
  # explicitly turned Safe mode off, so use Qwen's documented unattended
  # mode to approve those requests. The surrounding prompt still directs the
  # model not to make local changes unless the user requested that work.
  qwen_headless_args+=(--yolo)
fi

# Google AI Pro/Ultra consumer subscriptions now use Antigravity CLI (`agy`).
# Its documented print mode emits one final response to stdout. In safe mode,
# Antigravity plan mode plus its terminal sandbox preserves the app's read-only
# comparison contract while still allowing the agent's available research tools.
typeset -a google_headless_args
if [[ $allow_tools == false ]]; then
  google_headless_args=(--mode plan --sandbox)
else
  google_headless_args=(--mode accept-edits --dangerously-skip-permissions)
fi

# In headless mode Grok asks for tool approval even for web research. Approve
# only the read-only research path by removing all local file, terminal,
# background-task, and integration tools in normal (safe) comparisons.
typeset -a grok_headless_args
grok_headless_args=(--no-plan --always-approve --output-format json)
if [[ $allow_tools == false ]]; then
  grok_headless_args+=(--disallowed-tools "run_terminal_cmd,search_replace,read_file,grep,list_dir,task,todo_write,search_tool,use_tool")
fi

# Use one cost-bounded Tavily Search brief for direct API providers whenever a
# saved Tavily key exists. Standard CLI providers retain their native tools.
direct_api_needs_tavily=false
if [[ -n ${META_API_KEY:-} ]] && { provider_is_enabled meta || [[ $summary_model == meta ]]; }; then
  direct_api_needs_tavily=true
fi
if [[ -n ${DEEPSEEK_API_KEY:-} ]] && { provider_is_enabled deepseek || [[ $summary_model == deepseek ]]; }; then
  direct_api_needs_tavily=true
fi
direct_api_prompt="$prompt"

if ! provider_is_enabled codex; then
  skip codex "Not selected for this comparison."
elif [[ -n $codex_bin ]]; then
  run codex "$codex_bin" "${codex_headless_args[@]}" exec --skip-git-repo-check "${codex_args[@]}" "$prompt"
else
  skip codex "Codex CLI is not on PATH. Set CODEX_BIN to its full path if it is installed."
fi

claude_bin=$(find_cli claude || true)
if ! provider_is_enabled claude; then
  skip claude "Not selected for this comparison."
elif [[ -n $claude_bin ]]; then
  run claude "$claude_bin" "${claude_headless_args[@]}" "${claude_args[@]}" -p "$prompt" --output-format text
else
  skip claude "Claude Code is not installed or not on PATH."
fi

google_bin=${AGY_BIN:-$(find_cli agy || true)}
if ! provider_is_enabled google; then
  skip google "Not selected for this comparison."
elif [[ -n $google_bin ]]; then
  run google "$google_bin" "${google_headless_args[@]}" "${google_args[@]}" -p "$prompt" --output-format text
else
  skip google "Antigravity CLI is not installed or not on PATH. Install or set AGY_BIN to its full path."
fi

# Start the local CLI providers before the bounded Tavily request, so their
# responses can continue to appear promptly while the direct API research brief
# is being prepared.
if [[ $direct_api_needs_tavily == true ]]; then
  prepare_direct_api_tavily_research
fi
if [[ -n $tavily_research_context ]]; then
  direct_api_prompt+="\n\n${tavily_research_context}"
fi

# Meta Model API is OpenAI-compatible. Muse Spark 1.2 is selected by default;
# the user can supply a different account-available identifier in the editable
# model field. This is a direct API request, not the Meta AI consumer app.
if ! provider_is_enabled meta; then
  skip meta "Not selected for this comparison."
elif [[ -z ${META_API_KEY:-} ]]; then
  skip meta "Set a Meta Model API key in Model Compare to include Muse Spark."
else
  meta_selected_model=$meta_model
  if [[ $meta_selected_model == default ]]; then meta_selected_model=muse-spark-1.2; fi
  run meta invoke_openai_compatible_api meta \
    "https://api.meta.ai/v1/chat/completions" \
    "$meta_selected_model" "$meta_effort" "$direct_api_prompt"
fi

# DeepSeek's current V4 models use the same OpenAI-compatible endpoint. Their
# `reasoning_effort` accepts high/max; when left at Default the API uses its
# own model default. DeepSeek does not expose native web search in this route.
if ! provider_is_enabled deepseek; then
  skip deepseek "Not selected for this comparison."
elif [[ -z ${DEEPSEEK_API_KEY:-} ]]; then
  skip deepseek "Set a DeepSeek API key in Model Compare to include DeepSeek."
else
  deepseek_selected_model=$deepseek_model
  if [[ $deepseek_selected_model == default ]]; then deepseek_selected_model=deepseek-v4-pro; fi
  run deepseek invoke_openai_compatible_api deepseek \
    "https://api.deepseek.com/chat/completions" \
    "$deepseek_selected_model" "$deepseek_effort" "$direct_api_prompt"
fi

grok_bin=$(find_cli grok || true)
if ! provider_is_enabled grok; then
  skip grok "Not selected for this comparison."
elif [[ -n $grok_bin ]]; then
  run_grok grok "$grok_bin" "${grok_args[@]}" "${grok_headless_args[@]}" -p "$prompt"
else
  skip grok "Grok Build is not installed or not on PATH."
fi

# Kimi Code supports a one-prompt `-p` mode and its own OAuth login. Its
# upstream CLI uses automatic regular-tool approval in that mode, so require
# the caller to explicitly leave Safe mode before launching it.
# Respect an explicit override, then look in Kimi Code's installer location.
# This is particularly important from Finder, whose environment often omits
# the PATH changes written by a user's shell profile.
kimi_bin=${KIMI_BIN:-$(find_cli kimi || true)}
if ! provider_is_enabled kimi; then
  skip kimi "Not selected for this comparison."
elif [[ -z $kimi_bin ]]; then
  skip kimi "Kimi Code is not installed or not on PATH."
elif [[ $allow_tools == false ]]; then
  skip kimi "Kimi Code requires --allow-tools because its non-interactive mode auto-approves regular tool calls."
else
  kimi_prompt="${prompt}${kimi_attachment_context}"
  run kimi "$kimi_bin" "${kimi_args[@]}" -p "$kimi_prompt" --output-format text
fi

# Qwen Code is authenticated and configured once in its own interactive
# /auth flow. Respect a direct override for Finder-launched or custom installs.
qwen_bin=${QWEN_BIN:-$(find_cli qwen || true)}
if ! provider_is_enabled qwen; then
  skip qwen "Not selected for this comparison."
elif [[ -z $qwen_bin ]]; then
  skip qwen "Qwen Code is not installed or not on PATH."
else
  qwen_search_key=${Z_AI_API_KEY:-${ZAI_API_KEY:-}}
  typeset -a qwen_environment
  qwen_environment=(env)
  if [[ -n $qwen_search_key ]]; then
    qwen_environment+=("Z_AI_API_KEY=$qwen_search_key")
  fi
  if [[ -n $tavily_key ]]; then
    qwen_environment+=("TAVILY_API_KEY=$tavily_key")
  fi
  if (( ${#qwen_environment} > 1 )); then
    run qwen "${qwen_environment[@]}" "$qwen_bin" "${qwen_headless_args[@]}" "${qwen_args[@]}" -p "$prompt" --output-format text
  else
    run qwen "$qwen_bin" "${qwen_headless_args[@]}" "${qwen_args[@]}" -p "$prompt" --output-format text
  fi
fi

# GLM's Coding Plan must be called through an approved client. This temporary
# environment routes this one Claude Code process to Z.AI without persisting a
# key or changing the user's normal Claude Code configuration.
if ! provider_is_enabled glm; then
  skip glm "Not selected for this comparison."
elif [[ -n ${ZAI_API_KEY:-} && -n $claude_bin ]]; then
  glm_selected_model=${glm_model}
  if [[ $glm_selected_model == default ]]; then glm_selected_model=glm-5.2; fi
  run glm env \
    "ANTHROPIC_AUTH_TOKEN=$ZAI_API_KEY" \
    "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic" \
    "API_TIMEOUT_MS=3000000" \
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" \
    "ANTHROPIC_DEFAULT_OPUS_MODEL=$glm_selected_model" \
    "ANTHROPIC_DEFAULT_SONNET_MODEL=$glm_selected_model" \
    "ANTHROPIC_DEFAULT_HAIKU_MODEL=$glm_selected_model" \
    "$claude_bin" "${glm_headless_args[@]}" "${glm_mcp_args[@]}" "${glm_args[@]}" --model sonnet -p "$prompt" --output-format text
elif [[ -n ${ZAI_API_KEY:-} ]]; then
  skip glm "ZAI_API_KEY is set, but Claude Code is not installed."
else
  skip glm "Set ZAI_API_KEY for this session to include the GLM Coding Plan."
fi

print "Running available models in parallel…"
for key in ${(k)pids}; do
  wait_for "$key"
done

if [[ $summary_model != none ]]; then
  print "Synthesizing responses with ${summary_model}…"
  summary_prompt=$(build_summary_prompt)
  case "$summary_model" in
    codex)
      if [[ -n $codex_bin ]]; then
        run_summary "$codex_bin" "${codex_headless_args[@]}" exec --skip-git-repo-check "${summary_codex_args[@]}" "$summary_prompt"
      else
        skip summary "Codex is not available for synthesis."
      fi
      ;;
    claude)
      if [[ -n $claude_bin ]]; then
        run_summary "$claude_bin" "${claude_headless_args[@]}" "${summary_claude_args[@]}" -p "$summary_prompt" --output-format text
      else
        skip summary "Claude Code is not available for synthesis."
      fi
      ;;
    grok)
      if [[ -n $grok_bin ]]; then
        run_grok summary "$grok_bin" "${summary_grok_args[@]}" "${grok_headless_args[@]}" -p "$summary_prompt"
      else
        skip summary "Grok Build is not available for synthesis."
      fi
      ;;
    glm)
      if [[ -n ${ZAI_API_KEY:-} && -n $claude_bin ]]; then
        glm_selected_model=${summary_model_id}
        if [[ $glm_selected_model == default ]]; then glm_selected_model=glm-5.2; fi
        run_summary env \
          "ANTHROPIC_AUTH_TOKEN=$ZAI_API_KEY" \
          "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic" \
          "API_TIMEOUT_MS=3000000" \
          "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" \
          "ANTHROPIC_DEFAULT_OPUS_MODEL=$glm_selected_model" \
          "ANTHROPIC_DEFAULT_SONNET_MODEL=$glm_selected_model" \
          "ANTHROPIC_DEFAULT_HAIKU_MODEL=$glm_selected_model" \
          "$claude_bin" "${glm_headless_args[@]}" "${glm_mcp_args[@]}" "${summary_glm_args[@]}" --model sonnet -p "$summary_prompt" --output-format text
      else
        skip summary "GLM synthesis requires a Z.AI key and Claude Code."
      fi
      ;;
    kimi)
      if [[ -z $kimi_bin ]]; then
        skip summary "Kimi Code is not installed or not on PATH."
      elif [[ $allow_tools == false ]]; then
        skip summary "Kimi Code synthesis requires --allow-tools because its non-interactive mode auto-approves regular tool calls."
      else
        kimi_summary_prompt="${summary_prompt}${kimi_attachment_context}"
        run_summary "$kimi_bin" "${summary_kimi_args[@]}" -p "$kimi_summary_prompt" --output-format text
      fi
      ;;
    qwen)
      if [[ -n $qwen_bin ]]; then
        run_summary "$qwen_bin" "${qwen_headless_args[@]}" "${summary_qwen_args[@]}" -p "$summary_prompt" --output-format text
      else
        skip summary "Qwen Code is not installed or not on PATH."
      fi
      ;;
    google)
      if [[ -n $google_bin ]]; then
        run_summary "$google_bin" "${google_headless_args[@]}" "${summary_google_args[@]}" -p "$summary_prompt" --output-format text
      else
        skip summary "Antigravity CLI is not installed or not on PATH."
      fi
      ;;
    meta)
      if [[ -n ${META_API_KEY:-} ]]; then
        meta_summary_model=$summary_model_id
        if [[ $meta_summary_model == default ]]; then meta_summary_model=muse-spark-1.2; fi
        run_summary invoke_openai_compatible_api meta \
          "https://api.meta.ai/v1/chat/completions" \
          "$meta_summary_model" "$summary_effort" "$summary_prompt"
      else
        skip summary "Meta synthesis requires a Meta Model API key."
      fi
      ;;
    deepseek)
      if [[ -n ${DEEPSEEK_API_KEY:-} ]]; then
        deepseek_summary_model=$summary_model_id
        if [[ $deepseek_summary_model == default ]]; then deepseek_summary_model=deepseek-v4-pro; fi
        run_summary invoke_openai_compatible_api deepseek \
          "https://api.deepseek.com/chat/completions" \
          "$deepseek_summary_model" "$summary_effort" "$summary_prompt"
      else
        skip summary "DeepSeek synthesis requires a DeepSeek API key."
      fi
      ;;
    *)
      skip summary "Unknown summary model: $summary_model"
      ;;
  esac
  wait_for summary
else
  skip summary "No summary model selected."
fi

{
  print "# Model comparison"
  print
  print "Prompt: ${request}"
  print "Summary model: ${summary_model}"
  print
  print "| Model | Status | Response | Diagnostics |"
  print "| --- | --- | --- | --- |"
  for key in codex claude google meta deepseek grok glm kimi qwen summary; do
    if [[ -n ${statuses[$key]:-} ]]; then
      print "| $key | ${statuses[$key]} | [$key.txt]($key.txt) | [$key.stderr]($key.stderr) |"
    else
      print "| $key | skipped | [$key.txt]($key.txt) | — |"
    fi
  done
} >"$results_dir/README.md"

print "Done. Open: $results_dir/README.md"
