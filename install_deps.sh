#!/usr/bin/env bash
# 폐쇄망 RHEL 9.x 에서 Admin Console 런타임 · 의존성 오프라인 설치 — 이 디렉터리(의존성 패키지) 안에서 실행.
#
#   sudo ./install_deps.sh runtime                 # Node.js · pnpm → /opt/admin-console-runtime
#   ./install_deps.sh backend  <프로젝트 경로>      # 시스템 python3(3.9)로 backend/.venv 생성 + wheelhouse 설치
#   ./install_deps.sh frontend <프로젝트 경로>      # frontend/node_modules 오프라인 설치 (pnpm store)
#   ./install_deps.sh all      <프로젝트 경로>      # 위 3개 (runtime 은 root 필요)
#
# RUNTIME_PREFIX 로 설치 위치 변경 가능. 네트워크 접근 없음 — 모든 설치가 --offline / --no-index.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_PREFIX="${RUNTIME_PREFIX:-/opt/admin-console-runtime}"
# shellcheck disable=SC1091
source "$SRC/versions.env"
# 메타데이터 cache 는 registry URL 별로 저장된다 → 패키지 생성 때와 같은 registry 로 찾는다 (--offline 이라 접속 없음).
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"

NODE_BIN="$RUNTIME_PREFIX/node/bin"
# backend 는 RHEL 9 기본 python3(3.9) — PYTHON 으로 다른 인터프리터 지정 가능.
PYTHON="${PYTHON:-python3}"
# npm · pnpm 은 `#!/usr/bin/env node` — 시스템에 node 가 없는 서버에서도 동작하도록 번들 런타임을 PATH 앞에.
export PATH="$NODE_BIN:$PATH"

die() { echo "ERROR: $*" >&2; exit 1; }
# 최소 설치 RHEL 에는 diff/cmp(diffutils)가 없을 수 있다 → coreutils 의 sha256sum 으로 비교.
same_file() { [[ "$(sha256sum <"$1")" == "$(sha256sum <"$2")" ]]; }

verify() {
  echo "=== 무결성 확인 (SHA256SUMS) ==="
  local bad
  bad="$(cd "$SRC" && sha256sum --quiet -c SHA256SUMS 2>/dev/null | sed -n 's/: FAILED.*$//p')" || true
  [[ -z "$bad" ]] && return 0
  local f lfs=0
  while IFS= read -r f; do
    echo "  손상: $f" >&2
    head -c 64 "$SRC/$f" 2>/dev/null | grep -q '^version https://git-lfs' && lfs=1
  done <<<"$bad"
  # GitHub 의 ZIP 다운로드 · git-lfs 없는 clone 은 LFS 파일 대신 130 바이트짜리 포인터를 받는다.
  [[ $lfs -eq 1 ]] && die "Git LFS 포인터 파일입니다 — 원본 파일이 아닙니다. 패키지를 tar 등으로 그대로 반입하세요."
  die "체크섬 불일치 — 복사 중 손상되었을 수 있습니다."
}

# 패키지 생성 시점과 다른 의존성 목록은 store · wheelhouse 에 없는 패키지가 있어 설치가 중간에 실패한다 → 미리 중단.
check_same() {
  same_file "$1" "$2" && return 0
  local msg="$2 이 패키지 생성 시점(소스 ${SOURCE_REV:-알 수 없음})과 다릅니다 — 배포할 소스로 패키지를 다시 생성하세요."
  [[ "${ALLOW_LOCK_MISMATCH:-0}" == 1 ]] || die "$msg (무시하고 진행: ALLOW_LOCK_MISMATCH=1)"
  echo "경고: $msg"
}

install_runtime() {
  [[ $EUID -eq 0 || -w "$(dirname "$RUNTIME_PREFIX")" ]] || die "runtime 설치는 root 로 실행하세요 (또는 RUNTIME_PREFIX 지정)."
  [[ "$(uname -m)" == x86_64 ]] || die "x86_64 전용 패키지입니다 (현재 $(uname -m))."
  verify
  mkdir -p "$RUNTIME_PREFIX"

  echo "=== Node.js ${NODE_VERSION} → $RUNTIME_PREFIX/node ==="
  rm -rf "$RUNTIME_PREFIX/node" && mkdir -p "$RUNTIME_PREFIX/node"
  tar -xzf "$SRC/runtime/$NODE_TARBALL" -C "$RUNTIME_PREFIX/node" --strip-components=1

  echo "=== pnpm ${PNPM_VERSION} ==="
  # 단독 실행 바이너리 (@pnpm/exe.linux-x64) — npm 설치 과정 없이 node/bin 에 배치.
  tar -xzf "$SRC/runtime/$PNPM_TARBALL" -C "$RUNTIME_PREFIX" package/pnpm
  install -m 755 "$RUNTIME_PREFIX/package/pnpm" "$NODE_BIN/pnpm" && rm -rf "$RUNTIME_PREFIX/package"

  if [[ $EUID -eq 0 ]]; then
    for b in node npm npx pnpm; do ln -sf "$NODE_BIN/$b" "/usr/local/bin/$b"; done
  fi
  echo "node $("$NODE_BIN/node" --version) · pnpm $("$NODE_BIN/pnpm" --version)"
}

install_backend() {
  local proj="$1"
  [[ -f "$proj/backend/requirements.txt" ]] || die "$proj/backend/requirements.txt 가 없습니다."
  command -v "$PYTHON" >/dev/null || die "$PYTHON 이 없습니다 (RHEL: dnf install python3)."
  "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Python 3.9 이상이 필요합니다 ($("$PYTHON" --version))."
  verify
  check_same "$SRC/backend/requirements.txt" "$proj/backend/requirements.txt"
  echo "=== backend venv → $proj/backend/.venv ==="
  if [[ ! -x "$proj/backend/.venv/bin/python" ]]; then
    # 최소 설치 RHEL 은 ensurepip 용 wheel(python3-pip-wheel)이 없을 수 있다 → pip 없이 만들고 wheelhouse 의 pip 로 부트스트랩.
    if ! "$PYTHON" -m venv "$proj/backend/.venv" 2>/dev/null; then
      rm -rf "$proj/backend/.venv"
      "$PYTHON" -m venv --without-pip "$proj/backend/.venv"
      local pipwhl; pipwhl="$(ls "$SRC"/backend/wheelhouse/pip-*.whl | head -1)"
      "$proj/backend/.venv/bin/python" "$pipwhl/pip" install -q --no-index "$pipwhl"
    fi
  fi
  "$proj/backend/.venv/bin/pip" install -q --no-index --find-links "$SRC/backend/wheelhouse" --upgrade pip
  "$proj/backend/.venv/bin/pip" install -q --no-index --find-links "$SRC/backend/wheelhouse" \
    -r "$proj/backend/requirements.txt"
  "$proj/backend/.venv/bin/python" -c "import fastapi, sqlalchemy, asyncpg, oracledb, cryptography; print('backend 패키지 OK')"
}

# lockfile 의 linux-x64-gnu 네이티브 패키지(@next/swc · lightningcss · tailwind oxide …)가 실제로 설치됐는지.
# 모두 optional 의존성이라 store 에서 손상 · 누락돼도 pnpm 은 오류 없이 건너뛰고, 그러면 `pnpm build` 가
# "Failed to load SWC binary" 로 실패한다.
check_native() {
  local fe="$1" missing=() spec name
  while IFS= read -r spec; do
    name="${spec%@*}"
    [[ -d "$fe/node_modules/.pnpm/${spec//\//+}/node_modules/$name" ]] || missing+=("$spec")
  done < <(sed -n "/^packages:/,/^snapshots:/s/^  '\{0,1\}\(@\{0,1\}[^@' ]*-linux-x64-gnu@[^':]*\)'\{0,1\}:\$/\1/p" "$fe/pnpm-lock.yaml")
  [[ ${#missing[@]} -eq 0 ]] || die "네이티브 패키지가 설치되지 않았습니다: ${missing[*]} — store 의 파일이 손상되었을 수 있습니다."
  ( cd "$fe" && node -e '
      const r = require("module").createRequire(require.resolve("next/package.json"));
      r("@next/swc-linux-x64-gnu");' ) || die "@next/swc-linux-x64-gnu 를 불러오지 못했습니다."
  echo "네이티브 패키지 OK (SWC linux-x64-gnu 포함)"
}

install_frontend() {
  local proj="$1"
  [[ -f "$proj/frontend/pnpm-lock.yaml" ]] || die "$proj/frontend/pnpm-lock.yaml 이 없습니다."
  command -v pnpm >/dev/null || die "pnpm 이 없습니다 — 먼저 'install_deps.sh runtime'."
  [[ "$(pnpm --version)" == "$PNPM_VERSION" ]] \
    || echo "경고: pnpm $(pnpm --version) — 패키지는 pnpm $PNPM_VERSION 의 store 형식입니다."
  verify
  check_same "$SRC/frontend/pnpm-lock.yaml" "$proj/frontend/pnpm-lock.yaml"

  # store · 메타데이터 cache 는 tar.gz 조각으로 실려 있다 → 사용자 쓰기 가능한 위치에 한 번 풀어 계속 쓴다
  # (pnpm 은 쓰기 불가한 store 를 cache miss 로 취급해 네트워크로 가려 한다).
  local work="${PNPM_WORK_DIR:-$HOME/.local/share/admin-console-pnpm}"
  local id; id="$(grep ' frontend/pnpm-offline\.tar\.gz\.part-' "$SRC/SHA256SUMS" | sha256sum | cut -c1-64)"
  if [[ "$(cat "$work/.bundle-id" 2>/dev/null)" != "$id" ]]; then
    echo "=== pnpm store · cache → $work ==="
    rm -rf "$work" && mkdir -p "$work"
    cat "$SRC"/frontend/pnpm-offline.tar.gz.part-* | tar -xzf - -C "$work"
    echo "$id" >"$work/.bundle-id"
  fi
  local store="$work/pnpm-store" cache="$work/pnpm-cache"

  echo "=== frontend node_modules (offline) ==="
  # 메타데이터 cache 는 XDG_CACHE_HOME 으로 지정 (pnpm 12 install 에 --cache-dir 없음).
  ( cd "$proj/frontend" && XDG_CACHE_HOME="$cache" pnpm install --offline --frozen-lockfile \
      --config.registry="$NPM_REGISTRY" --store-dir "$store" )
  check_native "$proj/frontend"

  # 직접 실행하는 `pnpm install` 과 `pnpm build`(실행 전 의존성 확인 → 필요하면 자동 install)도 이 store 를
  # 쓰도록 사용자 전역 설정(~/.config/pnpm/config.yaml)에 기록 — 기본 store(~/.local/share/pnpm/store)는 비어 있어
  # 폐쇄망에서 ERR_PNPM_NO_OFFLINE_TARBALL 이 난다. 끄려면 PNPM_SET_GLOBAL=0.
  if [[ "${PNPM_SET_GLOBAL:-1}" == 1 ]]; then
    pnpm config set storeDir "$store" >/dev/null
    pnpm config set cacheDir "$cache/pnpm" >/dev/null
    echo "pnpm 전역 설정: storeDir=$store · cacheDir=$cache/pnpm"
  fi
  echo "빌드: cd $proj/frontend && pnpm build   (→ frontend/out)"
}

cmd="${1:-}"; proj="${2:-}"
case "$cmd" in
  runtime)  install_runtime ;;
  backend)  [[ -n "$proj" ]] || die "프로젝트 경로를 지정하세요."; install_backend "$(cd "$proj" && pwd)" ;;
  frontend) [[ -n "$proj" ]] || die "프로젝트 경로를 지정하세요."; install_frontend "$(cd "$proj" && pwd)" ;;
  all)      [[ -n "$proj" ]] || die "프로젝트 경로를 지정하세요."; p="$(cd "$proj" && pwd)"
            install_runtime; install_backend "$p"; install_frontend "$p" ;;
  *)        sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
