# Admin Console 폐쇄망 의존성 패키지

- 대상: **RHEL 9.x x86_64** (9.5 기준 검증) — OS 패키지(RPM) 설치 없이 동작
- 생성: 2026-10-27 · 소스 `61e1ed2` (`scripts/airgap/build_deps.sh`)

| 경로 | 내용 |
|---|---|
| `runtime/` | Node.js v24.22.1 (linux-x64, tar.gz) · pnpm 12.9.1 (단독 실행 바이너리) |
| `backend/wheelhouse/` | `backend/requirements.txt` 의 **cp39** manylinux x86_64 wheel — RHEL 9 기본 `python3`(3.9)용 |
| `frontend/pnpm-offline.tar.gz.part-*` | `frontend/pnpm-lock.yaml` 의 모든 패키지 (pnpm 오프라인 store + 메타데이터 cache, 90MB 조각) |
| `install_deps.sh` | 오프라인 설치 스크립트 |
| `SHA256SUMS` | runtime · wheelhouse · frontend 조각 체크섬 (설치 시 자동 확인) |

## 반입

이 디렉터리를 **tar 등으로 그대로** 옮긴다. GitHub 의 *Download ZIP* 이나 git-lfs 없는 `git clone` 은
LFS 파일을 포인터로 받으므로 쓰지 않는다 — 설치가 체크섬으로 감지하고 중단한다.

## 설치

```bash
# 1) 런타임 — /opt/admin-console-runtime 에 설치, /usr/local/bin 에 node·npm·npx·pnpm 링크
sudo ./install_deps.sh runtime

# 2) 프로젝트 의존성 (소스는 git clone 등으로 별도 반입)
./install_deps.sh backend  /path/to/admin-console-gui    # backend/.venv
./install_deps.sh frontend /path/to/admin-console-gui    # frontend/node_modules

# 3) 빌드 · 실행
cd /path/to/admin-console-gui/frontend && pnpm build      # → frontend/out
cd ../backend && ./run.sh
```

- backend 는 시스템 `python3`(RHEL 9 기본 3.9)로 실행한다 — 다른 인터프리터는 `PYTHON=/path/to/python3 ./install_deps.sh backend ...`.
- 설치 위치 변경: `RUNTIME_PREFIX=/opt/xxx ./install_deps.sh runtime`
- 프로젝트의 `requirements.txt` / `pnpm-lock.yaml` 이 패키지 생성 시점(위 소스)과 다르면 설치가 **중단**된다 —
  배포할 소스로 빌드 머신에서 다시 생성 (`ALLOW_LOCK_MISMATCH=1` 로 무시 가능하나 대개 중간에 실패).
- frontend store 는 `~/.local/share/admin-console-pnpm` 에 풀리고(`PNPM_WORK_DIR` 로 변경), 사용자 pnpm 전역 설정
  (`~/.config/pnpm/config.yaml` 의 `storeDir` · `cacheDir`)에 기록된다 — 이후 직접 실행하는 `pnpm install` · `pnpm build` 도
  이 store 를 쓴다 (`PNPM_SET_GLOBAL=0` 이면 기록하지 않음). 의존성은 반드시 `install_deps.sh frontend` 로 설치한다.
- PostgreSQL 클라이언트(`psql`, 스키마 적용용)와 Oracle Instant Client 는 포함하지 않는다
  (Oracle 은 python-oracledb thin 모드라 클라이언트 불필요).
