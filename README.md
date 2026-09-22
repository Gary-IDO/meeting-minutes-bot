# 會議紀錄機器人（iOS）

按一下開始錄音，會議結束按停止，App 會：

1. 在 **手機上** 把語音即時轉成逐字稿（Apple Speech framework，不上傳錄音）。
2. 把逐字稿送給 **Claude（claude-opus-5）**，產出正式的繁體中文會議紀錄：摘要、討論要點、決議、待辦事項（負責人／期限）、待釐清問題。
3. 保存錄音檔（.m4a）、逐字稿與會議紀錄，可用「分享」匯出到 LINE、Mail、備忘錄、Notion 等。

---

## 先回答最重要的問題：我只有 Windows，能自己把它裝進 iPhone 嗎？

**可以，但要先知道兩個限制。**

| 項目 | 說明 |
|---|---|
| 沒有 Mac 怎麼編譯？ | 用 **GitHub Actions** 的 macOS 執行器編譯（公開 repo 免費）。這個專案已附好自動建置腳本，push 上去就會產出 IPA 檔。 |
| 沒有 Mac 怎麼裝進手機？ | 在 Windows 上用 **Sideloadly**（免費）以你的 Apple ID 簽章並透過 USB 安裝。 |
| 免費 Apple ID 的限制 | App **7 天過期**，需重新簽章（Sideloadly 可在電腦開機、手機同 Wi‑Fi 時自動更新）。同時最多 3 個側載 App、每 7 天最多註冊 10 個 App ID。 |
| 想免除 7 天限制 | 加入 **Apple Developer Program（US$99／年）**，Sideloadly 簽章後可用 **1 年**，也解除 3 個 App 限制。 |
| iOS 版本／機型 | **iPhone 12 以上 + iOS 26** 效果最好：完全裝置端辨識，中文（台灣）支援，沒有時間限制。iOS 17／18 或 iPhone 11／SE2 也能用，但中文（台灣）會改走 Apple 伺服器辨識（需網路、每 55 秒分段，準確度略低）。 |

**這不是 App Store 上架**。那需要付費開發者帳號與審核；這裡的做法是「自己用的 App」。

---

## 你需要準備

- iPhone（建議 iPhone 12 以上、iOS 26 以上）與傳輸線
- Windows 10／11 電腦
- 一個 GitHub 帳號（免費）
- 一個 Apple ID（建議另外開一個專門用來簽章，需開啟雙重認證）
- **Anthropic API 金鑰**：到 <https://console.anthropic.com/> → API Keys 建立。費用見下方「費用估算」。

---

## 步驟 A：把程式碼放上 GitHub，讓它自動產出 IPA

1. 在 GitHub 建立一個 **Public** 新 repo（例如 `meeting-minutes-bot`）。公開 repo 使用 macOS 執行器免費；私有 repo 每月只有約 200 分鐘 macOS 額度，一次建置約用 8～12 分鐘。程式碼裡沒有任何金鑰（金鑰是在 App 內輸入、存在手機 Keychain），公開無妨。
2. 在 Windows 這台電腦打開終端機，進入本專案資料夾後執行（把網址換成你的 repo）：

```bash
cd "D:\###ClaudeCode\MeetingMinutesBot"
```

```bash
git init -b main
```

```bash
git add . && git commit -m "Meeting minutes bot iOS app"
```

```bash
git remote add origin https://github.com/<你的帳號>/meeting-minutes-bot.git && git push -u origin main
```

3. 到 GitHub repo 的 **Actions** 分頁，會看到「Build unsigned IPA」正在跑（約 8～12 分鐘）。
4. 跑完後點進該次執行，最下方 **Artifacts** 有 `MeetingMinutesBot-unsigned-ipa`。下載後是一個 zip，**解壓縮**得到 `MeetingMinutesBot-unsigned.ipa`。
   - 或者推一個版本 tag，Actions 會直接建立 GitHub Release 並附上 .ipa（不用再解壓）：

```bash
git tag v1.0.0 && git push origin v1.0.0
```

> 如果 Actions 失敗，點開紅色的步驟看錯誤訊息，把整段貼回來給我即可修正。

---

## 步驟 B：在 Windows 用 Sideloadly 安裝到 iPhone

1. **移除 Microsoft Store 版的 iTunes 與 iCloud**（若有）。Sideloadly 需要 Apple 官網版：
   - iTunes（64 位元）：<https://www.apple.com/itunes/download/win64>
   - iCloud for Windows：<https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe>
2. 下載安裝 **Sideloadly**：<https://sideloadly.io>
3. iPhone 解鎖、用線接上電腦，手機上點「信任這部電腦」，確認 iTunes 看得到手機。
4. 打開 Sideloadly：
   - 把 `MeetingMinutesBot-unsigned.ipa` 拖進去
   - 選你的 iPhone
   - 輸入 Apple ID（Email）
   - 勾選 **自動更新／Automatic refreshing**
   - 按 **Start**，輸入 Apple ID 密碼與手機收到的 6 位數雙重認證碼（免費 Apple ID **不能**用 App 專用密碼，要用正常密碼）
5. 安裝完成後，到 iPhone：
   - **設定 → 隱私權與安全性 → 開發者模式** → 開啟 → 重新開機 → 開機後「啟用」（這個選項要裝過開發者簽章的 App 後才會出現）
   - **設定 → 一般 → VPN 與裝置管理** → 點你的 Apple ID → **信任**（需要網路）
6. 打開 App，允許 **麥克風**（與可能出現的 **語音辨識**）權限。

**7 天後 App 打不開？** 讓電腦開著 Sideloadly、手機和電腦在同一個 Wi‑Fi（iTunes 裡對該裝置勾選「透過 Wi‑Fi 與此 iPhone 同步」），Sideloadly 會在到期前自動重新簽章。過期了就用同一個 Apple ID 再側載一次同一個 IPA，資料會保留。

**之後要更新 App**：改程式 → push → Actions 產出新 IPA → 再用 Sideloadly 同一個 Apple ID 安裝，會直接覆蓋，資料保留。

---

## 步驟 C：第一次使用

1. 打開 App → 右上角 ⚙ **設定** → 貼上 Anthropic API 金鑰 → **儲存金鑰** → **測試連線**。
2. 確認「辨識語言」是 **中文（台灣）**、「錄音結束後自動產生會議紀錄」已開。
3. 回到主畫面按 **開始錄音**。第一次會下載中文（台灣）語音模型（需要網路，約數十秒到數分鐘，之後離線可用）。
4. 會議中可鎖定螢幕，錄音與辨識會在背景繼續。畫面上會即時顯示逐字稿（灰字是暫定、黑字是已確定）。
5. 按 **停止並產生紀錄** → 自動送 Claude → 幾十秒後會議紀錄以串流方式出現。
6. 右上角 **分享** 可匯出「會議紀錄 + 逐字稿」文字。錄音檔在「檔案」App → 我的 iPhone → 會議紀錄機器人 → Recordings。

---

## 費用：什麼免費、什麼要錢

**App 本身、編譯、安裝、語音辨識全部免費。** 唯一要錢的是「請 Claude 把逐字稿寫成會議紀錄」這一步，因為那是跑在 Anthropic 伺服器上、按用量計費。

| 項目 | 費用 |
|---|---|
| App 程式、GitHub Actions 編譯、Sideloadly | 免費 |
| 語音轉文字 | 免費（在你手機上跑，不連網也能用） |
| Claude 產生會議紀錄 | 依用量計費，見下表 |
| Apple Developer Program（選用，免除 7 天重簽） | US$99／年 |

一小時中文會議（逐字稿約 1.5 萬字）的粗估費用，可在 App 的「設定 → 摘要模型與費用」隨時切換：

| 模型 | 思考深度 | 每場約 |
|---|---|---|
| Claude Opus 5 | 品質優先 | NT$9.5 |
| Claude Opus 5 | 省錢 | NT$6.3 |
| Claude Sonnet 5 | 品質優先 | NT$3.8 |
| Claude Haiku 4.5 | 不適用 | NT$1.3 |

**注意：Claude 的 Pro／Team 訂閱方案不包含 API 用量，兩者分開計費、不能折抵。** API 金鑰要另外到 <https://console.anthropic.com/> 申請，並可在那裡設定每月用量上限。

### 完全不想付 API 費用：內建「零成本模式」

到 **設定 → 會議紀錄怎麼產生 → 手動貼到 Claude App（零成本）**，App 就不會呼叫 API，也不需要金鑰。錄音結束後在會議頁面按三個按鈕：

1. **① 複製逐字稿與指示** — 把逐字稿加上寫紀錄的指示複製到剪貼簿。
2. **② 開啟 Claude** — 貼上、送出，讓 Claude 產生會議紀錄。這會用掉你 Claude 帳號本身的額度（免費或 Pro 方案），但不會產生任何 API 費用。
3. **③ 從剪貼簿貼上會議紀錄** — 把 Claude 的回覆複製後貼回 App 保存，之後跟自動模式一樣可以瀏覽、分享、匯出。

代價是每場會議多按幾下、多切換一次 App。用 API 自動模式則是全自動但每場幾塊台幣。兩種模式可以隨時切換，同一場會議也能先試零成本、之後再改用 API 重新產生。

---

## 常見問題

| 狀況 | 原因與處理 |
|---|---|
| Sideloadly 看不到裝置、`AFC_E_MUX_ERROR` | 裝到 Microsoft Store 版 iTunes，或電腦未被信任。改裝官網版 iTunes + iCloud、重開機、重新信任。 |
| `Failed to obtain anisette: 500` | Sideloadly 伺服器暫時異常，稍後再試，或在 Advanced Options 改用 Local Anisette。 |
| `maximum App ID limit… 10 App IDs every 7 days` | 免費帳號一週只能註冊 10 個 App ID。等幾天，或換一個 Apple ID。**不要一直改 bundle ID**。 |
| `maximum number of installed apps using a free developer profile` | 免費帳號同時最多 3 個側載 App，先刪一個。 |
| 開發者模式選項沒出現 | 要先裝過一個開發者簽章 App；重開機再看。 |
| App 一開就閃退 | 通常是 Info.plist 缺權限字串或用了免費帳號不能有的功能（本專案沒用）。把 Actions 的建置 log 貼給我。 |
| 逐字稿是空的 | 檢查麥克風權限；iOS 17／18 上請確認網路（走 Apple 伺服器）；iOS 26 第一次需下載語音模型。 |
| 辨識引擎顯示「SFSpeechRecognizer」而不是「SpeechAnalyzer」 | 機型是 iPhone 11／SE2 或系統低於 iOS 26。仍可用，但需網路、每 55 秒分段。 |
| 摘要失敗顯示 401 | API 金鑰錯誤或已停用。 |
| 摘要失敗顯示 429 | 超過 API 速率上限，稍後重試（詳情頁有「重新產生」）。 |
| iOS 大版本更新後裝不上 | 側載工具常在新 iOS 剛出時失效。更新 iOS 前先看 <https://sideloadly.io/changelog.html>。 |

---

## 不想側載？零程式的替代方案

iPhone 12 以上、iOS 18 以上、系統語言設為繁體中文時，內建的 **語音備忘錄** 與 **備忘錄（錄音）** 本身就會在裝置端產生繁體中文逐字稿：

1. 用語音備忘錄錄會議 → 錄音項目 → … → **拷貝逐字稿**。
2. 建一個 **捷徑**：「取得 URL 內容」→ POST `https://api.anthropic.com/v1/messages`，標頭 `x-api-key`、`anthropic-version: 2023-06-01`、`content-type: application/json`，JSON 內容用本專案 `SummaryPrompt.swift` 裡的提示詞，把剪貼簿文字當 user 訊息 → 「取得字典值」`content.0.text` → 「建立備忘錄」。

缺點：要手動複製貼上、沒有一鍵流程、沒有會議清單管理。但完全不需要電腦。

**最省的做法（零成本）**：用語音備忘錄錄音 → 拷貝逐字稿 → 貼到你原本就在用的 Claude 對話視窗，請它照 `SummaryPrompt.swift` 的格式整理。這走的是訂閱方案額度，不另外付 API 費用，缺點是每場會議都要手動來一次。

---

## 專案結構

```
MeetingMinutesBot/
├─ project.yml                         XcodeGen 專案描述（bundle id、權限、背景模式）
├─ .github/workflows/build-ipa.yml     GitHub Actions：產出未簽章 IPA
└─ MeetingMinutesBot/
   ├─ App/            進入點、使用者設定（UserDefaults）
   ├─ Models/         Meeting 資料模型、MeetingStore（Documents/meetings.json + Recordings/）
   ├─ Prompts/        SummaryPrompt：繁體中文會議紀錄提示詞
   ├─ Services/
   │  ├─ RecordingSession.swift            麥克風 → 錄音檔 + 逐字稿引擎；中斷／路由變更處理
   │  ├─ Transcription/
   │  │  ├─ TranscriptionEngine.swift      引擎介面、BufferConverter、音量表
   │  │  ├─ AnalyzerTranscriptionEngine    iOS 26 SpeechAnalyzer + SpeechTranscriber（裝置端）
   │  │  └─ LegacyTranscriptionEngine      iOS 17/18 SFSpeechRecognizer（每 55 秒分段）
   │  ├─ ClaudeSummaryService.swift        Claude Messages API（SSE 串流、fallbacks、refusal 處理）
   │  ├─ SummaryRunner.swift               背景摘要工作管理
   │  └─ KeychainStore.swift               API 金鑰存 Keychain
   └─ Views/          清單、錄音、詳情、設定、Markdown 顯示
```

### 技術重點

- **語音辨識**：iOS 26 以上用 `SpeechAnalyzer` + `SpeechTranscriber(locale: zh_TW)`，完全裝置端、無時長限制；模型由系統下載管理。iOS 17／18 或舊機型退回 `SFSpeechRecognizer`，因 Apple 伺服器單次請求上限一分鐘，每 55 秒換新請求並串接。
- **錄音**：`AVAudioEngine` 單一 tap 同時寫 `.m4a`（AAC 64 kbps，約 28 MB／小時）與餵給辨識引擎；`UIBackgroundModes: audio` 讓鎖屏後繼續。每 15 秒把逐字稿草稿寫入磁碟，App 被殺掉時啟動會自動復原。
- **摘要**：直接呼叫 `POST https://api.anthropic.com/v1/messages`（Swift 無官方 SDK），`stream: true`、`thinking: adaptive`、`effort: high`、`fallbacks: "default"`（安全分類器拒答時伺服器端自動改用替代模型），並處理 `stop_reason == "refusal"`。
- **安全**：API 金鑰只存 iOS Keychain，只送往 `api.anthropic.com`。錄音與逐字稿只存在手機。

### 已知限制

- 免費 Apple ID 每 7 天需重新簽章（見上）。
- 沒有講者分離（誰說了什麼），Claude 會盡量從內容推斷。
- 中文（台灣）在 iOS 17／18 需網路且分段辨識，段落交界處偶有斷詞。
- 錄音檔（.m4a）是在「停止」時才寫入索引；若 App 在錄音途中被系統強制終止，逐字稿草稿（每 15 秒存一次）會保留並自動復原成會議，但該場的 .m4a 可能無法播放。若這對你很重要，可改用 AVAssetWriter 分段寫入，之後再加。
- 建議會議中不要戴藍牙耳機當麥克風：App 固定用 iPhone 內建麥克風收整個房間的聲音。
- 未在實機驗證前，第一次建置可能有需要修正的編譯錯誤；把 Actions 的錯誤訊息貼回來即可。
