# MeetingCaption

회의 중 컴퓨터에서 나오는 소리나 마이크 음성을 이 Mac에서 실시간 자막으로 바꾸고, 필요하면 한국어 번역을 함께 보여 주는 macOS 앱입니다. 기록은 이 Mac의 보관 폴더에 저장되며 TXT·SRT로 내보낼 수 있습니다.

- 음성 인식: Apple 음성 인식(기기 내 처리). 회의 오디오를 별도 서버로 보내지 않습니다.
- 번역: Apple 번역(기본) 또는 선택 사항인 Google Cloud Translation·DeepL·Papago.
- 떠 있는 자막 창, 원문+번역 복사, 회의 기록 보관·불러오기.
- **중요 표시**: ⌘D로 최신 자막을, 오른쪽 클릭으로 아무 자막이나 ★ 표시합니다. 중요 표시만 모아 보거나 TXT로 내보낼 수 있습니다.
- **기록 검색**: 사이드바에서 저장된 모든 기록의 원문·번역·제목을 대소문자·악센트 구분 없이 찾고, 결과를 누르면 해당 문장으로 이동합니다.
- **기록 정리**: 기록 이름 바꾸기, 휴지통으로 이동(되살리기 가능), 과목 지정. 사이드바는 과목별(미분류 포함)로 접고 펼 수 있습니다.
- **전공 용어집**: 오인식된 단어를 용어로 고치고, 고정 한국어 번역을 지정합니다. CSV로 가져오기·내보내기를 지원합니다.
- **녹음(선택)**: 켜면 인식한 소리를 기록 옆에 .m4a로 저장하고, 자막 옆 ▶ 또는 ‘여기부터 듣기’로 그 부분부터 다시 들을 수 있습니다. 녹음해도 되는지 먼저 확인해 주세요.
- **파일 받아쓰기**: 이미 있는 녹음·동영상 파일을 툴바의 **파일 받아쓰기**(⌘O)로 열거나 창에 끌어다 놓으면 새 기록으로 받아씁니다. 소리 사본을 함께 보관해 자막을 눌러 다시 들을 수 있습니다.
- AI 요약(회의록·강의 노트)·발언 제안·표현 교정·연습: Apple 온디바이스(기본) 또는 선택 사항인 OpenAI·Gemini·Claude. 요약에 적힌 시간을 누르면 그 자막으로 이동합니다.

## 왜 MeetingCaption인가

- **전부 이 Mac 안에서, 무료로**: 음성 인식과 기본 번역이 모두 기기 안에서 돌아갑니다. 계정 가입, 구독, 서버 업로드가 없고 회의·강의 소리는 어디로도 나가지 않습니다.
- **영어 자막과 한국어 번역을 한 화면에**: Zoom·유튜브 강의처럼 컴퓨터에서 나오는 소리와 마이크 음성을 모두 받아, 원문과 번역을 실시간으로 나란히 보여 줍니다.
- **끊긴 문장을 이어서 번역**: 말하다 잠깐 쉰 뒤 이어지는 문장을 합쳐서 번역하므로(대기 시간 조절 가능), 조각난 번역이 줄어듭니다.
- **받아쓰기에서 끝나지 않는 공부 도구**: 강의 중 ⌘D 한 번으로 중요 표시, 과목별 기록 정리, 모든 기록 검색, 자막을 눌러 그 부분부터 다시 듣기.
- **전공 용어를 내 방식대로**: 자주 틀리게 인식되는 단어를 자동으로 고치고, 용어마다 한국어 번역을 고정합니다.
- **외부 서비스는 내가 고를 때만**: Google·DeepL·Papago·OpenAI·Gemini·Claude는 직접 선택하고, 내 키를 넣고, 기록마다 전송에 동의해야만 텍스트를 보냅니다. 키는 키체인에만 저장됩니다.
- **기록이 사라지지 않게**: 확정된 문장은 바로 저장되고, 앱이 갑자기 꺼져도 다음 실행 때 복구합니다. TXT·SRT로 내보낼 수 있습니다.
- **설치하면 알아서 최신 버전**: 서명이 확인된 업데이트만 자동으로 설치합니다. 소스는 MIT 라이선스로 공개되어 있습니다.

## 요구 사항

- Apple Silicon(M1 이상) Mac
- macOS 26 이상

## 설치 (DMG)

1. [Releases](../../releases/latest)에서 `MeetingCaption-<버전>.dmg`를 내려받아 엽니다.
2. `MeetingCaption.app`을 옆의 `Applications`(응용 프로그램) 폴더로 끌어 놓습니다.
3. 처음 실행할 때: 이 앱은 Apple 공증(notarization)을 받지 않은 자체 서명 앱이라, 내려받은 파일에 붙은 격리 표시(`com.apple.quarantine`) 때문에 macOS(Gatekeeper)가 처음 한 번 실행을 막습니다. macOS 버전과 상황에 따라 둘 중 하나가 나옵니다.
   - **"Apple은 'MeetingCaption'에 악성 코드가 없음을 확인할 수 없습니다"**(확인되지 않은 개발자) 경고: **완료**를 누른 뒤 **시스템 설정 → 개인정보 보호 및 보안**으로 가서 아래쪽 보안 항목의 "MeetingCaption이(가) 차단되었습니다" 옆 **그래도 열기**를 누르고 암호(또는 Touch ID)로 확인합니다. 다시 나오는 확인 창에서 **열기**를 누르면 이후에는 평소처럼 실행됩니다. **그래도 열기** 버튼은 차단된 직후 한동안(약 1시간)만 보이니, 없으면 앱을 한 번 더 열어 본 뒤 확인하세요.
   - **"'MeetingCaption'이(가) 손상되었기 때문에 열 수 없습니다. 해당 항목을 휴지통으로 이동해야 합니다."**: 이때는 **그래도 열기**가 나타나지 않습니다. 공증되지 않은 앱에 격리 표시가 붙어 있으면 파일이 멀쩡해도 이 메시지가 나올 수 있습니다. **휴지통으로 이동하지 말고** 창을 닫은 뒤, 아래처럼 DMG가 릴리스 페이지에 적힌 파일과 같은지 확인하고 격리 표시를 지웁니다.

   최신 macOS에서는 Control-클릭 → 열기로는 더 이상 우회되지 않습니다. 터미널에서는 두 경우 모두 다음으로 해결할 수 있습니다.

   ```sh
   # 1) 내려받은 DMG의 SHA-256이 릴리스 노트에 적힌 값과 같은지 확인
   shasum -a 256 ~/Downloads/MeetingCaption-<버전>.dmg
   # 2) 같을 때만: 설치한 앱(안의 모든 파일)에서 격리 표시를 지움
   xattr -dr com.apple.quarantine /Applications/MeetingCaption.app
   ```

   `xattr -dr`은 격리 표시만 지우고 앱의 서명은 건드리지 않습니다. 지운 뒤에는 Gatekeeper가 이 앱을 다시 검사하지 않으므로, 값을 확인한 파일에만 사용하세요. 값이 다르면 열지 말고 지우세요.

## 권한

- **화면 및 시스템 오디오 녹음**: 컴퓨터 소리를 자막으로 바꿀 때 필요합니다. 화면 영상은 저장하지 않습니다. 일부 앱은 시스템 오디오 캡처를 막습니다.
- **마이크**: 마이크 음성을 자막으로 바꿀 때 필요합니다.
- **음성 인식**: Apple 음성 인식 사용에 필요합니다.

권한은 시스템 설정 → 개인정보 보호 및 보안에서 언제든 바꿀 수 있습니다. 떠 있는 자막 창은 일반 창처럼 화면 공유에 보입니다.

## 외부 API 제공자 (선택 사항)

기본값은 모두 이 Mac 안에서 처리하는 Apple입니다. 외부 제공자는 **설정(⌘,)**의 번역·AI 탭에서 직접 고르고, 직접 발급한 키를 넣고, 전송에 동의해야만 사용합니다. 각 키 입력란 옆의 **키 발급 페이지 열기**로 공식 키 페이지를 열 수 있습니다.

| 용도 | 제공자 | 비용 | 필요한 키 |
| --- | --- | --- | --- |
| 번역 | Google Cloud Translation | 문자 수에 따라 유료(결제 활성화 필요) | API 키 |
| 번역 | DeepL API | Free 플랜은 월 무료 한도, Pro는 문자 수에 따라 유료 | 인증 키(Free 키는 `:fx`로 끝남) |
| 번역 | Papago (NAVER Cloud) | 문자 수에 따라 유료 | Client ID + Client Secret |
| AI | OpenAI | 사용량에 따라 유료(ChatGPT 구독과 별개) | API 키 |
| AI | Google Gemini | 무료 등급 한도 또는 사용량에 따라 유료 | API 키 |
| AI | Anthropic Claude | 사용량에 따라 유료(Claude.ai 구독과 별개) | API 키 |

- **키 보관**: 모든 키는 이 Mac의 **키체인**에만 저장됩니다. 설정 파일, UserDefaults, 로그, 기록 파일에는 저장하지 않으며 오류 메시지에도 키를 표시하지 않습니다.
- **번역 동의**: 기록마다 따로 받습니다. 다른 기록을 열거나 새 기록을 시작하거나 휴지통으로 옮기거나 제공자를 바꾸면 다시 꺼집니다. 동의하면 현재 기록의 미번역 확정 자막과 이후 확정되는 원문 **텍스트**만 전송하며, 오디오·녹음 파일은 보내지 않습니다.
- **AI 동의**: 선택한 제공자에 대해서만 유효하며 제공자를 바꾸면 다시 꺼집니다.
- **무료 플랜의 데이터 사용**: Gemini API 무료 등급은 보낸 내용과 응답을 Google 제품 개선에 쓰고 사람이 검토할 수 있으며, DeepL API Free는 보낸 텍스트를 서비스 개선(학습)에 쓸 수 있습니다. 다른 사람의 발언이나 민감한 내용이 담긴 기록은 이 플랜으로 보내지 마세요.
- 외부 제공자가 실패해도 Apple로 자동 전환하지 않고, 자막은 그대로 남습니다. 용어집의 고정 한국어는 모든 번역 제공자에 적용되며, 확실히 적용할 수 없는 문장은 일반 번역을 사용합니다.

## 업데이트

앱은 [Sparkle](https://sparkle-project.org)로 GitHub Releases의 `appcast.xml`을 확인해 스스로 업데이트합니다.

- **설정(⌘,) → 정보**에서 현재 버전 확인, **업데이트 확인**, **자동으로 업데이트 확인**, **업데이트 자동 다운로드·설치**를 설정할 수 있습니다. 메뉴 **MeetingCaption → 업데이트 확인…**으로도 확인할 수 있습니다.
- 기본값은 자동 확인(하루 한 번)과 자동 설치가 모두 켜져 있습니다. 새 버전은 백그라운드에서 내려받아 두었다가 **앱을 종료할 때** 설치되므로, 기록 중에 앱이 꺼지지 않습니다.
- 모든 업데이트와 appcast는 개발자의 EdDSA 키로 서명되어 있으며, 서명이 맞지 않으면 설치하지 않습니다. 서명 실패가 오래 이어져도 서명 없는 appcast로 넘어가지 않습니다. 업데이트 주소는 빌드에 고정된 GitHub 릴리스 주소만 쓰며, 설정 값(`defaults`)으로 바꿀 수 없습니다.
- 앱 안에서 설치된 업데이트에는 다운로드 격리 표시가 붙지 않아, Gatekeeper 확인은 DMG로 처음 설치할 때 한 번뿐입니다.
- **권한 유지**: 1.5.0부터 모든 릴리스는 같은 자체 서명 인증서("MeetingCaption Release Signing")로 서명되므로 macOS가 업데이트 후에도 같은 앱으로 알아봅니다. 화면 및 시스템 오디오 녹음·마이크·음성 인식 권한과, 키체인에 저장한 API 키 접근은 업데이트해도 다시 묻지 않습니다.
- **1.4.0 이하에서 옮겨 올 때 한 번**: 1.4.0까지는 빌드마다 서명이 달라지는 임시(ad-hoc) 서명이었고 업데이트 기능도 없었습니다. 1.5.0은 DMG로 직접 설치하며, 처음 실행하면 macOS가 다른 앱으로 보고 권한을 다시 묻습니다. 시스템 설정 → 개인정보 보호 및 보안에서 화면 및 시스템 오디오 녹음·마이크·음성 인식을 다시 허용하세요(예전 MeetingCaption 항목이 켜져 있는데도 동작하지 않으면 그 항목을 − 버튼으로 지우고 다시 허용). 저장해 둔 API 키를 처음 읽을 때 키체인 창이 나오면 로그인 암호를 입력하고 **항상 허용**을 누르세요. 그 뒤의 업데이트에서는 다시 묻지 않습니다.
- 개발자가 서명 인증서를 잃어 새 인증서로 바꾸게 되면 같은 재허용이 한 번 더 필요하며, 그때는 릴리스 노트에 알립니다.
- 업데이트 주소 없이 빌드한 앱(직접 빌드한 개발용 앱 등)은 업데이트 기능이 꺼진 채로 정상 동작하며, 설정 화면에 그 이유가 표시됩니다.

## 소스에서 빌드

Xcode 없이 Command Line Tools만으로 빌드합니다.

```sh
# 앱 빌드 (기본 위치: 상위 폴더의 MeetingCaption.app; 이미 있거나 다른 .app 안이면 중단)
MEETINGCAPTION_APP_PATH=/tmp/build/MeetingCaption.app zsh build-meeting.sh

# 업데이트를 켜려면 appcast 주소를 지정 (GitHub 릴리스 주소 형식만 허용)
MEETINGCAPTION_FEED_URL=https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml \
MEETINGCAPTION_APP_PATH=/tmp/build/MeetingCaption.app zsh build-meeting.sh

# 테스트
swift test --scratch-path .build -j 1 \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

직접 빌드한 앱은 임시(ad-hoc) 서명이라 빌드할 때마다 macOS가 권한을 다시 묻습니다. `MEETINGCAPTION_SIGN_IDENTITY`(코드 서명 인증서의 SHA-1)를 주면 그 인증서로 서명합니다(`MEETINGCAPTION_SIGN_KEYCHAIN`으로 키체인 파일 지정 가능). 로컬 업데이트 테스트에서만 `MEETINGCAPTION_TEST_FEED_URL`(`http://127.0.0.1:<포트>/…` 또는 localhost 주소)과 `MEETINGCAPTION_TEST_BUNDLE_ID`(실제와 다른 번들 ID)를 함께 쓸 수 있습니다.

## 라이선스

[MIT](LICENSE). 자동 업데이트에는 [Sparkle](https://sparkle-project.org)(MIT)을 사용합니다.

---

## English

MeetingCaption turns system audio or microphone speech into live captions on your Mac using on-device Apple Speech, with optional Korean translation (Apple Translation, or Google Cloud Translation / DeepL / Papago with your own key). All configuration lives in the Settings window (⌘,).

- **Why:** everything runs on your Mac for free (no account, subscription or upload); original and Korean translation side by side for both system audio and microphone; sentences split by a short pause are merged before translating; study tools built in (bookmarks, subjects, archive search, replay from any caption, a glossary that fixes misrecognized terms and pins translations); cloud providers only when you choose them, with your own key and per-record consent.
- **License:** MIT.
- **Requirements:** Apple Silicon Mac, macOS 26 or later.
- **Install:** open the DMG and drag MeetingCaption into Applications. The app is self-signed and not notarized, so the first launch is blocked. If macOS says it cannot verify the app is free of malware, click **Done**, then System Settings → Privacy & Security → **Open Anyway**. If it says the app "is damaged and can't be opened", don't move it to the Trash: check `shasum -a 256` of the DMG against the release notes, then run `xattr -dr com.apple.quarantine /Applications/MeetingCaption.app` (removes only the download quarantine flag; use it only on a verified download).
- **Permissions:** Screen & System Audio Recording (system audio), Microphone, Speech Recognition.
- **Study features:** bookmarks (⌘D) with marked-only view/export, archive-wide record search, rename / move to Trash / subjects, a glossary for misrecognition fixes and fixed Korean renderings, and optional audio recording with caption-linked playback.
- **Optional cloud providers:** translation via Google Cloud Translation, DeepL or Papago; AI via OpenAI, Gemini or Claude. All are off by default, use your own key (stored only in the macOS Keychain), and send caption text (never audio) only after explicit consent. Note that the Gemini free tier and DeepL API Free may use submitted content to improve their services (Gemini: including human review).
- **Updates:** Sparkle checks the GitHub Releases appcast daily and, by default, downloads updates automatically and installs them when you quit. Updates and the appcast are EdDSA-signed; unsigned or mismatched ones are always rejected. From 1.5.0 every release is signed with the same self-signed certificate, so permissions and Keychain access survive updates; moving from the ad-hoc-signed 1.4.0 to 1.5.0 (installed from the DMG) asks once to re-allow Screen & System Audio Recording, Microphone, Speech Recognition and Keychain access.
- **Build:** see the commands above (`build-meeting.sh`).
