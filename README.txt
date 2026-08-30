[v7.1 HOTFIX]
01 Freeze의 신규 Tag 생성 시 존재하지 않는 로컬 Tag 삭제 때문에 중단되던 문제를 수정했습니다.
브랜치별 독립 상태 구조는 v7과 동일합니다.

Gitea / GitHub -> GitLab 반입 자동화 Toolkit v7
=================================================

핵심 변경(v7)
--------------
상태를 이제 "프로젝트 + Mode(TEST/PROD) + sourceBranch" 단위로 완전히 분리합니다.

예:
  my-react-app + TEST + feature-dev
  my-react-app + TEST + feature-test
  my-react-app + PROD + main

위 3개는 Baseline / Freeze / Claim / Success가 서로 섞이지 않습니다.

Tag 예시
--------
TEST + feature-dev:
  transfer/success/test/feature-dev/<Id>
  transfer/freeze/test/feature-dev/<Id>
  transfer/claim/test/feature-dev/<Id>

TEST + feature-test:
  transfer/success/test/feature-test/<Id>
  transfer/freeze/test/feature-test/<Id>
  transfer/claim/test/feature-test/<Id>

PROD + main:
  transfer/success/prod/main/<Id>
  transfer/freeze/prod/main/<Id>
  transfer/claim/prod/main/<Id>

기존 v6의 transfer/success/test/<Id> 같은 Tag는 v7 상태 판정에 사용하지 않습니다.

폴더 구조
---------
C:\gitea-transfer\
  bat\test\      TEST 00~05
  bat\prod\      PROD 00~05
  scripts\       실제 PowerShell 로직
  config\        프로젝트별 설정
  dist\          외부망 Package 생성 위치
  inbound\       내부망 Package 투입 위치

프로젝트 설정
-------------
config\<프로젝트명>.json 의 external.profiles에서 현재 테스트/운영 브랜치를 지정합니다.

예:
  "test": { "sourceBranch": "feature-dev" }
  "prod": { "sourceBranch": "main" }

TEST에서 feature-dev를 완료한 뒤 feature-test를 새로 시험하려면 test.sourceBranch를
feature-test로 변경하고 다시 00 TEST부터 시작할 수 있습니다. feature-dev의 Tag는 그대로
남고 feature-test는 별도의 Baseline을 만듭니다.

Package 폴더도 브랜치별 분리
----------------------------
외부:
  C:\gitea-transfer\dist\<project>\<mode>\<branchKey>\<FreezeId>

예:
  C:\gitea-transfer\dist\my-react-app\test\feature-dev\... 가 아니라
  C:\gitea-transfer\dist\my-react-app\test\feature-dev\ 형태로 보일 수 있는 단순 이름은 동일하고,
  slash가 포함된 branch(feature/dev)는 Windows 안전키 feature__dev 로 저장됩니다.

내부:
  C:\gitea-transfer\inbound\<project>\<mode>\<branchKey>\<FreezeId>

00~05
-----
00 Initialize Baseline
  현재 설정된 Project + Mode + sourceBranch의 최초 성공 기준점을 생성합니다.
  같은 프로젝트/Mode라도 sourceBranch가 다르면 각각 00을 실행할 수 있습니다.

01 Freeze Project
  현재 설정된 sourceBranch의 origin/<branch> HEAD에 이번 반입 기준점을 생성합니다.

02 Claim & Export
  같은 Project + Mode + sourceBranch의 마지막 Success ~ 현재 Freeze 범위만 추출합니다.
  allowedAuthorEmails에 존재하는 Author Email의 Commit만 선택합니다.

03 Import Package (내부망)
  현재 Project + Mode + sourceBranch와 일치하는 Package 폴더에서 가져옵니다.
  내부 origin/main 기준 import branch를 만들고 Patch를 적용/검증/Push합니다.
  import branch명에도 branchKey가 포함됩니다.

04 Confirm Success (외부망)
  같은 Project + Mode + sourceBranch의 Freeze만 Success 처리합니다.
  완료된 Claim은 삭제합니다. Freeze/Success Tag는 이력으로 보관합니다.

05 Release Claim (외부망, 예외용)
  같은 Project + Mode + sourceBranch의 현재 Claim만 해제합니다.

운영 원칙
---------
- 한 번 01을 시작한 차수는 같은 사람이 02 -> 내부 03 -> 외부 04까지 맡습니다.
- 00은 Project + Mode + sourceBranch마다 최초 1회입니다.
- TEST에서 여러 브랜치를 독립적으로 반복 검증할 수 있습니다.
- PROD main은 TEST 브랜치들의 Tag/Success와 완전히 독립적입니다.
- sourceBranch를 바꾸기 전에 진행 중 Claim/Freeze가 있다면 먼저 그 브랜치 차수를 끝내세요.

IntelliJ External Tools Arguments
--------------------------------
워크스페이스가 여러 프로젝트라면 경로를 직접 적어도 됩니다.
예:
  "D:\workspace\my-react-app"

또는 단일 프로젝트 창이면:
  "$ProjectFileDir$"

집 GitHub 테스트
---------------
config\my-react-app.json을 포함했습니다.
1) allowedAuthorEmails를 실제 git log의 Author Email로 수정
2) test.sourceBranch를 시험할 브랜치명으로 수정
3) 해당 브랜치를 GitHub origin에 Push
4) 00 TEST부터 실행
5) 다른 브랜치를 시험하려면 sourceBranch만 바꾸고 다시 00 TEST부터 시작
