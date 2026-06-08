#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: script/release.sh --version <semver> [--skip-notarization]

Builds a signed Developer ID release, packages it as a zip, optionally notarizes
and staples it, then writes checksums under build/release.

Required environment:
  DEVELOPMENT_TEAM

Required for notarization unless --skip-notarization is passed:
  APPLE_ID
  APPLE_APP_SPECIFIC_PASSWORD

Optional environment:
  CONFIGURATION=Release
USAGE
}

version=""
skip_notarization=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --skip-notarization)
      skip_notarization=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ ! "${version}" =~ ^[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must be semver without a leading v, for example 1.2.3." >&2
  exit 64
fi

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "DEVELOPMENT_TEAM is required for Developer ID signing." >&2
  exit 65
fi

if [[ "${skip_notarization}" -eq 0 ]]; then
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD are required for notarization." >&2
    exit 65
  fi
fi

configuration="${CONFIGURATION:-Release}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${repo_root}/build/release"
archive_path="${build_root}/Tarmac.xcarchive"
export_path="${build_root}/export"
zip_path="${build_root}/Tarmac-${version}.zip"
checksum_path="${zip_path}.sha256"
export_options="${build_root}/ExportOptions.plist"

rm -rf "${build_root}"
mkdir -p "${build_root}" "${export_path}"

cd "${repo_root}"
if [[ -f Tuist.swift ]]; then
  tuist install
  tuist generate --no-open
fi

cat > "${export_options}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${DEVELOPMENT_TEAM}</string>
</dict>
</plist>
EOF

xcodebuild archive \
  -project Tarmac.xcodeproj \
  -scheme Tarmac \
  -configuration "${configuration}" \
  -archivePath "${archive_path}" \
  -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  MARKETING_VERSION="${version}" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  CODE_SIGN_STYLE=Automatic

xcodebuild -exportArchive \
  -archivePath "${archive_path}" \
  -exportPath "${export_path}" \
  -exportOptionsPlist "${export_options}" \
  -allowProvisioningUpdates

/usr/bin/ditto -c -k --keepParent "${export_path}/Tarmac.app" "${zip_path}"

if [[ "${skip_notarization}" -eq 0 ]]; then
  xcrun notarytool submit "${zip_path}" \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --team-id "${DEVELOPMENT_TEAM}" \
    --wait

  xcrun stapler staple "${export_path}/Tarmac.app"
  /usr/bin/ditto -c -k --keepParent "${export_path}/Tarmac.app" "${zip_path}"
fi

/usr/bin/shasum -a 256 "${zip_path}" | tee "${checksum_path}"
xcrun stapler validate "${export_path}/Tarmac.app" || {
  if [[ "${skip_notarization}" -eq 0 ]]; then
    exit 1
  fi
}

echo "Release artifact: ${zip_path}"
echo "Checksum: ${checksum_path}"
