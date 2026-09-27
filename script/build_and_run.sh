#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Tarmac"
BUNDLE_ID="studio.seventwo.tarmac"
SCHEME="Tarmac"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
DERIVED_DATA_PATH="$PWD/.build/xcode-derived-data"
BUILT_APP_PATH_FILE="$DERIVED_DATA_PATH/tarmac-built-app-path"
WORKSPACE="Tarmac.xcworkspace"
PROJECT="Tarmac.xcodeproj"
CODE_SIGN_STYLE="${TARMAC_CODE_SIGN_STYLE:-Manual}"
CODE_SIGN_IDENTITY="${TARMAC_CODE_SIGN_IDENTITY:-Apple Development: Luca Silverentand (R377UCHFT2)}"
DEVELOPMENT_TEAM="${TARMAC_DEVELOPMENT_TEAM:-96452FLT2P}"
CODE_SIGN_INJECT_BASE_ENTITLEMENTS="${TARMAC_CODE_SIGN_INJECT_BASE_ENTITLEMENTS:-NO}"

usage() {
  echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
}

project_needs_generation() {
  if [[ ! -d "$WORKSPACE" && ! -d "$PROJECT" ]]; then
    return 0
  fi

  if [[ "${TARMAC_REGENERATE_PROJECT:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -d "$PROJECT" && ( Project.swift -nt "$PROJECT" || Tuist.swift -nt "$PROJECT" ) ]]; then
    return 0
  fi

  if [[ -d "$WORKSPACE" && ( Project.swift -nt "$WORKSPACE" || Tuist.swift -nt "$WORKSPACE" ) ]]; then
    return 0
  fi

  return 1
}

build_project() {
  if project_needs_generation; then
    tuist generate --no-open
  fi

  local build_args=()
  if [[ -d "$WORKSPACE" ]]; then
    build_args=(-workspace "$WORKSPACE")
  elif [[ -d "$PROJECT" ]]; then
    build_args=(-project "$PROJECT")
  else
    echo "error: expected $WORKSPACE or $PROJECT after tuist generate" >&2
    exit 1
  fi

  local signing_args=(
    CODE_SIGN_STYLE="$CODE_SIGN_STYLE"
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS="$CODE_SIGN_INJECT_BASE_ENTITLEMENTS"
  )

  xcodebuild \
    "${build_args[@]}" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    "${signing_args[@]}" \
    build

  local products_dir
  products_dir="$(
    xcodebuild \
      "${build_args[@]}" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -destination "$DESTINATION" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      "${signing_args[@]}" \
      -showBuildSettings |
      awk -F'= ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / { print $2; exit }'
  )"

  mkdir -p "$DERIVED_DATA_PATH"
  printf '%s\n' "$products_dir/$APP_NAME.app" >"$BUILT_APP_PATH_FILE"
}

app_bundle_path() {
  if [[ -f "$BUILT_APP_PATH_FILE" ]]; then
    sed -n '1p' "$BUILT_APP_PATH_FILE"
  else
    echo "$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
  fi
}

open_app() {
  local app_bundle
  app_bundle="$(app_bundle_path)"

  if [[ ! -d "$app_bundle" ]]; then
    echo "error: built app was not found at $app_bundle" >&2
    exit 1
  fi

  local open_args=(-n)
  if [[ -n "${TARMAC_JOBS_DIRECTORY:-}" ]]; then
    open_args+=(--env "TARMAC_JOBS_DIRECTORY=$TARMAC_JOBS_DIRECTORY")
  fi

  /usr/bin/open "${open_args[@]}" "$app_bundle"
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
build_project

case "$MODE" in
  build|--build)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$(app_bundle_path)/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    usage
    exit 2
    ;;
esac
