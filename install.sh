#!/usr/bin/env bash

set -euo pipefail

RELEASE_REPO="${INSPECTOR_RELEASE_REPO:-inspectorai/inspector-releases}"
INSTALL_ROOT="${INSPECTOR_INSTALL_ROOT:-${HOME}/.local/share/inspector}"
BIN_DIR="${INSPECTOR_BIN_DIR:-${HOME}/.local/bin}"
CONFIG_HOME="${INSPECTOR_CONFIG_HOME:-${HOME}/.inspector}"
FORCE_CONFIG="${INSPECTOR_INSTALL_FORCE_CONFIG:-1}"
temp_dir=""

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

normalize_repo() {
  local value="${1:-}"
  value="${value#https://github.com/}"
  value="${value#http://github.com/}"
  value="${value#github.com/}"
  value="${value%/}"
  printf '%s' "${value}"
}

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}:${arch}" in
    Linux:x86_64)
      printf 'x86_64-unknown-linux-gnu'
      ;;
    Darwin:arm64)
      printf 'aarch64-apple-darwin'
      ;;
    Darwin:x86_64)
      printf 'x86_64-apple-darwin'
      ;;
    *)
      echo "Inspector installer does not support ${os}/${arch}." >&2
      exit 1
      ;;
  esac
}

need_sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    return
  fi
  echo "Missing required command: sha256sum or shasum" >&2
  exit 1
}

extract_json_string() {
  local key="${1:?missing key}"
  local value
  value="$(
    sed -nE "s/^[[:space:]]*\"${key}\":[[:space:]]*\"([^\"]+)\".*/\1/p" \
      | head -n1
  )"
  if [[ -z "${value}" ]]; then
    echo "Failed to parse '${key}' from release manifest" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

checksum_for_asset() {
  local asset_name="${1:?missing asset name}"
  awk -v asset_name="${asset_name}" '
    $2 == asset_name || $2 == "*" asset_name { print $1; exit }
  '
}

manifest_sha256_for_asset() {
  local asset_name="${1:?missing asset name}"
  awk -v asset_name="${asset_name}" '
    index($0, "\"name\": \"" asset_name "\"") { in_asset=1; next }
    in_asset && /"name":/ { in_asset=0 }
    in_asset && /"sha256":/ {
      line=$0
      sub(/^.*"sha256"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  '
}

compute_sha256() {
  local asset_path="${1:?missing asset path}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${asset_path}" | awk '{print $1}'
    return
  fi
  shasum -a 256 "${asset_path}" | awk '{print $1}'
}

verify_checksum() {
  local asset_path="${1:?missing asset path}"
  local expected="${2:?missing checksum}"
  local actual
  actual="$(compute_sha256 "${asset_path}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Checksum mismatch for ${asset_path}" >&2
    echo "Expected: ${expected}" >&2
    echo "Actual:   ${actual}" >&2
    exit 1
  fi
}

path_contains_bin_dir() {
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

shell_quote() {
  local value="${1:?missing value}"
  printf "'%s'" "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")"
}

path_profile_snippet() {
  local quoted_bin_dir
  quoted_bin_dir="$(shell_quote "${BIN_DIR}")"
  cat <<EOF
# >>> inspector installer PATH >>>
inspector_bin_dir=${quoted_bin_dir}
case ":\${PATH}:" in
  *":\${inspector_bin_dir}:"*) ;;
  *) export PATH="\${inspector_bin_dir}:\${PATH}" ;;
esac
# <<< inspector installer PATH <<<
EOF
}

fish_path_profile_snippet() {
  local quoted_bin_dir
  quoted_bin_dir="$(shell_quote "${BIN_DIR}")"
  cat <<EOF
# >>> inspector installer PATH >>>
set -l inspector_bin_dir ${quoted_bin_dir}
if not contains -- \$inspector_bin_dir \$PATH
    set -gx PATH \$inspector_bin_dir \$PATH
end
# <<< inspector installer PATH <<<
EOF
}

append_profile_snippet() {
  local profile_path="${1:?missing profile path}"
  local snippet="${2:?missing snippet}"
  local profile_dir

  if [[ -f "${profile_path}" ]] && grep -Fq "# >>> inspector installer PATH >>>" "${profile_path}"; then
    return 1
  fi

  profile_dir="$(dirname "${profile_path}")"
  mkdir -p "${profile_dir}"
  touch "${profile_path}"
  {
    echo
    printf '%s\n' "${snippet}"
  } >>"${profile_path}"
  return 0
}

profile_candidates() {
  local shell_name os_name
  shell_name="$(basename "${SHELL:-}")"
  os_name="$(uname -s)"

  case "${shell_name}" in
    zsh)
      printf '%s\n' "${HOME}/.zprofile" "${HOME}/.zshrc"
      ;;
    bash)
      if [[ "${os_name}" == "Darwin" ]]; then
        printf '%s\n' "${HOME}/.bash_profile"
      fi
      printf '%s\n' "${HOME}/.bashrc" "${HOME}/.profile"
      ;;
    fish)
      printf '%s\n' "${HOME}/.config/fish/config.fish"
      ;;
    *)
      printf '%s\n' "${HOME}/.profile"
      ;;
  esac
}

link_into_existing_path_dir() {
  local inspector_target="${1:?missing inspector target}"
  local path_dir candidate

  IFS=":" read -r -a path_dirs <<<"${PATH:-}"
  for path_dir in "${path_dirs[@]}"; do
    if [[ -z "${path_dir}" || ! -d "${path_dir}" || ! -w "${path_dir}" ]]; then
      continue
    fi
    if [[ "${path_dir}" != "${HOME}/"* && "${path_dir}" != "/usr/local/bin" && "${path_dir}" != "/opt/homebrew/bin" ]]; then
      continue
    fi
    if [[ "${path_dir}" == "${BIN_DIR}" ]]; then
      continue
    fi

    candidate="${path_dir}/inspector"
    if [[ -e "${candidate}" && ! -L "${candidate}" ]]; then
      continue
    fi

    if ln -sfn "${inspector_target}" "${candidate}" 2>/dev/null; then
      echo "Linked Inspector into PATH: ${candidate}"
      return 0
    fi
  done

  return 1
}

ensure_user_path() {
  local inspector_target="${1:?missing inspector target}"
  local profile_path snippet updated_profiles=()

  if path_contains_bin_dir; then
    return
  fi

  if link_into_existing_path_dir "${inspector_target}"; then
    return
  fi

  while IFS= read -r profile_path; do
    if [[ -z "${profile_path}" ]]; then
      continue
    fi
    if [[ "${profile_path}" == */config.fish ]]; then
      snippet="$(fish_path_profile_snippet)"
    else
      snippet="$(path_profile_snippet)"
    fi
    if append_profile_snippet "${profile_path}" "${snippet}"; then
      updated_profiles+=("${profile_path}")
    fi
  done < <(profile_candidates)

  if ((${#updated_profiles[@]} > 0)); then
    echo "Added Inspector to PATH for new shells:"
    for profile_path in "${updated_profiles[@]}"; do
      echo "  ${profile_path}"
    done
  else
    echo "Inspector PATH profile entry already exists."
  fi
}

cleanup() {
  if [[ -n "${temp_dir}" && -d "${temp_dir}" ]]; then
    rm -rf "${temp_dir}"
  fi
}

main() {
  local repo target manifest_url manifest version tag asset_name download_url
  local checksums_url expected_sha archive_path extract_root bundle_root
  local releases_dir release_dir current_link config_dir installed_config bundle_config

  need_cmd curl
  need_cmd tar
  need_sha256_cmd
  need_cmd mktemp

  repo="$(normalize_repo "${RELEASE_REPO}")"
  target="$(detect_target)"
  manifest_url="https://github.com/${repo}/releases/latest/download/release-manifest.json"

  echo "Fetching latest Inspector release metadata..."
  manifest="$(curl -fsSL "${manifest_url}")"
  version="$(printf '%s\n' "${manifest}" | extract_json_string version)"
  tag="$(printf '%s\n' "${manifest}" | extract_json_string tag)"

  asset_name="inspector-bundle-${version}-${target}.tar.gz"
  download_url="https://github.com/${repo}/releases/download/${tag}/${asset_name}"
  checksums_url="https://github.com/${repo}/releases/download/${tag}/SHA256SUMS.txt"

  echo "Resolving checksum for ${asset_name}..."
  expected_sha="$(
    printf '%s\n' "${manifest}" | manifest_sha256_for_asset "${asset_name}"
  )"
  if [[ -z "${expected_sha}" ]]; then
    expected_sha="$(
      curl -fsSL "${checksums_url}" | checksum_for_asset "${asset_name}"
    )"
  fi
  if [[ -z "${expected_sha}" ]]; then
    echo "Failed to find ${asset_name} in ${checksums_url}" >&2
    exit 1
  fi

  temp_dir="$(mktemp -d)"
  archive_path="${temp_dir}/${asset_name}"
  extract_root="${temp_dir}/extract"

  echo "Downloading ${asset_name}..."
  curl -fL "${download_url}" -o "${archive_path}"
  verify_checksum "${archive_path}" "${expected_sha}"

  mkdir -p "${extract_root}" "${BIN_DIR}"
  tar -xzf "${archive_path}" -C "${extract_root}"

  bundle_root="${extract_root}/inspector-bundle-${version}-${target}"
  if [[ ! -f "${bundle_root}/bundle.json" ]]; then
    echo "Downloaded archive does not contain a valid Inspector bundle" >&2
    exit 1
  fi

  releases_dir="${INSTALL_ROOT}/releases"
  release_dir="${releases_dir}/${version}"
  current_link="${INSTALL_ROOT}/current"
  config_dir="${CONFIG_HOME}"
  installed_config="${config_dir}/config.toml"
  bundle_config="${release_dir}/config/config.toml"

  mkdir -p "${releases_dir}" "${config_dir}"
  rm -rf "${release_dir}"
  mv "${bundle_root}" "${release_dir}"

  ln -sfn "${release_dir}" "${current_link}"
  ln -sfn "${current_link}/bin/inspector" "${BIN_DIR}/inspector"
  ensure_user_path "${current_link}/bin/inspector"

  if [[ -f "${bundle_config}" ]]; then
    if [[ ! -f "${installed_config}" || "${FORCE_CONFIG}" == "1" ]]; then
      cp "${bundle_config}" "${installed_config}"
      echo "Installed Inspector config: ${installed_config}"
    else
      echo "Keeping existing Inspector config: ${installed_config}"
      echo "Set INSPECTOR_INSTALL_FORCE_CONFIG=1 to replace it."
    fi
  fi

  echo
  echo "Inspector ${version} installed successfully."
  echo "Binary: ${BIN_DIR}/inspector"
  echo "Bundle: ${release_dir}"
}

trap cleanup EXIT
main "$@"
