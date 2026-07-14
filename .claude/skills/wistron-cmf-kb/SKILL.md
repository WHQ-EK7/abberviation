---
name: wistron-cmf-kb
description: 維護與擴充 Wistron Server Knowledge 知識庫網站（縮寫查詢 / 組階說明 / CMF 總表），並管理其 CMF（Color-Material-Finish）資料：材質、顏色、色號 PN、加工工法、表面處理、供應商、Lab/Gloss 量測值。只要使用者提到 CMF 總表、色號、Wstron Color_PN、ACS-S 色號、Lab 值、ΔE、色差、供應商、工法、表面處理、噴粉、陽極、Pad Print、或要新增/匯入/清洗/驗證 CMF 資料、要改這個知識庫網站、要建後台資料庫（Supabase/Postgres），就一定要使用這個 Skill——即使他們沒有明確說「CMF」或「Skill」。這個 Skill 內含正規化 schema、欄位字典、資料清洗規則與 UI 契約，可避免把既有前端改壞。
---

# Wistron CMF Knowledge Base

這個 Skill 管的是一個**單檔 HTML 前端 + 扁平資料列**的知識庫（部署在 GitHub Pages）。它有三個頁籤：

| 頁籤 | 資料來源 | 狀態 |
|---|---|---|
| 縮寫查詢 | `ABBR_DATA`（JS 物件，可上傳 Excel 覆蓋） | 穩定 |
| 組階說明 (L1–L12) | 靜態圖 `levels.png` | 穩定 |
| CMF 總表 | `CMF_DEFAULT`（92 筆扁平 JSON，可上傳 Excel/CSV 覆蓋） | **需要 schema 治理** |

核心原則：**UI 不動，資料變乾淨。** 前端的視覺、配色（Wistron 紫 `#702082`）、版面、互動邏輯都是使用者定案的，不要重新設計。所有改進都應該從資料層（schema、驗證、正規化、後台 DB）進來，前端只做最小必要的修補。

---

## 開始前先判斷任務類型

| 使用者想做的事 | 先讀哪個檔 |
|---|---|
| 新增／修改／匯入 CMF 資料、問某個欄位該填什麼 | `references/cmf-schema.md` |
| 清洗現有 92 筆髒資料、統一工法名稱、修 Lab 值 | `references/cmf-schema.md` + `scripts/normalize_cmf.py` |
| 改前端（加欄位、加篩選、修 bug） | `references/ui-contract.md` |
| 建後台資料庫（Supabase / Postgres / NocoDB） | `references/database.md` + `assets/schema.sql` |
| 驗證一份 Excel 能不能匯入 | 直接跑 `scripts/validate_cmf.py` |

---

## CMF 資料的三層模型

前端吃的是**扁平列**（一列 = 一倌「品牌 × 材質 × 工法 × 顏色」的組合）。但底層真實世界是**多對多**的：同一個色號會跨多個專案、多個材質、多個供應商。所以：

```
Level 1  扁平列 (flat row)      ← 前端 CMF_DEFAULT / Excel 匯入匯出，維持不變
Level 2  正規化 schema           ← 驗證、去重、統一命名的依據
Level 3  關聯式 DB (Postgres)    ← 後台，用 VIEW 攤平回 Level 1 餵給前端
```

**關鍵設計：後台 DB 一定要提供一個 `v_cmf_flat` VIEW，欄位名與現有前端完全一致。** 這樣前端一行都不用改，只要把 `CMF_DEFAULT` 換成 `fetch()` 就能接上後台。細節在 `references/database.md`。

---

## 已知的資料問題（每次處理資料都要檢查）

這些是從現有 92 筆資料裡**實際跑驗證器挖出來的**，不是假設。碰到 CMF 資料先檢查這幾項。

### 1. ⭐ `Manufacturing Methods` 一欄裝了兩種東西 —— 這是最根本的問題

同一欄裡，有時候放的是**成型工法**（Injection Molding、Stamping、Die-Casting、Extrusion+CNC），有時候放的是**表面處理**（Powder Coating、Anodizing、Pad Print）。

而且 Naomi 那批資料是「成型工法在欄位、表面處理埋在 Remark」：

| Wstron Color_PN | Manufacturing Methods | Remark | 真正的表面處理 |
|---|---|---|---|
| `ACS-S3008E` | Stamping | `1.PVD2.Handle` | **PVD** |
| `ACS-S8240E` | Extrusion+CNC | `1.Anodize2.Handle` | **Anodize** |
| `ACS-S0376PE-2` | Stamping | `1.Powder coating` | **Powder Coating** |

**後果**：無法回答「所有做陽楶的件有哪些」——因為陽極這個資訊，一半在工法欄、一半在備註欄。

→ Canonical schema 拆成 **`forming_process`（成型）** 與 **`finish_process`（表面處理）** 兩個獨立欄位。色號後綴（`PE`/`E`/`T`/`P`）對照的是 **`finish_process`，不是 forming**。`scripts/normalize_cmf.py` 會自動判斷欄位裝放的是哪一種，並從 Remark 把表面處理挖出來。

### 2. `WZS_b` 掉進了 `WZS_E`
例：CISCO Slate Blue 的 `WZS_B` 是空的、`WZS_E` 是 `-27.97`。**ΔE 依定義 ≥ 0，不可能為負。**
→ 規則：若 `*_E < 0` 且對應的 `*_b` 為空，判定為欄位錯位，把值搬回 `b`，`E` 清空。`scripts/normalize_cmf.py` 會自動修並列出清單。

### 3. 工法名稱大小寫／同義詞不統一
`Powder coating` / `Powder Coating` / `Powder Painting` / `Black Powder Painting` 是同一件事；`Anodized` / `Anodizing` / `Black Anodized (黑色陽極)` 也是。
→ 用 `assets/cmf_schema.json` 的別名表對映到 canonical 值，顏色修飾（Black / Silver / Light Gray）抽到 `finish_note`，不要丟掉。

### 4. 多值欄位塞在單一儲存格 —— **但不能無腦切**

| 欄位 | 分隔符 | 陷阱 |
|---|---|---|
| `Project` | `,` `;` `/` | **`M7 1U/2U` 的 `/2U` 是尺寸不是專案**，切完要把 `^\d+U$` 碎片黏回去 |
| `Material SPEC` | 只切 `,` | **`PC/ABS`、`PC+ABS` 是單一材料**，切 `/` 會拆壞 |
| `OEM Vendor` | `/` `,` | `UNEEC/Chenbro/Amtek` 確實是三家廠，這裡 `/` 一律當分隔 |

三個欄位規則不同，寫在 `cmf_schema.json` 的 `multi_value_fields`。**Level 1 匯出時再接回字串**，前端顯示不變。

### 5. `Wstron Color_PN` 的後綴可以拿來反查資料錯誤
格式：`ACS-S{4碼色系流水號}{後綴}[-變體]`，例：`ACS-S8233PE-02`。
後綴：`PE` = 噴粉/噴漆、`E` = 陽極/PVD、`T` = 液態塗裝、`P` = 印刷、`ED` = 電著、無後綴 = 原料本色。

**後綴必須和 `finish_process` 一致**（不是 forming！見第 1 點）。驗證器實測抓到的真實錯誤：

> Pegasus 專案陽極件，一筆寫 `ACS-S8209E`（正確），另一筆寫 `ACS-S8209PE`（PE 是噴粉後綴，但工法是 Anodized）。**同一個件的色號打錯了。**

`Material Supplier` 也有沒法自動拆的髒資料，例：`SABIC C6200/WAM NC85`（一格塞兩家廠 + 兩個牌號）。腳本會標記 `[需人工]`，不會亂猜。

---

## 新增一筆 CMF 資料的流程

不要直接把使用者給的欄位塞進 JSON。照這個順序：

1. **問清最小必要欄位**（缺這些就不該入庫）：
   `customer`（客戶代號）、`material`、`forming_process`、`material_spec`、`wistron_color_pn`（或 `customer_color_pn`）、`project`。
2. **正規化**：判斷工法是 forming 還是 finish（見第 1 點）、`material_spec` 轉大寫（`SGCC`、`AL6063 T5`）、`project` 切成陣列。
3. **驗證**：
   - HEX 必須是 `#RRGGBB`（6 碼，大寫）。
   - Lab：`L ∈ [0,100]`、`a,b ∈ [-128,127]`、`ΔE ≥ 0`。
   - Gloss 可以是數值或範圍字串（`5±1`、`7~13`、`9~15`）——保留原字串，另存 `gloss_min` / `gloss_max`。
   - 色號後綴 vs 工法一致性（見上方第 5 點）。
4. **HEX 與 Lab 交叉檢查**：若兩者都有，用 `scripts/validate_cmf.py --check-hex` 把 Lab 轉 sRGB，ΔE > 10 就警告（很多既有 HEX 是人工目測填的，不準）。
5. 寫入時**同時更新 `CMF_DEFAULT`（前端）與 DB seed**，兩邊不能只改一邊。

---

## 修改前端時的鐵則

完整清單在 `references/ui-contract.md`，但這幾條先記住：

- **不要改配色、字體、圓角、間距、版面。** 這是定案的設計。
- **不要移除或改名任何 `id`**（`cmf-f-brand`、`cmf-search`、`cmf-detail-body`…），JS 全靠它們。
- 要在總表加欄位 → 只改 `CMF_DISPLAY_COLS` 陣列，不要動 `renderCmfTable()` 的其他部分。
- 要在詳細視窗加欄位 → 加進 `openCmfDetail()` 的 `usedKeys` 集合，否則會在「其他資訊」重複出現一次。
- **`localStorage` 在此專案可用**（它是自架 GitHub Pages，不是 Claude Artifact），但目前程式碼沒用，改資料重整就消失——這正是需要後台的原因。

### 現有前端已知 bug（可以修，屬於必要修補，不算改 UI）

- `cmf-edit-modal` 這個 `id` 出現**兩次**（一個含儲存按鈕、一個綠色標題版本）。`getElementById` 只會拿到第一個，第二個是死代碼。→ 刪掉第二個。
- `.main` 的 `max-width: 100％` 用了**全形百分號**，CSS 無效。→ 改成 `100%`。
- 上傳 Excel 的 drag & drop 用 `Object.assign(new Event('change'), {target:{files:[file]}})` 偽造事件，實際上 `target` 是唯讀的，這條路徑不會生效。→ 改成直接抽出解析函式來呼叫。

---

## 修正資料時：建檔，不要手改

發現資料錯誤時，**不要直接編輯 `CMF_DEFAULT` 或 Excel**。把修正寫進 `assets/corrections.json`，`normalize_cmf.py` 會在正規化前套用並記進報告。

```json
{
  "id": "C001",
  "match": {"Brand": "Cindy", "Project": "Pegasus", "Wstron Color_PN": "ACS-S8209PE"},
  "set":   {"Wstron Color_PN": "ACS-S8209E"},
  "reason": "陽極的後綴應為 E 不是 PE；同專案列 81 就是 ACS-S8209E",
  "confirmed_by": "user",
  "date": "2026-07-14"
}
```

這樣做的理由：CMF 資料會被拿去跟供應商對帳、跟客戶對色。當有人問「為什麼系統裡的色號跟三年前的 Excel 不一樣」，你要答得出來是誰、什麼時候、為什麼改的。手改資料答不出來。

`match` 是多欄位比對（不是列號——列號會因為排序或新增而失效）。`merges` 區塊記錄待合併的重複列，狀態為 `pending` 時腳本不會動它。

**修正必須有 `confirmed_by`。** 沒有人確認過的東西不要放進 corrections，放進報告的「需人工決策」就好。

---

## 快速指令

```bash
# 驗證一份 CMF Excel/CSV/JSON，輸出錯誤與警告報告
python scripts/validate_cmf.py <檔案路徑>

# 清洗 + 正規化（修 Lab 錯位、統一工法、拆多值欄位），輸出 canonical JSON
python scripts/normalize_cmf.py <輸入檔> -o cmf_clean.json --report report.md

# 產生後台 DB 的 seed SQL
python scripts/normalize_cmf.py <輸入檔> --emit-sql seed.sql
```

腳本只依賴 `pandas` + `openpyxl`，沒有的話 `pip install pandas openpyxl --break-system-packages`。

---

## 檔案地圖

- `references/cmf-schema.md` — 欄位字典、enum 清單、舊欄位 → 新欄位對照、色號編碼規則
- `references/ui-contract.md` — 前端結構、可改／不可改清單、如何安全加欄位
- `references/database.md` — Postgres 正規化 schema、`v_cmf_flat` VIEW、前端接後台的最小改動
- `assets/cmf_schema.json` — 機器可讀 schema（驗證器與腳本共用的單一真相來源）
- `assets/corrections.json` — 人工確認過的資料修正（有 reason + confirmed_by，可追溯）
- `assets/schema.sql` — 可直接貽進 Supabase SQL Editor 的建表語法
- `scripts/validate_cmf.py`、`scripts/normalize_cmf.py`
