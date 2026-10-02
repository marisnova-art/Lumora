# Lumora Studio — Global Photo & Video Creative Platform (v1.0.0)

모바일 우선 사진·영상 촬영/보정/변환 플랫폼의 초기 버전입니다.
`index.html` 한 파일에 앱 전체(UI, WebGL 보정 엔진, 카메라, 사진·영상 편집기, 관리자)가 들어 있고,
Supabase(SQL·RLS·Edge Functions)와 PWA 파일이 함께 제공됩니다.

```
lumora-studio/
├─ index.html                 ← 앱 전체 (단일 파일, 약 384KB, 빌드 도구 불필요)
├─ manifest.webmanifest       ← PWA 매니페스트
├─ sw.js                      ← 서비스 워커 (앱 셸 오프라인 캐시)
├─ icons/                     ← PWA 아이콘 (192/512/maskable/apple-touch)
├─ _headers                   ← Cloudflare Pages 보안 헤더 (카메라·마이크 권한 정책 포함)
└─ supabase/
   ├─ schema.sql              ← 17개 테이블, 인덱스, 트리거, RLS, RPC, Storage 버킷·정책
   ├─ seed.sql                ← 카테고리 16 · 프리셋 40 · 배너 · 공지 · 요금제/설정
   ├─ presets.seed.json       ← 관리자 "JSON 가져오기"용 프리셋 묶음 (seed.sql과 동일 데이터)
   ├─ config.toml             ← 함수별 JWT 검증 설정
   └─ functions/
      ├─ _shared/common.ts    ← CORS, 서비스 클라이언트, 인증 헬퍼
      ├─ _shared/payments.ts  ← 결제 제공자 추상화 (Stripe 구현 포함)
      ├─ create-checkout/     ← 후원·구독 결제 세션 생성 (test / live)
      ├─ payments-webhook/    ← 결제 서버 검증 (서명 확인 후에만 succeeded 처리)
      ├─ ai-jobs/             ← AI 작업 생성·상태 조회 (Replicate 호환 API)
      └─ delete-account/      ← 계정 탈퇴 (Storage 파일 + Auth 사용자 삭제)
```

---

## 1. 바로 실행하기 (Supabase 없이)

```bash
cd lumora-studio
python3 -m http.server 8080        # 또는 npx serve .
# 브라우저에서 http://localhost:8080 열기
```

- **로컬 모드**로 실행됩니다. 사진/영상 편집·카메라·내보내기·프리셋·관리자(로컬 샌드박스)가 모두 작동하고,
  회원·클라우드 프로젝트·결제는 비활성 상태로 명확히 표시됩니다.
- 카메라는 **HTTPS 또는 localhost**에서만 작동합니다(브라우저 정책). `file://`로 열면 카메라 화면에 안내가 나옵니다.
- 휴대폰에서 테스트하려면 Cloudflare Pages에 올리거나(HTTPS), `npx localtunnel`/`cloudflared tunnel` 등으로 HTTPS 주소를 만드세요.

## 2. Supabase 연결

1. supabase.com에서 프로젝트 생성
2. **SQL Editor**에서 `supabase/schema.sql` 실행 → `supabase/seed.sql` 실행 (둘 다 재실행 안전)
3. **Authentication → Providers**: Email 활성화(이메일 인증 ON 권장). Google/Apple은 키 등록 후 사용
4. **Authentication → URL Configuration**: Site URL과 Redirect URL에 배포 주소 추가 (예: `https://lumora.pages.dev`)
5. 앱에서 한 번 회원가입한 뒤, 최고 관리자 지정:
   ```sql
   insert into public.user_roles (user_id, role)
   select id, 'super_admin' from auth.users where email = 'you@example.com';
   ```
6. `index.html` 상단의 설정에 **공개 값만** 입력 (또는 앱의 설정 → 백엔드에서 입력):
   ```js
   window.LUMORA_CONFIG = { supabaseUrl: 'https://xxxx.supabase.co', supabaseAnonKey: 'eyJ...' };
   ```
   > `service_role` 키는 절대 넣지 마세요. 앱은 service_role 형태의 키 입력을 거부합니다.

## 3. Edge Functions 배포

```bash
supabase link --project-ref <ref>
supabase functions deploy create-checkout
supabase functions deploy payments-webhook --no-verify-jwt
supabase functions deploy ai-jobs
supabase functions deploy delete-account
supabase secrets set ALLOWED_ORIGINS=https://lumora.pages.dev
```

### 환경 변수 (Supabase Secrets — 브라우저에 노출되지 않음)

| 변수 | 용도 | 필수 |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | 함수 내부 서비스 클라이언트 (Supabase가 자동 주입) | 자동 |
| `ALLOWED_ORIGINS` | CORS 허용 도메인 (쉼표 구분) | 권장 |
| `PAYMENT_PROVIDER` | `stripe` (기본) | 선택 |
| `STRIPE_SECRET_KEY` | Stripe 서버 키 | live 결제 시 |
| `STRIPE_WEBHOOK_SECRET` | 웹훅 서명 검증 | live 결제 시 |
| `STRIPE_PRICE_PREMIUM_MONTH` / `_YEAR` | Premium 가격 ID | 구독 시 |
| `STRIPE_PRICE_AI_PREMIUM_MONTH` / `_YEAR` | AI Premium 가격 ID | 구독 시 |
| `ALLOW_TEST_UPGRADES` | `true`면 test 모드 구독이 요금제를 실제로 올림 (스테이징 전용) | 선택 |
| `AI_API_TOKEN` | AI 제공자 토큰 (Replicate 호환) | AI 사용 시 |
| `AI_API_BASE` | 기본 `https://api.replicate.com/v1` | 선택 |
| `AI_MODEL_<TASK>` | 작업별 모델 버전 (`AI_MODEL_REMOVE_BG`, `AI_MODEL_UPSCALE`, `AI_MODEL_WATERCOLOR` …) | AI 사용 시 |

### 결제 흐름
- 기본값은 `app_settings.payments_mode = "test"` → 결제가 발생하지 않고 `is_test=true` 행만 기록되며, 화면에 **TEST MODE**가 항상 표시됩니다.
- 실결제: Stripe 키·가격 ID·웹훅(`https://<ref>.supabase.co/functions/v1/payments-webhook`, 이벤트: `checkout.session.completed`, `invoice.paid`, `customer.subscription.updated`, `customer.subscription.deleted`, `charge.refunded`)을 등록한 뒤
  관리자 → 콘텐츠 → 요금제 & 설정에서 `payments_mode`를 `"live"`로 변경.
- 결제 성공·요금제 부여는 **웹훅 서명 검증 후 서버에서만** 기록됩니다. 클라이언트는 결제 테이블에 쓰기 권한이 없습니다(RLS).

### AI 흐름
- 관리자 설정에서 `ai_enabled`를 `true`로 바꾸기 전까지 AI 기능은 **비활성 + 연동 안내**로 표시됩니다. 결과를 흉내 내지 않습니다.
- 작업마다 `ai_jobs` 행(작업 ID, 상태, 파라미터, 결과 파일, 오류)이 생기고, AI Premium 월 크레딧을 서버에서 차감합니다(실패 시 환급).

## 4. Cloudflare Pages 배포
- 빌드 명령 없음, 출력 디렉터리 = `lumora-studio` 폴더 그대로 업로드(또는 Git 연결).
- `_headers` 파일이 카메라/마이크 권한 정책과 보안 헤더를 설정합니다.
- 새 버전 배포 시 `sw.js`의 `CACHE` 값을 올리면 사용자에게 "새 버전" 안내가 뜹니다.

---

## 5. 구현 범위

### 실제 작동 (브라우저만으로)
| 영역 | 내용 |
|---|---|
| 렌더 엔진 | WebGL2 단일 패스 셰이더: 노출·밝기·대비·하이라이트·섀도우·화이트·블랙·색온도·색조·채도·생동감·선명도·부분대비·디헤이즈·페이드·매트·그레인·비네팅, RGB 채널, 컬러 믹서, HSL 8밴드, 컬러 밸런스, 3-way 그레이딩(휠), 스플릿 토닝, 커브(RGB/R/G/B, 단조 3차 보간), 3D LUT(.cube), 블러·글로우·빛샘·렌즈 왜곡·RGB 분리·색수차·글리치·노이즈·스크래치·픽셀화·하프톤·디더링·아스키·듀오톤·팔레트 변환·포스터화·색상 반전·흑백·세피아·색상 이동, 로컬 스타일 필터(연필·유화·수채·셀·추상 — AI 아님) |
| 카메라 | 전/후면 전환, 권한 처리, 비율(3:4·9:16·1:1·16:9·전체), 실시간 프리셋 + EV/강도 다이얼, 타이머(3/10초), 그리드, 토치·하드웨어 줌(지원 기기), 디지털 줌(미지원 기기), 사진 촬영(필터 결과 + **필터 없는 원본 보관**), 동영상 녹화·일시정지·재개(필터 적용), 자동 품질 조절 |
| 사진 편집 | 다중 이미지, 드래그앤드롭, EXIF 확인, HEIC(지원 브라우저 또는 heic2any 지연 로드), 비파괴 편집(JSON 파라미터), Undo/Redo 80단계, 분할 비교·길게 눌러 원본, 핀치 줌, 자르기(비율 고정 핸들)·회전·반전·수평·원근, 프리셋 강도, 모든 이미지에 적용, 자동 저장, 원본 해상도 내보내기(JPEG/PNG/WebP/AVIF, 크기·품질 선택, 일괄 내보내기, 공유) |
| 영상 편집 | 메타데이터(길이·해상도·추정 fps·용량), 분할·삭제·복제·순서 변경(드래그/버튼)·트림 핸들·속도 ¼~4×, 사진과 동일한 프리셋/보정/효과, 화면 비율·회전, 페이드 인/아웃(영상+오디오), 타임라인 확대/축소, 내보내기(MP4 또는 WebM — 브라우저 지원 형식 자동 선택, 해상도·fps·품질·예상 용량·진행률·취소) |
| 이미지 변환 | 형식·크기 일괄 변환(기기 내 처리, EXIF 제거) |
| 프리셋 | 40개 실작동 프리셋(요구된 33개 + 로컬 스타일·렌즈·리소 7개), DB 조회·캐시, 검색·카테고리·무료/유료·정렬·즐겨찾기·최근 사용·무한 스크롤, 썸네일 자동 생성 |
| 관리자 | 대시보드, 프리셋 관리(검색·필터·정렬·페이지네이션·일괄 공개/비공개/카테고리/등급·JSON 가져오기/내보내기·복제·버전 기록·파라미터 실시간 미리보기·썸네일 업로드/렌더), 회원(검색·정지/해제·역할 — 최고 관리자만), 콘텐츠(배너·공지·카테고리·번역·요금제/설정), 매출 |
| 기타 | 한/영 다국어(번역 테이블로 덮어쓰기·언어 추가), 다크/라이트, PWA 설치·업데이트 안내·오프라인 셸, 모바일 하단 내비/데스크톱 전문 레이아웃 |

### 외부 연동이 있어야 작동 (구조는 완성, 키 필요)
- 회원가입·로그인·비밀번호 재설정·이메일 인증·Google/Apple 로그인 → Supabase Auth
- 클라우드 프로젝트 저장(서버 측 용량 제한 트리거 포함) → Supabase Storage
- 실결제·구독 → Stripe 키 + 웹훅
- AI 변환(일러스트·회화·수채·유화·스케치·애니·추상·배경 제거·확장·업스케일·객체 제거) → AI 제공자 토큰 + 모델 버전

### 이번 버전에서 제공하지 않음 (화면에 "사용 불가"로 표시)
- 얼굴 인식 기반 보정: 브라우저 내장 `FaceDetector`가 있을 때만 얼굴·눈 밝기 활성화(Chrome 일부 환경). 배경 블러·인물 분리·AI 뷰티는 모델 연동 필요(MediaPipe 등)
- 영상 역재생: 프레임 단위 디코딩(WebCodecs/FFmpeg.wasm) 확장 필요
- 멀티트랙 편집, 서버 측 영상 렌더링
- 영상 내보내기는 브라우저 인코더로 **실시간** 렌더링합니다. 저사양 기기에서 무거운 효과를 쓰면 프레임이 빠질 수 있으며(경고 표시), 프레임 단위 오프라인 인코딩은 FFmpeg.wasm/WebCodecs 확장으로 해결할 예정입니다.

---

## 6. 검증 결과

| 항목 | 상태 | 검증 방법 |
|---|---|---|
| 카메라 권한 요청·실시간 필터·사진 촬영·동영상 녹화 | ✅ | Headless Chromium + 가짜 카메라 장치 |
| 사진 불러오기·보정(노출 변화 픽셀 측정)·Undo·자르기 1:1·내보내기 다운로드 | ✅ | Headless Chromium (모바일 390px / 데스크톱 1440px) |
| 프리셋 적용 시 이미지 변화 / 촬영 → 스튜디오에서 프리셋 유지 | ✅ | 동일 |
| 영상 불러오기·분할·속도·내보내기(영상+오디오 트랙 확인: ffprobe) | ✅ | 동일 (WebM VP9 입력). 첫 내보내기에서 영상 트랙이 빠지던 문제를 트랙 워밍업 + `requestFrame`으로 수정, 반복 실행으로 확인. 렌더링 비율이 60% 미만이면 경고 표시 |
| 프로젝트 자동 저장·다시 열기, 관리자 프리셋 편집 → 버전 증가 | ✅ | 동일 (로컬 모드) |
| schema.sql / seed.sql 적용 및 재실행 | ✅ | PostgreSQL 16 + Supabase auth/storage 스텁 |
| RLS 19개 시나리오 (익명/일반/정지/편집자/관리자/최고관리자, 결제 쓰기 차단, 요금제 자가 변경 차단, 타인 폴더 업로드 차단, 용량 초과 차단 등) | ✅ | 동일 |
| Edge Functions 4종 타입 검사 | ✅ | `deno check` |
| **실제 iOS Safari / Android Chrome 기기** | ⚠️ 미검증 | 실제 기기 테스트 필요 (특히 iOS의 MP4 녹화, 토치, HEIC) |
| **실제 Supabase 프로젝트와의 Auth·Storage·함수 통신** | ⚠️ 미검증 | 스키마/RLS는 검증했으나 라이브 프로젝트 연결은 미검증 |
| **Stripe 실결제·웹훅 / AI 제공자 호출** | ⚠️ 미검증 | 키가 없어 호출하지 않음 |

참고: 테스트 환경의 Chromium에는 H.264 디코더가 없어 MP4(H.264) 입력은 열리지 않았습니다(코덱 오류 안내가 정상 표시됨). 일반 Chrome/Safari는 H.264를 지원합니다.

## 7. 데이터베이스 (17 테이블)
`profiles` · `user_roles` · `presets` · `preset_categories` · `preset_favorites` · `projects` · `project_media` · `subscriptions` · `donations` · `payment_transactions` · `banners` · `announcements` · `usage_logs` · `ai_jobs` · `app_settings` · `translations` + `preset_versions`(프리셋 버전 기록)

- 프리셋 수정 시 파라미터가 바뀌면 `version`이 올라가고 `preset_versions`에 이전 값이 남습니다.
- 사용자 프로젝트는 적용 당시의 **해석된 파라미터 전체를 스냅샷**으로 저장하므로, 프리셋이 수정·삭제되어도 기존 프로젝트는 그대로 열립니다.
- 관리자 작업은 `usage_logs`에 `admin.*` 이벤트로 기록됩니다(일반 사용자는 `admin.*` 기록 불가).

## 8. 프리셋 파라미터 형식
```json
{ "exposure": 0.1, "contrast": 18, "temperature": 25,
  "grading": { "shadows": { "h": 190, "s": 55, "l": -4 }, "high": { "h": 32, "s": 45, "l": 0 } },
  "hsl": { "orange": [4, 10, 5], "blue": [-15, 10, -10] },
  "curves": { "master": [[0,0.04],[0.25,0.22],[0.75,0.8],[1,0.97]] },
  "fx": { "grain": 0, "glow": 20, "halftone": 0, "palette": "pico", "paletteAmt": 60 },
  "stylize": { "mode": "watercolor", "amount": 100 } }
```
기본값과 다른 값만 넣으면 됩니다. 범위는 대부분 -100~100(노출은 -3~3 EV). 관리자 편집기에서 "현재 편집기 값 사용"을 누르면 사진 편집기에서 만든 룩을 그대로 프리셋으로 저장할 수 있습니다.

## 9. 다음 단계 제안
1. 실제 기기(iOS/Android) QA 및 Supabase 스테이징 연결
2. FFmpeg.wasm/WebCodecs로 오프라인 영상 인코딩(실시간 제약 해소, 역재생)
3. MediaPipe Selfie Segmentation / Face Landmarker로 인물 보정 활성화
4. 일본어·중국어·스페인어·프랑스어 번역 JSON 등록 (관리자 → 번역 → JSON 가져오기)
