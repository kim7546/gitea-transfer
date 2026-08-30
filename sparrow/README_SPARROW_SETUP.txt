Sparrow integration - v7.2
==========================

현재 상태
---------
Sparrow 환경이 아직 없으므로 모든 프로젝트 설정은 아래처럼 OFF 입니다.

  "sparrow": {
    "enabled": false
  }

OFF이면 02는 v7.1과 동일하게 동작하며 Sparrow를 전혀 호출하지 않습니다.

나중에 Sparrow 환경이 준비되면
-----------------------------
1. 외부 반입 담당자 PC에 Sparrow 실행 환경(Client/CLI 또는 회사에서 정한 실행 방식)을 구성합니다.
2. C:\gitea-transfer\sparrow\run-sparrow.cmd 의 "VENDOR COMMAND" 부분을 한 번만 실제 명령에 맞게 연결합니다.
3. 연결 테스트가 끝나면 프로젝트 JSON의 enabled만 true로 변경합니다.

예:
  "sparrow": {
    "enabled": true
  }

그 이후에는 프로그램/스크립트 수정 없이 true / false만 바꾸면 됩니다.

02에서 Sparrow ON 시 동작
-------------------------
Success 시점 전체 프로젝트
 + allowedAuthorEmails에 해당하는 선택 Commit Patch만 적용
 = C:\gitea-transfer\scan\<project>\<mode>\<branchKey>\<freezeId>

이 임시 전체 프로젝트를 Sparrow Runner에 전달합니다.

Runner 반환 규약
----------------
0  : PASS
     -> Export Package 생성 계속
     -> Package\sparrow 에 검사 로그 포함

10 : 코드 검사 실패 / 수정 필요
     -> transfer/rejected/<mode>/<branch>/<freezeId> Tag 추가
     -> Claim Tag 삭제
     -> Freeze Tag는 이력으로 유지
     -> Package 생성 중단
     -> 개발자 수정 후 새 01 Freeze부터 다시 진행

기타 Exit Code : Sparrow 환경/통신/실행 오류
     -> REJECTED Tag를 만들지 않음
     -> Freeze/Claim 유지
     -> 환경 수정 후 같은 02를 다시 실행 가능

결과 위치
---------
C:\gitea-transfer\results\sparrow\<project>\<mode>\<branchKey>\<freezeId>\

02는 developers.txt도 생성합니다.
이 파일에는 이번 반입 대상 Commit의 Author Email, Commit SHA, 제목, 변경 파일이 기록됩니다.
Sparrow 실제 결과 형식을 확정한 뒤 Runner에서 개발자별 상세 결과 파일을 추가 생성할 수 있습니다.
