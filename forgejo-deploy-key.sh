#!/bin/sh
#
# forgejo-deploy-key.sh
#
# Generate a passphrase-less SSH key pair, register the public half as a deploy
# key on a Forgejo repository, and store the private half - together with a
# known_hosts file, either supplied by you or fetched with ssh-keyscan - in a
# Kubernetes secret laid out the way Flux expects:
#
#   identity       private key
#   identity.pub   public key
#   known_hosts    the known_hosts file you provided
#
# Settings come from a config file (see forgejo-deploy-key.conf.example); any
# of them can be overridden with a flag. The API token is read separately from
# an env file (default ./.env) or from $FORGEJO_TOKEN in the environment.
#
# The private key never touches disk outside a mode-0700 temporary directory
# that is removed on exit, unless you ask for it with --keep-key-dir.
#
# Requires: ssh-keygen, curl, kubectl, plus ssh-keyscan when scanning host keys.
# jq is used if present, not required.

set -eu
umask 077

PROG=$(basename "$0")

# ---------------------------------------------------------------- diagnostics

info() { printf '%s\n' "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $PROG [options]

Creates an SSH key pair, stores it in a Kubernetes secret and registers the
public key as a deploy key on a Forgejo repository.

Options:
  -c, --config FILE      config file (default: ./forgejo-deploy-key.conf)
      --env-file FILE    file holding FORGEJO_TOKEN (default: ./.env)
  -u, --url URL          Forgejo base URL, e.g. https://git.example.com
  -r, --repo OWNER/REPO  target repository
  -n, --namespace NS     Kubernetes namespace for the secret
  -s, --secret NAME      Kubernetes secret name
  -k, --known-hosts FILE known_hosts file to embed, instead of scanning
      --scan             fetch host keys with ssh-keyscan even if a
                         known_hosts file is configured
      --ssh-host HOST    host to scan (default: the host in the Forgejo URL)
  -p, --ssh-port PORT    SSH port of the Forgejo host (default: 22)
      --save-known-hosts FILE
                         also write the scanned host keys here
  -t, --title TITLE      deploy key title shown in Forgejo
      --key-type TYPE    ed25519 (default) or rsa
      --read-write       register a writable deploy key (default: read-only)
      --context CTX      kubectl context to use
      --replace          overwrite the secret if it already exists
      --keep-key-dir DIR write identity, identity.pub and the fingerprint here
      --dry-run          show what would happen, change nothing
  -y, --yes              do not ask for confirmation
  -h, --help             this text

Host keys come from --known-hosts / KNOWN_HOSTS_FILE when set, otherwise they
are fetched with ssh-keyscan. Either way the fingerprints are printed before
anything is created - check them against what your Forgejo instance publishes.

Config file keys (all optional if given as flags):
  FORGEJO_URL  FORGEJO_REPO  NAMESPACE  SECRET_NAME  KNOWN_HOSTS_FILE
  SSH_HOST  SSH_PORT  KEY_TITLE  KEY_TYPE  READ_ONLY  KUBE_CONTEXT

Precedence: flags > config file > defaults.
EOF
}

# ------------------------------------------------------------------- defaults

CONFIG_FILE=./forgejo-deploy-key.conf
ENV_FILE=./.env

FORGEJO_URL=""
FORGEJO_REPO=""
NAMESPACE=""
SECRET_NAME=""
KNOWN_HOSTS_FILE=""
SSH_HOST=""
SSH_PORT=22
KEY_TITLE=""
KEY_TYPE=ed25519
READ_ONLY=true
KUBE_CONTEXT=""

# flag overrides, applied after the config file is read
F_URL=""; F_REPO=""; F_NS=""; F_SECRET=""; F_KNOWN_HOSTS=""
F_TITLE=""; F_KEY_TYPE=""; F_READ_ONLY=""; F_CONTEXT=""
F_SSH_HOST=""; F_SSH_PORT=""

REPLACE=no
DRY_RUN=no
ASSUME_YES=no
KEEP_KEY_DIR=""
CONFIG_EXPLICIT=no
FORCE_SCAN=no
SAVE_KNOWN_HOSTS=""

WORKDIR=""
CREATED_KEY_ID=""

# --------------------------------------------------------------------- helpers

trim() {
	# strip leading and trailing blanks
	printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

unquote() {
	_v=$1
	case $_v in
		\"*\") _v=${_v#\"}; _v=${_v%\"} ;;
		\'*\') _v=${_v#\'}; _v=${_v%\'} ;;
	esac
	printf '%s' "$_v"
}

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

kc() {
	if [ -n "$KUBE_CONTEXT" ]; then
		kubectl --context "$KUBE_CONTEXT" "$@"
	else
		kubectl "$@"
	fi
}

cleanup() {
	if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
		rm -rf "$WORKDIR"
	fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------- config files

load_config() {
	_file=$1
	_line_no=0
	while IFS= read -r _line || [ -n "$_line" ]; do
		_line_no=$((_line_no + 1))
		_line=$(trim "$_line")
		case $_line in
			''|\#*) continue ;;
			*=*) ;;
			*) die "$_file:$_line_no: not a KEY=VALUE line: $_line" ;;
		esac
		_key=$(trim "${_line%%=*}")
		_val=$(unquote "$(trim "${_line#*=}")")
		[ -n "$_val" ] || continue
		case $_key in
			FORGEJO_URL)      FORGEJO_URL=$_val ;;
			FORGEJO_REPO)     FORGEJO_REPO=$_val ;;
			NAMESPACE)        NAMESPACE=$_val ;;
			SECRET_NAME)      SECRET_NAME=$_val ;;
			KNOWN_HOSTS_FILE) KNOWN_HOSTS_FILE=$_val ;;
			SSH_HOST)         SSH_HOST=$_val ;;
			SSH_PORT)         SSH_PORT=$_val ;;
			KEY_TITLE)        KEY_TITLE=$_val ;;
			KEY_TYPE)         KEY_TYPE=$_val ;;
			READ_ONLY)        READ_ONLY=$_val ;;
			KUBE_CONTEXT)     KUBE_CONTEXT=$_val ;;
			FORGEJO_TOKEN)
				die "$_file:$_line_no: keep FORGEJO_TOKEN out of the config file, put it in $ENV_FILE" ;;
			*) die "$_file:$_line_no: unknown setting: $_key" ;;
		esac
	done < "$_file"
}

load_token() {
	# environment wins, so CI can inject the token without a file
	if [ -n "${FORGEJO_TOKEN:-}" ]; then
		return 0
	fi
	FORGEJO_TOKEN=""
	[ -f "$ENV_FILE" ] || return 0
	while IFS= read -r _line || [ -n "$_line" ]; do
		_line=$(trim "$_line")
		case $_line in
			export\ *) _line=$(trim "${_line#export }") ;;
		esac
		case $_line in
			FORGEJO_TOKEN=*) FORGEJO_TOKEN=$(unquote "$(trim "${_line#*=}")") ;;
		esac
	done < "$ENV_FILE"
}

# ------------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
	case $1 in
		-c|--config)      [ $# -ge 2 ] || die "$1 needs a value"; CONFIG_FILE=$2; CONFIG_EXPLICIT=yes; shift 2 ;;
		--env-file)       [ $# -ge 2 ] || die "$1 needs a value"; ENV_FILE=$2; shift 2 ;;
		-u|--url)         [ $# -ge 2 ] || die "$1 needs a value"; F_URL=$2; shift 2 ;;
		-r|--repo)        [ $# -ge 2 ] || die "$1 needs a value"; F_REPO=$2; shift 2 ;;
		-n|--namespace)   [ $# -ge 2 ] || die "$1 needs a value"; F_NS=$2; shift 2 ;;
		-s|--secret)      [ $# -ge 2 ] || die "$1 needs a value"; F_SECRET=$2; shift 2 ;;
		-k|--known-hosts) [ $# -ge 2 ] || die "$1 needs a value"; F_KNOWN_HOSTS=$2; shift 2 ;;
		--ssh-host)       [ $# -ge 2 ] || die "$1 needs a value"; F_SSH_HOST=$2; shift 2 ;;
		-p|--ssh-port)    [ $# -ge 2 ] || die "$1 needs a value"; F_SSH_PORT=$2; shift 2 ;;
		--save-known-hosts) [ $# -ge 2 ] || die "$1 needs a value"; SAVE_KNOWN_HOSTS=$2; shift 2 ;;
		--scan)           FORCE_SCAN=yes; shift ;;
		-t|--title)       [ $# -ge 2 ] || die "$1 needs a value"; F_TITLE=$2; shift 2 ;;
		--key-type)       [ $# -ge 2 ] || die "$1 needs a value"; F_KEY_TYPE=$2; shift 2 ;;
		--context)        [ $# -ge 2 ] || die "$1 needs a value"; F_CONTEXT=$2; shift 2 ;;
		--keep-key-dir)   [ $# -ge 2 ] || die "$1 needs a value"; KEEP_KEY_DIR=$2; shift 2 ;;
		--read-write)     F_READ_ONLY=false; shift ;;
		--read-only)      F_READ_ONLY=true; shift ;;
		--replace)        REPLACE=yes; shift ;;
		--dry-run)        DRY_RUN=yes; shift ;;
		-y|--yes)         ASSUME_YES=yes; shift ;;
		-h|--help)        usage; exit 0 ;;
		--)               shift; break ;;
		-*)               die "unknown option: $1 (try --help)" ;;
		*)                die "unexpected argument: $1 (try --help)" ;;
	esac
done

if [ -f "$CONFIG_FILE" ]; then
	load_config "$CONFIG_FILE"
elif [ "$CONFIG_EXPLICIT" = yes ]; then
	die "config file not found: $CONFIG_FILE"
fi

[ -n "$F_URL" ]         && FORGEJO_URL=$F_URL
[ -n "$F_REPO" ]        && FORGEJO_REPO=$F_REPO
[ -n "$F_NS" ]          && NAMESPACE=$F_NS
[ -n "$F_SECRET" ]      && SECRET_NAME=$F_SECRET
[ -n "$F_KNOWN_HOSTS" ] && KNOWN_HOSTS_FILE=$F_KNOWN_HOSTS
[ -n "$F_SSH_HOST" ]    && SSH_HOST=$F_SSH_HOST
[ -n "$F_SSH_PORT" ]    && SSH_PORT=$F_SSH_PORT
[ -n "$F_TITLE" ]       && KEY_TITLE=$F_TITLE
[ -n "$F_KEY_TYPE" ]    && KEY_TYPE=$F_KEY_TYPE
[ -n "$F_READ_ONLY" ]   && READ_ONLY=$F_READ_ONLY
[ -n "$F_CONTEXT" ]     && KUBE_CONTEXT=$F_CONTEXT

load_token

# ------------------------------------------------------------------ validation

need_cmd ssh-keygen
need_cmd curl
need_cmd kubectl

[ -n "$FORGEJO_URL" ]      || die "no Forgejo URL (set FORGEJO_URL or pass --url)"
[ -n "$FORGEJO_REPO" ]     || die "no repository (set FORGEJO_REPO or pass --repo)"
[ -n "$NAMESPACE" ]        || die "no namespace (set NAMESPACE or pass --namespace)"
[ -n "${FORGEJO_TOKEN:-}" ] || die "no API token: set FORGEJO_TOKEN in the environment or in $ENV_FILE"

# strip any trailing slashes from the base URL
while :; do
	case $FORGEJO_URL in
		*/) FORGEJO_URL=${FORGEJO_URL%/} ;;
		*)  break ;;
	esac
done
case $FORGEJO_URL in
	http://*|https://*) ;;
	*) die "FORGEJO_URL must start with http:// or https://: $FORGEJO_URL" ;;
esac

case $FORGEJO_REPO in
	*/*/*|/*|*/) die "repository must be OWNER/REPO: $FORGEJO_REPO" ;;
	*/*) ;;
	*) die "repository must be OWNER/REPO: $FORGEJO_REPO" ;;
esac
REPO_NAME=${FORGEJO_REPO#*/}

case $KEY_TYPE in
	ed25519|rsa) ;;
	*) die "unsupported key type: $KEY_TYPE (use ed25519 or rsa)" ;;
esac

case $READ_ONLY in
	true|false) ;;
	*) die "READ_ONLY must be true or false, got: $READ_ONLY" ;;
esac

[ -n "$SECRET_NAME" ] || SECRET_NAME="${REPO_NAME}-deploy-key"
[ -n "$KEY_TITLE" ]   || KEY_TITLE="k8s:${NAMESPACE}/${SECRET_NAME}"

# Kubernetes object names are DNS-1123 subdomains
if ! printf '%s' "$SECRET_NAME" | grep -qE '^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'; then
	die "not a valid secret name: $SECRET_NAME"
fi

# SSH host defaults to the host in the Forgejo URL, minus any HTTP port
if [ -z "$SSH_HOST" ]; then
	SSH_HOST=$(printf '%s' "$FORGEJO_URL" | sed -e 's|^https\{0,1\}://||' -e 's|/.*$||' -e 's|:[0-9]*$||')
	[ -n "$SSH_HOST" ] || die "cannot derive the SSH host from $FORGEJO_URL; set SSH_HOST or pass --ssh-host"
fi

if ! printf '%s' "$SSH_PORT" | grep -qE '^[0-9]+$' || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
	die "not a valid SSH port: $SSH_PORT"
fi

# Host keys: an explicit file wins, otherwise ssh-keyscan the Forgejo host.
if [ -n "$KNOWN_HOSTS_FILE" ] && [ "$FORCE_SCAN" != yes ]; then
	KNOWN_HOSTS_SOURCE=file
	[ -f "$KNOWN_HOSTS_FILE" ] || die "known_hosts file not found: $KNOWN_HOSTS_FILE
     drop the setting to scan $SSH_HOST port $SSH_PORT instead, or pass --scan"
	[ -s "$KNOWN_HOSTS_FILE" ] || die "known_hosts file is empty: $KNOWN_HOSTS_FILE"
else
	KNOWN_HOSTS_SOURCE=scan
	need_cmd ssh-keyscan
fi

if [ -n "$SAVE_KNOWN_HOSTS" ] && [ "$KNOWN_HOSTS_SOURCE" != scan ]; then
	die "--save-known-hosts only applies when host keys are scanned (pass --scan)"
fi

if [ -n "$KEEP_KEY_DIR" ] && [ ! -d "$KEEP_KEY_DIR" ]; then
	die "--keep-key-dir is not a directory: $KEEP_KEY_DIR"
fi

API="$FORGEJO_URL/api/v1"

# --------------------------------------------------------- cluster preflight

if ! kc version --request-timeout=10s >/dev/null 2>&1; then
	die "cannot reach the cluster with kubectl${KUBE_CONTEXT:+ (context $KUBE_CONTEXT)}"
fi

if ! kc get namespace "$NAMESPACE" >/dev/null 2>&1; then
	die "namespace does not exist: $NAMESPACE"
fi

SECRET_EXISTS=no
if kc -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
	SECRET_EXISTS=yes
	if [ "$REPLACE" != yes ]; then
		die "secret $NAMESPACE/$SECRET_NAME already exists (pass --replace to overwrite it)"
	fi
fi

# ---------------------------------------------------------------- host keys

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/forgejo-deploy-key.XXXXXX") || die "cannot create a temporary directory"
chmod 700 "$WORKDIR"

if [ "$KNOWN_HOSTS_SOURCE" = scan ]; then
	KNOWN_HOSTS="$WORKDIR/known_hosts"
	info "scanning host keys of $SSH_HOST port $SSH_PORT ..."
	ssh-keyscan -T 10 -p "$SSH_PORT" "$SSH_HOST" > "$WORKDIR/keyscan.raw" 2>"$WORKDIR/keyscan.err" || true
	# ssh-keyscan puts its banner comments on stdout; keep the file to the keys
	# themselves plus one line saying where they came from. No timestamp, so
	# re-running produces a byte-identical secret.
	{
		printf '# host keys of %s port %s, fetched with ssh-keyscan\n' "$SSH_HOST" "$SSH_PORT"
		grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$WORKDIR/keyscan.raw" || true
	} > "$KNOWN_HOSTS"
	if ! grep -qv '^#' "$KNOWN_HOSTS"; then
		KEYSCAN_ERR=$(sed -n '1,3p' "$WORKDIR/keyscan.err")
		die "ssh-keyscan returned no host keys for $SSH_HOST port $SSH_PORT${KEYSCAN_ERR:+
     $KEYSCAN_ERR}
     Nothing is answering there, or it does not speak SSH. Check the host and
     port, or supply the keys yourself with --known-hosts FILE."
	fi
	KNOWN_HOSTS_ORIGIN="scanned from $SSH_HOST port $SSH_PORT"
else
	KNOWN_HOSTS=$KNOWN_HOSTS_FILE
	KNOWN_HOSTS_ORIGIN="from $KNOWN_HOSTS_FILE"
fi

if ! grep -qE '(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-ss[hd])' "$KNOWN_HOSTS"; then
	die "no host key found in $KNOWN_HOSTS_ORIGIN"
fi

# ------------------------------------------------------------------- the plan

if [ "$READ_ONLY" = true ]; then
	ACCESS="read-only"
else
	ACCESS="read-write"
fi

info "Forgejo:     $FORGEJO_URL"
info "Repository:  $FORGEJO_REPO"
info "SSH remote:  git@$SSH_HOST:$SSH_PORT"
info "Deploy key:  $KEY_TITLE ($KEY_TYPE, $ACCESS)"
info "Secret:      $NAMESPACE/$SECRET_NAME${KUBE_CONTEXT:+ (context $KUBE_CONTEXT)}$([ "$SECRET_EXISTS" = yes ] && printf ' [will be replaced]')"
info "known_hosts: $KNOWN_HOSTS_ORIGIN"
if HOST_FINGERPRINTS=$(ssh-keygen -lf "$KNOWN_HOSTS" 2>/dev/null); then
	printf '%s\n' "$HOST_FINGERPRINTS" | sed 's/^/             /' >&2
else
	info "             (could not read fingerprints from $KNOWN_HOSTS)"
fi
info "             ^ verify these against the fingerprints Forgejo publishes"

if [ "$DRY_RUN" = yes ]; then
	info ""
	info "dry run: nothing was created."
	[ -n "$SAVE_KNOWN_HOSTS" ] && info "         $SAVE_KNOWN_HOSTS was not written either."
	exit 0
fi

if [ "$ASSUME_YES" != yes ] && [ -t 0 ]; then
	printf 'Proceed? [y/N] ' >&2
	IFS= read -r answer || answer=""
	case $answer in
		y|Y|yes|YES) ;;
		*) die "aborted" ;;
	esac
fi

# ---------------------------------------------------------------- token setup

CURL_CFG="$WORKDIR/curl.cfg"
# Passed via --config so the token never shows up in the process list.
printf 'header = "Authorization: token %s"\n' "$FORGEJO_TOKEN" > "$CURL_CFG"

api_call() {
	# api_call METHOD PATH [DATA_FILE] -> body in $WORKDIR/response, prints status
	_method=$1
	_path=$2
	_data=${3:-}
	if [ -n "$_data" ]; then
		curl -sS --fail-with-body -o "$WORKDIR/response" -w '%{http_code}' \
			--config "$CURL_CFG" \
			-X "$_method" \
			-H 'Content-Type: application/json' \
			-H 'Accept: application/json' \
			--data-binary @"$_data" \
			"$API$_path" 2>"$WORKDIR/curl.err" || true
	else
		curl -sS -o "$WORKDIR/response" -w '%{http_code}' \
			--config "$CURL_CFG" \
			-X "$_method" \
			-H 'Accept: application/json' \
			"$API$_path" 2>"$WORKDIR/curl.err" || true
	fi
}

api_message() {
	if [ ! -s "$WORKDIR/response" ]; then
		return 0
	fi
	if command -v jq >/dev/null 2>&1; then
		jq -r '.message // empty' "$WORKDIR/response" 2>/dev/null && return 0
	fi
	sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKDIR/response" | head -1
}

# ------------------------------------------------------------- repo preflight

status=$(api_call GET "/repos/$FORGEJO_REPO")
case $status in
	200) ;;
	000) die "cannot reach $API - $(cat "$WORKDIR/curl.err")" ;;
	401) die "Forgejo rejected the token (401). Check FORGEJO_TOKEN in $ENV_FILE." ;;
	403) die "token lacks permission on $FORGEJO_REPO (403). It needs the write:repository scope." ;;
	404) die "repository not found or not visible to this token: $FORGEJO_REPO (404)" ;;
	*)   die "unexpected response $status from GET /repos/$FORGEJO_REPO: $(api_message)" ;;
esac

# ------------------------------------------------------------- key generation

KEY_PATH="$WORKDIR/identity"
if [ "$KEY_TYPE" = rsa ]; then
	ssh-keygen -q -t rsa -b 4096 -N '' -C "$KEY_TITLE" -f "$KEY_PATH" </dev/null \
		|| die "ssh-keygen failed"
else
	ssh-keygen -q -t ed25519 -N '' -C "$KEY_TITLE" -f "$KEY_PATH" </dev/null \
		|| die "ssh-keygen failed"
fi

IFS= read -r PUBKEY < "$KEY_PATH.pub" || die "cannot read the generated public key"
FINGERPRINT=$(ssh-keygen -lf "$KEY_PATH.pub" 2>/dev/null || printf 'unknown')

# ------------------------------------------------------ register the deploy key

PAYLOAD="$WORKDIR/payload.json"
printf '{"title":"%s","key":"%s","read_only":%s}\n' \
	"$(json_escape "$KEY_TITLE")" \
	"$(json_escape "$PUBKEY")" \
	"$READ_ONLY" > "$PAYLOAD"

status=$(api_call POST "/repos/$FORGEJO_REPO/keys" "$PAYLOAD")
case $status in
	201) ;;
	422)
		die "Forgejo refused the key (422): $(api_message)
     A public key can only be a deploy key on one repository at a time, and the
     title must be unique within the repository." ;;
	403) die "token lacks permission to add deploy keys to $FORGEJO_REPO (403)" ;;
	000) die "cannot reach $API - $(cat "$WORKDIR/curl.err")" ;;
	*)   die "unexpected response $status when creating the deploy key: $(api_message)" ;;
esac

if command -v jq >/dev/null 2>&1; then
	CREATED_KEY_ID=$(jq -r '.id // empty' "$WORKDIR/response" 2>/dev/null || printf '')
else
	# flatten the JSON so the first "id" seen is the deploy key's own
	CREATED_KEY_ID=$(tr ',{}' '\n\n\n' < "$WORKDIR/response" \
		| sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
		| head -1)
fi

info "deploy key created${CREATED_KEY_ID:+ (id $CREATED_KEY_ID)}: $FINGERPRINT"

rollback_deploy_key() {
	if [ -z "$CREATED_KEY_ID" ]; then
		warn "could not determine the deploy key id; remove '$KEY_TITLE' from $FORGEJO_REPO by hand"
		return 0
	fi
	_st=$(api_call DELETE "/repos/$FORGEJO_REPO/keys/$CREATED_KEY_ID")
	case $_st in
		204) info "rolled back: deploy key $CREATED_KEY_ID deleted" ;;
		*)   warn "could not delete deploy key $CREATED_KEY_ID (status $_st); remove it by hand" ;;
	esac
}

# ------------------------------------------------------------- create the secret

create_secret() {
	kc -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
		--from-file=identity="$KEY_PATH" \
		--from-file=identity.pub="$KEY_PATH.pub" \
		--from-file=known_hosts="$KNOWN_HOSTS" \
		--dry-run=client -o yaml \
	| kc apply -f -
}

if ! create_secret; then
	warn "creating the secret failed"
	rollback_deploy_key
	die "nothing was left behind in Forgejo; the cluster is unchanged"
fi

# ---------------------------------------------------------------- keep the key

if [ -n "$SAVE_KNOWN_HOSTS" ]; then
	cp "$KNOWN_HOSTS" "$SAVE_KNOWN_HOSTS"
	chmod 644 "$SAVE_KNOWN_HOSTS"
	info "scanned host keys written to $SAVE_KNOWN_HOSTS"
fi

if [ -n "$KEEP_KEY_DIR" ]; then
	cp "$KEY_PATH" "$KEEP_KEY_DIR/identity"
	cp "$KEY_PATH.pub" "$KEEP_KEY_DIR/identity.pub"
	chmod 600 "$KEEP_KEY_DIR/identity"
	chmod 644 "$KEEP_KEY_DIR/identity.pub"
	info "key pair copied to $KEEP_KEY_DIR (identity is unencrypted - handle with care)"
fi

info ""
info "done."
info "  secret:      $NAMESPACE/$SECRET_NAME"
info "  deploy key:  $KEY_TITLE ($ACCESS)"
info "  fingerprint: $FINGERPRINT"
info ""
info "Reference it from a Flux GitRepository like this:"
if [ "$SSH_PORT" = 22 ]; then
	SSH_URL_HOST=$SSH_HOST
else
	SSH_URL_HOST="$SSH_HOST:$SSH_PORT"
fi
cat >&2 <<EOF

  apiVersion: source.toolkit.fluxcd.io/v1
  kind: GitRepository
  metadata:
    name: $REPO_NAME
    namespace: $NAMESPACE
  spec:
    interval: 1m
    url: ssh://git@$SSH_URL_HOST/$FORGEJO_REPO.git
    ref:
      branch: main
    secretRef:
      name: $SECRET_NAME
EOF
