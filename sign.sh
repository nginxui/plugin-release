#!/usr/bin/env bash
# Signs every plugin package in a directory in place, the way Nginx UI checks
# packages:
#
# 1. The package is unpacked. plugin.json must sit at its root, and its id and
#    version must start the archive name, <id>-<version>[-<platform>].tar.gz.
# 2. The signer certificate, plugin.signer and plugin.signer.minisig from
#    CERTIFICATE_DIR, goes to the root unless the package holds it already.
#    Without one the key signs directly, which suits the official and partner
#    keys only: the official catalog lists a community package only when a
#    certified signing key signed it.
# 3. plugin.sums lists the sha256 of every other file, sorted bytewise by
#    path, and the key signs it into plugin.sums.minisig.
# 4. The package is packed again with plugin.json as its first entry, and
#    <archive>.sha256 is written next to it.
# 5. Every archive is checked: its digest, plugin.sums against the files and
#    the signature against the certified key. When TRUSTED_KEY is given, the
#    certificate must verify against it, or without a certificate the
#    signature must.
#
# Environment:
#   PACKAGES_DIR           directory of the unsigned <id>-<version>*.tar.gz
#   SIGNING_KEY            the minisign secret key, as the file holds it
#   SIGNING_KEY_PASSWORD   its password, empty for a key made with -W
#   CERTIFICATE_DIR        directory of the signer certificate, may be empty
#   TRUSTED_KEY            the public key the catalog and Nginx UI trust for
#                          the plugin, optional: the primary key that issued
#                          the certificate, or a key that signs directly, such
#                          as the official plugin key
#   TAG                    the release tag, v<version>, optional
#
# Writes packages=<archives, one per line> and signer=<key id> to
# $GITHUB_OUTPUT when it is set.
set -euo pipefail

PACKAGES_DIR="${PACKAGES_DIR:?PACKAGES_DIR is required}"
SIGNING_KEY="${SIGNING_KEY:-}"
SIGNING_KEY_PASSWORD="${SIGNING_KEY_PASSWORD:-}"
CERTIFICATE_DIR="${CERTIFICATE_DIR:-}"
TRUSTED_KEY="${TRUSTED_KEY:-}"
TAG="${TAG:-}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

[[ -n "${SIGNING_KEY}" ]] || fail "signing-key is empty, a release must be signed"
[[ -d "${PACKAGES_DIR}" ]] || fail "${PACKAGES_DIR} is not a directory"
command -v minisign >/dev/null || fail "minisign is not installed"

# Keep macOS tar from adding AppleDouble "._*" entries.
export COPYFILE_DISABLE=1

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
key_file="${work}/signing.key"
(umask 077 && printf '%s\n' "${SIGNING_KEY}" >"${key_file}")

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | cut -d ' ' -f 1
  else
    shasum -a 256 <"$1" | cut -d ' ' -f 1
  fi
}

# The key line of a minisign public key, given with or without its comment.
key_line() {
  printf '%s\n' "$1" | grep -Ev '^untrusted comment:' | tr -d '[:space:]'
}

# The upper case hex key id of a minisign public key line.
key_id() {
  printf '%s' "$1" | base64 -d 2>/dev/null | od -An -tx1 -j2 -N8 | tr -d ' \n' \
    | sed 's/\(..\)/\1 /g' | awk '{ for (i = NF; i > 0; i--) printf "%s", $i }' | tr 'a-f' 'A-F'
}

# The trusted comment of a .minisig file.
trusted_comment() {
  sed -n 's/^trusted comment: //p' "$1"
}

minisign_sign() {
  local message="$1" comment="$2"
  if [[ -n "${SIGNING_KEY_PASSWORD}" ]]; then
    printf '%s\n' "${SIGNING_KEY_PASSWORD}" | minisign -S -s "${key_file}" -m "${message}" -t "${comment}" >/dev/null
  else
    minisign -S -s "${key_file}" -m "${message}" -t "${comment}" </dev/null >/dev/null
  fi
}

# The signer certificate of the release, both files or neither.
certificate=""
if [[ -n "${CERTIFICATE_DIR}" ]]; then
  has_key=0 has_signature=0
  [[ -f "${CERTIFICATE_DIR}/plugin.signer" ]] && has_key=1
  [[ -f "${CERTIFICATE_DIR}/plugin.signer.minisig" ]] && has_signature=1
  if [[ "${has_key}" -ne "${has_signature}" ]]; then
    fail "${CERTIFICATE_DIR} holds only one of plugin.signer and plugin.signer.minisig"
  fi
  if [[ "${has_key}" -eq 1 ]]; then
    certificate="${CERTIFICATE_DIR}"
  fi
fi
# An empty CERTIFICATE_DIR asks for direct signing, which needs no notice.
if [[ -z "${certificate}" && -n "${CERTIFICATE_DIR}" ]]; then
  echo "::notice title=No signer certificate::${CERTIFICATE_DIR} holds no signer certificate, so the packages are signed by the key directly. The official catalog lists a community package only when a signing key certified by its primary key signs it, see nginx-ui plugin key init."
fi

shopt -s nullglob
archives=("${PACKAGES_DIR}"/*.tar.gz)
[[ ${#archives[@]} -gt 0 ]] || fail "${PACKAGES_DIR} holds no .tar.gz package"

signer_id=""
signed=()
for archive in "${archives[@]}"; do
  name="$(basename "${archive}")"
  root="${work}/${name%.tar.gz}"
  mkdir -p "${root}"
  tar -xzpf "${archive}" -C "${root}"
  [[ -f "${root}/plugin.json" ]] || fail "${name}: plugin.json is not at the root of the package"

  id="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).id ?? ""' "${root}/plugin.json")"
  version="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version ?? ""' "${root}/plugin.json")"
  case "${name}" in
    "${id}-${version}.tar.gz" | "${id}-${version}-"*.tar.gz) ;;
    *) fail "${name}: the name does not start with ${id}-${version}, the id and version of its plugin.json" ;;
  esac
  if [[ -n "${TAG}" && "${TAG#v}" != "${version}" ]]; then
    fail "${name}: plugin.json says version ${version}, the tag is ${TAG}"
  fi

  # The certificate of the release, unless the package brings its own.
  pkg_cert="${certificate}"
  if [[ -f "${root}/plugin.signer" || -f "${root}/plugin.signer.minisig" ]]; then
    [[ -f "${root}/plugin.signer" && -f "${root}/plugin.signer.minisig" ]] \
      || fail "${name}: holds only one of plugin.signer and plugin.signer.minisig"
    if [[ -n "${certificate}" ]] && ! cmp -s "${root}/plugin.signer" "${certificate}/plugin.signer"; then
      fail "${name}: holds another signer certificate than ${certificate}"
    fi
    pkg_cert="${root}"
  elif [[ -n "${certificate}" ]]; then
    cp "${certificate}/plugin.signer" "${certificate}/plugin.signer.minisig" "${root}/"
  fi

  if [[ -n "${pkg_cert}" ]]; then
    comment="$(trusted_comment "${pkg_cert}/plugin.signer.minisig")"
    [[ "${comment}" == "signer:${id}" ]] \
      || fail "${name}: the signer certificate is for \"${comment#signer:}\", the package is ${id}"
    if [[ -n "${TRUSTED_KEY}" ]]; then
      minisign -V -q -m "${pkg_cert}/plugin.signer" -x "${pkg_cert}/plugin.signer.minisig" \
        -P "$(key_line "${TRUSTED_KEY}")" \
        || fail "${name}: the signer certificate does not verify against trusted-key"
    fi
  fi

  # plugin.sums over every other file, then its signature.
  rm -f "${root}/plugin.sums" "${root}/plugin.sums.minisig"
  (
    cd "${root}"
    find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s  %s\n' "$(sha256_hex "${file}")" "${file}"
    done
  ) >"${work}/plugin.sums"
  mv "${work}/plugin.sums" "${root}/plugin.sums"
  minisign_sign "${root}/plugin.sums" "${id} ${version}"

  # Signing with the primary key instead of the signing key shows here.
  if [[ -n "${pkg_cert}" ]]; then
    signer_line="$(key_line "$(cat "${pkg_cert}/plugin.signer")")"
    minisign -V -q -m "${root}/plugin.sums" -x "${root}/plugin.sums.minisig" -P "${signer_line}" \
      || fail "${name}: the key that signed is not the one the signer certificate names, sign with the signing key, not the primary key"
    signer_id="$(key_id "${signer_line}")"
  fi

  # plugin.json first, then the signature files and the rest in byte order.
  entries=(plugin.json plugin.sums plugin.sums.minisig)
  while IFS= read -r entry; do
    entries+=("${entry}")
  done < <(cd "${root}" && ls -A | LC_ALL=C sort | grep -Fxv -e plugin.json -e plugin.sums -e plugin.sums.minisig)
  rm -f "${archive}" "${archive}.sha256"
  tar -czf "${archive}" -C "${root}" "${entries[@]}"
  printf '%s  %s\n' "$(sha256_hex "${archive}")" "${name}" >"${archive}.sha256"
  signed+=("${archive}")
  echo "signed ${name}"
done

# Check every archive the way a host and the catalog do.
for archive in "${signed[@]}"; do
  name="$(basename "${archive}")"
  (cd "$(dirname "${archive}")" && sha256sum -c --quiet "${name}.sha256" 2>/dev/null || shasum -a 256 -c --quiet "${name}.sha256") \
    || fail "${name}: does not match its .sha256"
  check="${work}/check"
  rm -rf "${check}" && mkdir -p "${check}"
  tar -xzpf "${archive}" -C "${check}"
  [[ "$(tar -tzf "${archive}" | head -n 1)" == plugin.json ]] || fail "${name}: plugin.json is not the first entry"
  (cd "${check}" && sha256sum -c --quiet plugin.sums 2>/dev/null || shasum -a 256 -c --quiet plugin.sums) \
    || fail "${name}: plugin.sums does not match the files"
  if [[ -f "${check}/plugin.signer" ]]; then
    minisign -V -q -m "${check}/plugin.sums" -x "${check}/plugin.sums.minisig" -P "$(key_line "$(cat "${check}/plugin.signer")")" \
      || fail "${name}: plugin.sums.minisig does not verify against the certified signing key"
  elif [[ -n "${TRUSTED_KEY}" ]]; then
    minisign -V -q -m "${check}/plugin.sums" -x "${check}/plugin.sums.minisig" -P "$(key_line "${TRUSTED_KEY}")" \
      || fail "${name}: plugin.sums.minisig does not verify against trusted-key"
  fi
done

echo "signed ${#signed[@]} package(s)${signer_id:+ with signing key ${signer_id}}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "packages<<PACKAGES_EOF"
    printf '%s\n' "${signed[@]}"
    echo "PACKAGES_EOF"
    echo "signer=${signer_id}"
  } >>"${GITHUB_OUTPUT}"
fi
