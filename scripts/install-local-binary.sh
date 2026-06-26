#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build, install, and restart the local CLIProxyAPI Homebrew service.

The build runs in the foreground. The critical install+restart step is then
started with nohup so it continues even if the caller loses its API connection
when the service restarts.

Usage:
  scripts/install-local-binary.sh [--wait] [--install-path PATH] [--service NAME]

Options:
  --wait               Poll the detached installer until it exits.
  --install-path PATH  Binary install path.
                       Default: /opt/homebrew/opt/cliproxyapi/bin/cliproxyapi
  --service NAME       Homebrew service name. Default: cliproxyapi
  -h, --help           Show this help.

Environment:
  CLIPROXYAPI_INSTALL_PATH  Overrides the default install path.
  CLIPROXYAPI_SERVICE_NAME  Overrides the default service name.
EOF
}

wait_for_installer=false
install_path="${CLIPROXYAPI_INSTALL_PATH:-/opt/homebrew/opt/cliproxyapi/bin/cliproxyapi}"
service_name="${CLIPROXYAPI_SERVICE_NAME:-cliproxyapi}"

while (($# > 0)); do
  case "$1" in
    --wait)
      wait_for_installer=true
      shift
      ;;
    --install-path)
      if (($# < 2)); then
        echo "missing value for --install-path" >&2
        exit 2
      fi
      install_path="$2"
      shift 2
      ;;
    --service)
      if (($# < 2)); then
        echo "missing value for --service" >&2
        exit 2
      fi
      service_name="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cliproxyapi-install.XXXXXX")"
built_binary="$work_dir/cliproxyapi"
installer="$work_dir/install-and-restart.sh"
log_file="${TMPDIR:-/tmp}/cliproxyapi-install-$timestamp.log"
pid_file="${TMPDIR:-/tmp}/cliproxyapi-install-$timestamp.pid"

echo "Building CLIProxyAPI from $repo_root"
(
  cd "$repo_root"
  go build -o "$built_binary" ./cmd/server
)

cat >"$installer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

install_path="$1"
service_name="$2"
built_binary="$3"
timestamp="$4"
work_dir="$5"

lock_dir="${TMPDIR:-/tmp}/cliproxyapi-install.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "another local install appears to be running: $lock_dir" >&2
  exit 1
fi
cleanup() {
  rm -rf "$lock_dir" "$work_dir"
}
trap cleanup EXIT

install_dir="$(dirname -- "$install_path")"
mkdir -p "$install_dir"

if [[ -e "$install_path" ]]; then
  backup_path="$install_path.bak-$timestamp"
  cp -p "$install_path" "$backup_path"
  echo "Backed up $install_path to $backup_path"
fi

staged_path="$install_dir/.cliproxyapi.$timestamp.$$"
install -m 0755 "$built_binary" "$staged_path"
mv -f "$staged_path" "$install_path"
echo "Installed $install_path"

brew services restart "$service_name"
echo "Restarted Homebrew service: $service_name"
EOF
chmod +x "$installer"

echo "Starting detached install+restart step"
nohup "$installer" "$install_path" "$service_name" "$built_binary" "$timestamp" "$work_dir" \
  >"$log_file" 2>&1 < /dev/null &
installer_pid=$!
echo "$installer_pid" >"$pid_file"

echo "Installer PID: $installer_pid"
echo "Installer log: $log_file"

if [[ "$wait_for_installer" != true ]]; then
  echo "Install+restart continues in the background."
  exit 0
fi

echo "Waiting for installer to finish..."
while kill -0 "$installer_pid" 2>/dev/null; do
  sleep 1
done

if [[ -f "$log_file" ]]; then
  cat "$log_file"
fi

if wait "$installer_pid" 2>/dev/null; then
  exit 0
fi

echo "Installer exited; inspect log if the service did not restart cleanly: $log_file" >&2
exit 1
