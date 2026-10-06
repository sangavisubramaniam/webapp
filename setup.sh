#!/usr/bin/env bash
#
# setup.sh - prerequisites + one-shot bootstrap for Jenkins, Nexus and SonarQube
#            (images are pushed to a public Docker Hub repository)
#
# Usage:
#   ./setup.sh           install prerequisites, start the stack, configure everything
#   ./setup.sh --reset   DELETE all containers, volumes and .env
#
# Safe to re-run: generated passwords live in .env and finished steps are skipped.
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

RESET=false
for arg in "$@"; do
  case "$arg" in
    --ecr)     echo "--ecr is no longer needed (Docker Hub is used now)" ;;
    --reset)   RESET=true ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *)         echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# ------------------------------------------------------------------ helpers
log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'warn "setup.sh failed at line $LINENO"' ERR

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

ENV_FILE=".env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"

getv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
setv() {
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  grep -vE "^${k}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}
ensure() { [ -n "$(getv "$1")" ] || setv "$1" "$2"; }
pw()     { printf 'Aa1-%s' "$(openssl rand -hex 10)"; }

pkg_install() {
  if   command -v apt-get >/dev/null; then $SUDO apt-get update -y && $SUDO apt-get install -y "$@"
  elif command -v dnf     >/dev/null; then $SUDO dnf install -y "$@"
  elif command -v yum     >/dev/null; then $SUDO yum install -y "$@"
  else die "Please install manually: $*"; fi
}

wait_http() {   # name url [tries]
  local name="$1" url="$2" tries="${3:-90}" i
  log "Waiting for $name ($url) ..."
  for ((i = 1; i <= tries; i++)); do
    curl -fsS -o /dev/null "$url" 2>/dev/null && return 0
    sleep 5
  done
  die "$name did not become ready. Check: docker compose logs"
}
wait_sonar() {
  local i
  log "Waiting for SonarQube ..."
  for ((i = 1; i <= 120; i++)); do
    curl -fsS http://localhost:9000/api/system/status 2>/dev/null | grep -q '"status":"UP"' && return 0
    sleep 5
  done
  die "SonarQube did not become ready. Check: docker compose logs sonarqube"
}

# ------------------------------------------------- 1. system prerequisites
log "Step 1/5 - checking prerequisites"
OS="$(uname -s)"

for tool in curl openssl; do
  command -v "$tool" >/dev/null || pkg_install "$tool"
done

if ! command -v docker >/dev/null; then
  [ "$OS" = "Linux" ] || die "Docker not found. Install Docker Desktop: https://docs.docker.com/get-docker/"
  log "Installing Docker Engine (get.docker.com) ..."
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO systemctl enable --now docker 2>/dev/null || true
fi

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if $SUDO docker info >/dev/null 2>&1; then
    warn "Your user can't talk to Docker yet - using sudo for this run."
    warn "Adding '$USER' to the docker group (log out/in afterwards)."
    $SUDO usermod -aG docker "$USER" 2>/dev/null || true
    DOCKER=($SUDO docker)
  else
    die "Docker daemon is not running/reachable. Start Docker and re-run."
  fi
fi
dc() { "${DOCKER[@]}" compose "$@"; }

need="2.23.1"
have="$(dc version --short 2>/dev/null | sed 's/^v//' || true)"
[ -n "$have" ] && [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -n1)" = "$need" ] \
  || die "Docker Compose >= $need required (found: ${have:-none}). Update Docker / docker-compose-plugin."

if $RESET; then
  read -r -p "This deletes ALL containers, volumes and .env. Type 'yes' to continue: " ans
  [ "$ans" = "yes" ] || die "Aborted."
  dc down -v --remove-orphans || true
  rm -f "$ENV_FILE"
  log "Everything removed."
  exit 0
fi

if [ "$OS" = "Linux" ]; then
  cur="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if [ "$cur" -lt 262144 ]; then
    log "Setting vm.max_map_count=262144 (required by SonarQube/Elasticsearch)"
    $SUDO sysctl -w vm.max_map_count=262144 >/dev/null
    echo 'vm.max_map_count=262144' | $SUDO tee /etc/sysctl.d/99-sonarqube.conf >/dev/null
  fi
  mem_gb="$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)"
  [ "$mem_gb" -ge 6 ] || warn "Only ~${mem_gb} GB RAM detected; the stack wants 6+ GB. Expect slowness."
else
  warn "Not Linux: give Docker Desktop at least 6 GB RAM (Settings > Resources)."
fi

if [ -z "$(dc ps -q 2>/dev/null)" ]; then
  for p in 8080 8081 9000; do
    if (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; then
      die "Port $p is already in use (old Jenkins container? run: docker stop <name>)."
    fi
  done
fi

# --------------------------------------------------------- 2. .env secrets
log "Step 2/5 - generating secrets in $ENV_FILE"
ensure JENKINS_ADMIN_ID        admin
ensure JENKINS_ADMIN_PASSWORD  "$(pw)"
ensure NEXUS_ADMIN_PASSWORD    "$(pw)"
ensure NEXUS_CI_USER           jenkins-ci
ensure NEXUS_CI_PASSWORD       "$(pw)"
ensure SONAR_ADMIN_PASSWORD    "$(pw)"
ensure SONAR_DB_PASSWORD       "$(openssl rand -hex 12)"
ensure SONAR_TOKEN             not-set
ensure GIT_USER                not-set
ensure GIT_TOKEN               not-set
ensure DOCKERHUB_USER          not-set
ensure DOCKERHUB_TOKEN         not-set

# allow:  GIT_USER=me GIT_TOKEN=ghp_xxx DOCKERHUB_USER=me DOCKERHUB_TOKEN=dckr_pat_xxx ./setup.sh
for v in GIT_USER GIT_TOKEN DOCKERHUB_USER DOCKERHUB_TOKEN; do
  [ -z "${!v:-}" ] || setv "$v" "${!v}"
done
if [ -t 0 ] && [ "$(getv GIT_TOKEN)" = "not-set" ]; then
  read -r -p "GitHub username (Enter to skip, add later in Jenkins): " gu || true
  if [ -n "${gu:-}" ]; then
    read -r -s -p "GitHub personal access token: " gt || true; echo
    [ -z "${gt:-}" ] || { setv GIT_USER "$gu"; setv GIT_TOKEN "$gt"; }
  fi
fi

if [ -t 0 ] && [ "$(getv DOCKERHUB_TOKEN)" = "not-set" ]; then
  read -r -p "Docker Hub username (Enter to skip, add later in Jenkins): " du || true
  if [ -n "${du:-}" ]; then
    read -r -s -p "Docker Hub access token (hub.docker.com > Account settings > Personal access tokens, Read & Write): " dt || true; echo
    [ -z "${dt:-}" ] || { setv DOCKERHUB_USER "$du"; setv DOCKERHUB_TOKEN "$dt"; }
  fi
fi

# ------------------------------------------- 3. start SonarQube and Nexus
log "Step 3/5 - starting SonarQube + Nexus"
dc pull sonar-db sonarqube nexus
dc up -d sonar-db sonarqube nexus
wait_sonar
wait_http Nexus http://localhost:8081/service/rest/v1/status 120

# ------------------------------------------------------ 4. configure them
log "Step 4/5 - configuring SonarQube and Nexus"

configure_sonar() {
  if [ "$(getv SONAR_CONFIGURED)" = "1" ]; then log "SonarQube already configured"; return 0; fi
  local base="http://localhost:9000" pass tok
  pass="$(getv SONAR_ADMIN_PASSWORD)"
  if curl -fsS -o /dev/null -u admin:admin -X POST "$base/api/users/change_password" \
       --data-urlencode "login=admin" --data-urlencode "previousPassword=admin" \
       --data-urlencode "password=$pass"; then
    log "SonarQube admin password changed"
  else
    warn "Could not change default admin/admin password (already changed?). Reusing .env value."
  fi
  tok="$(curl -fsS -u "admin:$pass" -X POST "$base/api/user_tokens/generate" \
          --data-urlencode "name=jenkins-$(date +%s)" 2>/dev/null \
          | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)"
  if [ -n "$tok" ]; then
    setv SONAR_TOKEN "$tok"; setv SONAR_CONFIGURED 1
    log "SonarQube token created for Jenkins"
  else
    warn "Could not create a SonarQube token. Create one in the UI (My Account > Security) and set SONAR_TOKEN in .env."
  fi
}

configure_nexus() {
  if [ "$(getv NEXUS_CONFIGURED)" = "1" ]; then log "Nexus already configured"; return 0; fi
  local base="http://localhost:8081" init adminpw cipw ciuser ok=true
  adminpw="$(getv NEXUS_ADMIN_PASSWORD)"; cipw="$(getv NEXUS_CI_PASSWORD)"; ciuser="$(getv NEXUS_CI_USER)"
  init="$(dc exec -T nexus cat /nexus-data/admin.password 2>/dev/null | tr -d '\r\n' || true)"
  if [ -z "$init" ]; then
    warn "Nexus initial admin.password not found (already configured manually?). Skipping Nexus automation."
    return 0
  fi
  napi() { local pass="$1"; shift; curl -fsS -o /dev/null -u "admin:$pass" "$@"; }

  napi "$init" -X PUT -H 'Content-Type: text/plain' --data "$adminpw" \
       "$base/service/rest/v1/security/users/admin/change-password" || ok=false

  napi "$adminpw" -X POST -H 'Content-Type: application/json' \
       "$base/service/rest/v1/repositories/raw/hosted" \
       -d '{"name":"helm-raw","online":true,
            "storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"allow"},
            "raw":{"contentDisposition":"ATTACHMENT"}}' || { warn "helm-raw repo not created (exists already?)"; }

  napi "$adminpw" -X POST -H 'Content-Type: application/json' \
       "$base/service/rest/v1/security/roles" \
       -d '{"id":"helm-uploader","name":"helm-uploader","description":"Upload Helm archives",
            "privileges":["nx-repository-view-raw-helm-raw-*"],"roles":[]}' || { warn "role not created (exists already?)"; }

  napi "$adminpw" -X POST -H 'Content-Type: application/json' \
       "$base/service/rest/v1/security/users" \
       -d "{\"userId\":\"$ciuser\",\"firstName\":\"Jenkins\",\"lastName\":\"CI\",
            \"emailAddress\":\"jenkins@example.local\",\"password\":\"$cipw\",
            \"status\":\"active\",\"roles\":[\"helm-uploader\"]}" || { warn "CI user not created (exists already?)"; }

  napi "$adminpw" -X PUT -H 'Content-Type: application/json' \
       "$base/service/rest/v1/security/anonymous" \
       -d '{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' || warn "could not disable anonymous access"

  if $ok; then setv NEXUS_CONFIGURED 1; log "Nexus configured: repo helm-raw, user $ciuser"
  else warn "Nexus password change failed - finish setup in the UI (see summary)."; fi
}

configure_sonar
configure_nexus

# --------------------------------------------------------- 5. Jenkins
log "Step 5/5 - building and starting Jenkins (first build takes a few minutes)"
dc up -d --build jenkins
wait_http Jenkins http://localhost:8080/login 120

# ------------------------------------------------------------- summary
cat <<EOF

==================================================================
 Stack is up. Credentials are stored in $(pwd)/.env  (keep it private!)

 Jenkins    http://localhost:8080   $(getv JENKINS_ADMIN_ID) / $(getv JENKINS_ADMIN_PASSWORD)
 Nexus      http://localhost:8081   admin / $(getv NEXUS_ADMIN_PASSWORD)
 SonarQube  http://localhost:9000   admin / $(getv SONAR_ADMIN_PASSWORD)

 Jenkins credential IDs created for you:
   Git_Sang_Cred  DockerHub_Creds  Nexus_Creds  sonar-token
 SonarQube server "SonarQube" and the node label "jenkins-agent" are preconfigured.

 Next:
   1. In the Jenkinsfile set  DOCKERHUB_NAMESPACE = '<your Docker Hub username>'
      and  NEXUS_URL = 'http://nexus:8081'
   2. Jenkins > New Item > Pipeline > "Pipeline script from SCM" > your repo.
   3. If Git_Sang_Cred / DockerHub_Creds show "not-set", edit .env and run:
        docker compose up -d jenkins
      (or edit them in Manage Jenkins > Credentials).
==================================================================
EOF
