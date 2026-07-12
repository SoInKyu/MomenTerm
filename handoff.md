# Handoff — MomenTerm

> 마지막 업데이트: 2026-07-12
> **참고**: 이 파일은 세션 간 작업 컨텍스트를 유지합니다.

## 현재 목표
MT 요구사항 문서 기반 전체 구현 — Phase 1~4 완료, Phase 5~7 골격

## 추가 완료 (2026-07-12 세션)
사용성 점수 평가를 축으로 `make run` 실행·시각 검증을 돌리며 발견한 결함 4건을 수정·검증·커밋. 사용성 점수 추이: 72(코드 추정) → 78(빌드·실행 확인) → 85(스크린샷 시각 검증) → 90(수정 반영) → 92(자유 리사이즈 검증).

- [x] **메뉴 아이콘 누락 2건 보강** (commit 9b79e65a5) — 실행 로그의 “These identifiers lack icons: [Install Claude Code Integration, Project Manager]” 경고 제거. `MainMenuMangler.iconMap` 에 XIB 실존 항목 2개 매핑 추가(sparkles / folder.badge.gearshape). 검증: 경고 1→0, wrong-identifiers fatal 미발생.
- [x] **프로젝트 사이드바 중복 등록 버그 수정** (commit 06d729915) — 같은 폴더가 서로 다른 UUID 로 사이드바에 2개 표시되던 문제. 원인: `MomentermProject.init` 이 매번 새 UUID, `addProject` 중복검사가 id 기준뿐. 수정: `normalizedPath`(standardizingPath) 기준 dedup + `deduplicateProjects()` + `Storage.load()` 에서 self-heal. 검증: 실제 store `~/.momenterm/projects.json` 8→7 로 중복 제거 확인.
- [x] **Git Graph tag ref 오분류 수정** (commit 3583a9d31) — 태그 ref 가 초록(localBranch 색) + “tag: refs/tags/…” full 경로로 잘못 표시. 원인: git 이 `--decorate=full` 에서도 붙이는 “tag: ” 접두어를 `MomentermGitRefInfo.from(decoration:)` 이 미처리 → .localBranch fallback. 수정: “tag: ” 스트립 후 kind=.tag. 검증: 파싱 로직 독립 실행 확인(주황 + “v0.1.0-ideation-reviewed”), 브랜치/리모트/HEAD 회귀 없음.
- [x] **iTerm2ImportStatus 헬퍼 앱 사용자 노출 브랜딩 정리** (commit 937446ac3) — 메뉴바 문자열 6건(About/Hide/Quit/Help/앱메뉴) → “MomenTerm Import”, pbxproj 헬퍼 4개 config 에 `INFOPLIST_KEY_CFBundleDisplayName = "MomenTerm Import"`. `customModule` 코드 식별자·`PRODUCT_NAME`·번들 ID·경로는 보존(ImportExport.swift:211 실경로 참조 보호). 검증: 빌드 헬퍼 Info.plist DisplayName·MainMenu.nib 반영, plutil OK.
- [x] **자유 리사이즈 검증** — `disableWindowSizeSnap` 기본값 YES(iTermAdvancedSettingsModel.m:647) + `PseudoTerminal.m windowWillResize:` 6175-6177 에서 flag ON 시 snap 무력화 확인. 런타임 `defaults` 두 도메인 모두 unset → 기본값 활성. (물리 드래그 체감만 미관찰 — 코드 결정론적)

### 검증 환경 메모
- 이 세션 쉘은 화면 녹화·손쉬운 사용(접근성) 권한이 없어 스크린샷/UI 자동조작 불가. 시각 확인은 사용자 제공 스크린샷으로, 나머지는 빌드 로그·런타임 defaults·persisted store·독립 실행으로 검증.
- `make run` 은 앱 종료 시 래퍼가 exit 1/144 로 끝나지만 이는 크래시 아님(정상 종료/pkill). 빌드 성공 판정은 “** BUILD SUCCEEDED **” 마커 기준.
- 안전 백업 `~/.momenterm/projects.json.bak` 생성됨(dedup 검증용, 불필요 시 삭제 가능).

## 추가 완료 (2026-07-08 세션)
- [x] iTerm2 → MomenTerm 사용자 노출 문구 일관성 정리 (26 파일) — 알림/프롬프트/설정 설명/Tip 본문의 제품명, 버그 신고 URL → GitHub issues. 프로토콜 식별자·실경로·업스트림 문서 URL 은 보존 (commit b0bfdd27a)
- [x] 터미널 창 자유 리사이즈 기본화 — disableWindowSizeSnap 기본값 YES (commit 167d26b99)
- [x] Tahoe 활성 그린 탭 풀필 라운드 3 — intercellSpacing 이음새 + 바 가장자리 마진까지 확장 (commit 54384f426)
- [x] Git Graph 고도화 — 레인 색상, ref 종류별 pill, 커밋 상세 팝오버, 우클릭 메뉴, 10초 자동 새로고침, %x1f 파싱, edgesByRow 인덱스 (commit 95363c156)
- [x] 환경: Xcode 26.6(17F113) 업데이트 대응 — deps 재빌드 + Metal Toolchain 다운로드. sfsymbolenum 타깃은 SF Symbols.app 미설치로 스킵 (체크인된 헤더 유효)

### 미결/후속 후보
- [x] ~~사용자 make run 화면 확인: 탭 풀필, Git Graph 색상, 창 리사이즈~~ — 2026-07-12 세션에서 스크린샷 시각 검증 완료(탭 풀필·Git Graph 레인/pill/컬럼·자유 리사이즈 로직)
- [x] ~~iTerm2ImportStatus 헬퍼 앱 메뉴 브랜딩~~ — 사용자 노출 문구 정리 완료(commit 937446ac3). 단 아래 “전체 앱 개명” 은 여전히 별도 스코프로 미결
- [ ] iTerm2ImportStatus **전체 앱 개명** — 타겟명/PRODUCT_NAME/`.app` 파일명/ImportExport.swift:211 실경로까지 변경하는 큰 스코프. 이번엔 표시명(DisplayName)만 정리, 실체명은 보존
- [ ] beta/dev/nightly/preview plist 의 SUFeedURL 이 여전히 iterm2.com (릴리스 채널 미사용이라 보류)
- [ ] release.sh 0.9.13 cut (스티커 커밋 bc1981f11 이후 누적분 포함) — 2026-07-12 수정 4건(9b79e65a5, 06d729915, 3583a9d31, 937446ac3) 포함
- [ ] Git Graph: 실 repo 에서 브랜치 다수/머지 커밋 있는 멀티레인 렌더 확인(이번 검증 repo 는 선형 히스토리라 단일 레인만 관찰)

## 최근 완료
- [x] `mt` CLI 패키지 생성 (`mt-cli/`) — TypeScript, npm, commander 기반
  - init, doctor, plugins, skills, upgrade, harness, vibe, handoff, mcp, projects 명령
  - `mt bootstrap` — 원클릭 프로젝트 초기화
- [x] Swift 프로젝트 관리 창 (`MomentermProject*.swift`)
  - MomentermProjectModel, Storage, WindowController, SidebarVC, FileTreeVC
  - 프로젝트 공간 + 프로젝트 트리 (NSOutlineView)
  - 파일 탐색 패널 (.agentignore 기반 필터링)
  - 더블클릭 → vi 편집 진입
- [x] AI 도구 체크 (`MomentermAIToolChecker.swift`) — Claude Code/Codex 설치 확인 및 실행 프롬프트
- [x] 새 탭/창 경로 유지 (`MomentermNewTabHandler.swift`)
- [x] 상태바 프로젝트 컴포넌트 (`MomentermStatusBarProjectComponent.swift`)
- [x] 문서 생성:
  - docs/harness-engineering.md
  - docs/mcp-server-setup.md
  - docs/db-setup.md
  - docs/deployment-guide.md
  - docs/github-guide.md
  - docs/ci-cd-guide.md
  - docs/operations-guide.md
  - docs/korean-ime-analysis.md
  - docs/image-paste-analysis.md
- [x] 운영 파일:
  - .agentignore (AI 컨텍스트 최적화)
  - .hooks/pre-commit (secret 감지, .env 보호)
  - .hooks/pre-push (빌드 검증)
  - .claude/commands/mt.md (/mt 슬래시 명령)

## 추가 완료 (2차 세션)
- [x] 모든 Swift/ObjC 소스 파일 Xcode 프로젝트 등록 (`iTerm2SharedARC` 타겟)
- [x] `iTermStatusBarSetupViewController.m` — `MomentermStatusBarProjectComponentImpl` 등록
- [x] `iTermApplicationDelegate.m` — Window 메뉴에 "MomenTerm Projects…" 항목 추가
- [x] `iTermApplicationDelegate.m` — `performStartupActivities`에서 AI 도구 체크 훅 연결
- [x] `iTermKeyboardHandler.m` — 한국어 IME Enter 단일입력 수정 (Single-Enter Commits IME 설정)
  - 기본값 YES, `defaults write com.googlecode.iterm2 MomentermSingleEnterCommitsIME -bool NO`로 비활성화
- [x] 이미지 붙여넣기 — `iTermNonTextPasteHelper.swift` 이미 완전히 구현되어 있음 (추가 작업 불필요)

## 수동으로 실행 필요

### 1. Git hooks 설치
```bash
cp .hooks/pre-commit .git/hooks/pre-commit
cp .hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-commit .git/hooks/pre-push
```

### 2. mt CLI 글로벌 링크 (테스트용)
```bash
cd mt-cli
npm link
mt --help
```

### 3. 빌드 & 실행
```bash
make run
```

## 추가 완료 (3차 세션)
- [x] `mt skills` — gstack, omc, open-spec 실제 runner 구현 (`mt-cli/src/commands/skills.ts`)
  - gstack: Graphite CLI 설치 + `gt repo init` + `.graphite_ignore` 생성
  - omc: CLAUDE.md, .agentignore, .claude/commands/review.md 생성
  - open-spec: openapi.yaml + .spectral.yaml 스캐폴드, spectral lint 실행
- [x] `mt vibe` — vibe-ready 미설치 시 install hint 표시 (`npm install -g vibe-ready-cli`)
- [x] `mt mcp scope` — 최소 권한 scope 정책 생성 (.claude/mcp-scope.json)
- [x] `mt mcp audit` — MCP 서버 scope 정책 준수 여부 점검
- [x] `mt guardrail` — 가드레일 이탈 감지 시스템 (`mt-cli/src/commands/guardrail.ts`)
  - `check`: staged + recent commits 대상 7개 규칙 스캔
  - `report`: 점수/등급 포함 .claude/guardrail-report.json 생성
  - `rules`: 전체 규칙 목록 출력
  - harness pre-commit 훅에 `mt guardrail check --commits 0` 자동 통합
- [x] `mt doctor` — gt, spectral 설치 여부 체크 추가

## 다음 액션
Phase 1~7 완료. 후속 후보는 위 “미결/후속 후보” 참고 — 우선순위: release.sh cut → SUFeedURL → 헬퍼 전체 개명 → Git Graph 멀티레인 확인.

## 막힌 이슈
- 없음. (이전 세션의 `MomenTerm.swiftmodule not found` / clean build 이슈는 2026-07-12 세션에서 `make run` 반복 빌드가 매번 “** BUILD SUCCEEDED **” 로 통과함을 확인 — 해소됨. 앱 21분+ 무크래시 상주, MomentermProjectRestorer/증분 캡처 정상 동작 관찰.)

## 참고 문서
- docs/harness-engineering.md — 전체 개발 원칙
- docs/operations-guide.md — 일상 개발 플로우
- docs/korean-ime-analysis.md — IME Enter 이슈 분석
- docs/image-paste-analysis.md — 이미지 붙여넣기 구현 계획
- mt-cli/src/ — mt CLI 소스

## 관련 브랜치
master

## 주의사항
- Auto Layout을 terminal window에 절대 사용 금지
- it_fatalError / it_assert 사용 (fatalError 아님)
- 새 파일 생성 후 즉시 git add + Xcode 등록 필요
- AI 생성 마크다운(플랜, 요약)을 커밋에 포함하지 않기
