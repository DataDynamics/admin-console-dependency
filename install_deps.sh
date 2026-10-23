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
  ( cd "$SRC" && sha256sum --quiet -c SHA256SUMS ) || die "체크섬 불일치 — 복사 중 손상되었을 수 있습니다."
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
  same_file "$SRC/backend/requirements.txt" "$proj/backend/requirements.txt" \
    || echo "경고: 프로젝트 requirements.txt 가 패키지 생성 시점과 다릅니다 — 없는 wheel 이 있으면 설치가 실패합니다."
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

install_frontend() {
  local proj="$1"
  [[ -f "$proj/frontend/pnpm-lock.yaml" ]] || die "$proj/frontend/pnpm-lock.yaml 이 없습니다."
  [[ -x "$NODE_BIN/pnpm" ]] || die "pnpm 이 없습니다 — 먼저 'install_deps.sh runtime'."
  same_file "$SRC/frontend/pnpm-lock.yaml" "$proj/frontend/pnpm-lock.yaml" \
    || echo "경고: 프로젝트 pnpm-lock.yaml 이 패키지 생성 시점과 다릅니다 — store 에 없는 패키지가 있으면 설치가 실패합니다."
  echo "=== frontend node_modules (offline) ==="
  # pnpm 은 쓰기 불가한 store 를 cache miss 로 취급해 네트워크로 가려 한다 → 이 디렉터리가 읽기 전용
  # (ISO · 읽기 전용 마운트 등)이면 쓰기 가능한 위치로 복사해서 쓴다.
  local store="$SRC/frontend/pnpm-store" cache="$SRC/frontend/pnpm-cache"
  if [[ ! -w "$store" || ! -w "$cache" ]]; then
    local work="${PNPM_WORK_DIR:-$HOME/.cache/admin-console-pnpm}"
    echo "패키지 디렉터리가 읽기 전용 — store/cache 를 $work 로 복사"
    mkdir -p "$work" && rm -rf "$work/pnpm-store" "$work/pnpm-cache"
    cp -a "$store" "$cache" "$work/"
    store="$work/pnpm-store"; cache="$work/pnpm-cache"
  fi
  # 메타데이터 cache 는 XDG_CACHE_HOME 으로 지정 (pnpm 12 install 에 --cache-dir 없음).
  ( cd "$proj/frontend" && XDG_CACHE_HOME="$cache" pnpm install --offline --frozen-lockfile --store-dir "$store" )
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
