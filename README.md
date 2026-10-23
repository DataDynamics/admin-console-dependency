# Admin Console 폐쇄망 의존성 패키지

- 대상: **RHEL 9.x x86_64** (9.5 기준 검증) — OS 패키지(RPM) 설치 없이 동작
- 생성: 2026-10-23 · 소스 `9753628-dirty` (`scripts/airgap/build_deps.sh`)

| 경로 | 내용 |
|---|---|
| `runtime/` | Node.js v24.22.1 (linux-x64, tar.gz) · pnpm 12.9.1 (단독 실행 바이너리) |
| `backend/wheelhouse/` | `backend/requirements.txt` 의 **cp39** manylinux x86_64 wheel — RHEL 9 기본 `python3`(3.9)용 |
| `frontend/pnpm-store/` · `pnpm-cache/` | `frontend/pnpm-lock.yaml` 의 모든 패키지 (pnpm 오프라인 store + 메타데이터 cache) |
| `install_deps.sh` | 오프라인 설치 스크립트 |
| `SHA256SUMS` | runtime · wheelhouse 체크섬 (설치 시 자동 확인) |

## 설치

```bash
# 1) 런타임 — /opt/admin-console-runtime 에 설치, /usr/local/bin 에 node·npm·npx·pnpm 링크
sudo ./install_deps.sh runtime

# 2) 프로젝트 의존성 (소스는 git clone 등으로 별도 반입)
./install_deps.sh backend  /path/to/gmes-admin-console-gui    # backend/.venv
./install_deps.sh frontend /path/to/gmes-admin-console-gui    # frontend/node_modules

# 3) 빌드 · 실행
cd /path/to/gmes-admin-console-gui/frontend && pnpm build      # → frontend/out
cd ../backend && ./run.sh
```

- backend 는 시스템 `python3`(RHEL 9 기본 3.9)로 실행한다 — 다른 인터프리터는 `PYTHON=/path/to/python3 ./install_deps.sh backend ...`.
- 설치 위치 변경: `RUNTIME_PREFIX=/opt/xxx ./install_deps.sh runtime`
- 패키지 생성 이후 `requirements.txt` / `pnpm-lock.yaml` 이 바뀌면 설치가 경고 후 실패할 수 있다 — 빌드 머신에서 다시 생성.
- PostgreSQL 클라이언트(`psql`, 스키마 적용용)와 Oracle Instant Client 는 포함하지 않는다
  (Oracle 은 python-oracledb thin 모드라 클라이언트 불필요).
