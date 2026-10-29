# sitegen: 앱 소개 페이지

앱마다 GitHub Pages(`docs/`)에 있는 소개 겸 지원 페이지를 한 벌의 디자인으로 만든다.
App Store 의 지원 URL · 마케팅 URL 이 이 페이지라서, 주소(`docs/index.html`, `docs/<언어>/index.html`)는 바꾸지 않는다.

```
python3 ~/Documents/workspace/Auto/DeployBar/scripts/sitegen/sitegen.py <레포 경로>
```

기준 예시는 **낫마템포** `docs/site/` 다. 처음 만드는 앱은 그것부터 읽는다.

## 앱 쪽에 두는 것: `docs/site/`

| 파일 | 내용 |
|---|---|
| `site.json` | 앱 공통 설정 (아래) |
| `<code>.json` | 그 언어의 글. `code` 는 `site.json` locales 의 code 와 같다 |
| `demo.js` · `demo.css` | (선택) 페이지 안에서 직접 해 보는 체험 |

생성기가 만드는 것: `docs/index.html`, `docs/<언어>/index.html`, `docs/site.css`, `docs/img/<code>/*.jpg`(웹용으로 줄인 스크린샷 · 공유 미리보기 `og.jpg`), `docs/icon.png`, 있으면 `docs/demo.*`.
`privacy.html` · `style.css` 는 건드리지 않는다.

### site.json

```json
{
  "name": {"en": "Not My Tempo", "ko": "낫마템포"},      // 언어별 앱 이름, 없는 언어는 en
  "url": "https://m1zz.github.io/<Repo>/",               // 끝에 / . 기존 index.html 의 canonical 과 같게
  "appStoreId": "6781537149",                            // APPSTORE.md · 기존 페이지 · deploy.env 에서
  "email": "leeo@kakao.com",
  "copyright": "Not My Tempo", "year": 2026,
  "color": {"light": "#0A7EA4", "dark": "#22D3EE", "darkBg": "#0a0d0f"},  // 앱의 키 색 (Palette · AccentColor 에셋)
  "shots": ["01-playing", "04-voice", "02-orbit", "05-accents"],          // 첫 장은 첫 화면, 나머지는 features 와 짝
  "shotsFrom": "raw",          // raw(글씨 없는 앱 화면, 기본) | marketing(헤드라인 얹은 그림)
  "shotsFallback": "en-US",    // 그 언어 화면이 없을 때 쓸 폴더
  "frame": "phone",            // phone: 아이폰 테두리 | plain: 둥근 모서리만 (맥 · 아이패드 · 가로 그림)
  "video": "screenshots/preview-ko/01-preview.mp4",   // (선택) 첫 화면에 반복 재생. 언어별이면 {"ko": "...", "default": "..."}
  "locales": [{"code": "en", "path": "", "shots": "en-US", "name": "English"},
              {"code": "ko", "path": "ko/", "name": "한국어"}, ...]
}
```

언어 폴더 안에 `privacy.html` 이 없고 다른 이름이면 그 언어 항목에 `"privacy": "../privacy-en.html"` 처럼 페이지 기준 주소를 적는다.
`locales` 는 지금 `docs/` 에 있는 언어 폴더 전부 + 루트(en, path "")다. 기존 index.html 의 언어 목록 · hreflang 과 같은 코드 · 같은 이름을 쓴다.
`shots` 는 스크린샷 폴더의 파일 이름(확장자 없이)이다. 언어마다 같은 이름으로 있어야 한다.

### `<code>.json` — 글

```
title, description                    검색 · 공유에 나오는 제목과 한 줄 (description 150자 안쪽)
hero: headline, lead, cta, note       headline 은 \n 으로 두 줄까지. cta 는 "App Store에서 무료로 받기" 처럼
demo: title, lead, ...                (선택) 체험 칸. 나머지 키는 demo.js 가 읽는다
problem: title, text                  이 앱이 없을 때 겪는 구체적인 순간
features: [{title, text, shot}]       좋아지는 점 3개 안팎. shot 은 shots 중 하나
steps: title, items[{title, text}]    시작하는 3단계
reference: title, rows[[k, v]], note  (선택) 명령표 · 단축키 · 요금표처럼 찾아보는 표
pricing: title, free{name, items}, pro{name, items, note}, note   무료로 되는 것을 먼저 · 앱에 유료가 없으면 이 절을 통째로 뺀다
faq: title, items[{q, a}]             기존 페이지의 문제 해결 · 사용법 · 문의를 모두 여기로. 6~10개
closing: headline, cta
ui: skip, languages, privacy, contact ({email} 자리에 메일 주소가 들어간다)
    links: [[이름, 주소]]              (선택) 푸터에 더할 링크. 예: 리모컨 앱 안내, 지원 페이지
```

`` `start` `` 처럼 백틱으로 감싼 말은 강조 색으로 나온다(앱에서 그대로 누르거나 말하는 말에만 쓴다).

## 글 쓰는 규칙

1. **기능은 소스에서 확인한다.** 앱에 없는 기능, 유료 · 무료 구분이 틀린 말은 실패다. 기존 페이지 · `APPSTORE.md` 와 어긋나면 소스를 따른다.
2. **기존 지원 정보를 잃지 않는다.** 기존 index.html 의 사용법 · 문제 해결 · 문의 · 가격 안내는 FAQ · reference · pricing 으로 옮긴다.
3. **결과를 구체적으로.** "편리한", "혁신적인", "강력한" 같은 빈말 대신 그 앱으로 무엇이 어떻게 달라지는지 쓴다.
4. **원어민 글.** 언어마다 그 나라 사람이 쓴 것처럼 쓴다. 한국어 · 영어를 옮겨 적지 않는다. 다른 언어 글자가 섞이면 실패(앱 이름 · 명령어 같은 고유명사는 예외).
   기존 `docs/<언어>/index.html` · `APPSTORE.md` 의 그 언어 절에 쓰인 용어를 이어 쓴다.
5. **한 페이지에 한 가지 행동.** 버튼은 App Store 받기뿐이다(체험 링크 제외).
6. 한국어는 해요체 · 합니다체 중 앱 문구에 맞춰 하나로. 줄표(—)를 남발하지 않는다.

## 체험 · 영상

사용자가 효용을 직접 느끼게 하는 것이 목적이다. 앱마다 하나를 고른다.

- **체험(`demo.js`)**: 앱의 핵심 동작을 브라우저에서 정직하게 흉내 낼 수 있으면 만든다(낫마템포: 말하면 박이 바뀐다).
  네트워크 · 외부 라이브러리 없이, 앱과 같은 규칙(소스에서 가져온 값)으로, 200줄 안쪽. 앱에 없는 동작을 보여 주지 않는다.
  `#demo` 의 `data-text` 로 그 언어 글이 들어온다. 디자인 값은 `site.css` 의 변수(`--accent`, `--s*`, `--r-*`, `--ease`)를 쓴다.
  동작 줄이기(`prefers-reduced-motion`)를 존중하고, 버튼은 44px 이상, 키보드로 쓸 수 있게.
- **영상**: `docs/` 안에 앱 미리보기 영상이 있으면 `video` 로 첫 화면에 건다. 8MB 넘으면 쓰지 않는다.
- 둘 다 맞지 않으면 스크린샷만으로 충분하다. 억지로 만들지 않는다.

## 확인

1. 생성기가 `⚠️ 글이 없어 건너뛴 언어` 없이 끝난다.
2. 로컬에서 띄워 눈으로 본다: `cd docs && python3 -m http.server 8765` 후 데스크톱 폭 · 390px 폭 · 다크 모드.
   헤드리스 캡처: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --force-prefers-reduced-motion --window-size=1280,9000 --screenshot=out.png http://localhost:8765/ko/`
   (390px 는 창 최소 폭 때문에 `<iframe style="width:390px">` 로 감싼 페이지를 캡처한다)
3. 체험이 있으면 버튼을 눌러 상태가 바뀌는지 확인한다.
4. 커밋: `docs/` 만. 메시지 예: `docs(소개 페이지): 공용 디자인으로 다시 만듦 — 23개 언어, 체험 데모`
