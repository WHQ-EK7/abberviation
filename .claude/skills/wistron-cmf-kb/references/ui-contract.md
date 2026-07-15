# 前端 UI 契約

單一檔案 `index.html`，無建置流程，直接 GitHub Pages 部署。唯一外部依賴：`xlsx.full.min.js`（cdnjs 0.18.5）。

**這份文件的目的：讓 Claude 在改動時不要把使用者定案的設計改壞。**

---

## 1. 不可更動（設計已定案）

| 項目 | 值 |
|---|---|
| 主色 | `#1a1a1a`（縮寫頁）、`#702082` Wistron 紫（CMF 頁）|
| 背景 | `#f5f5f3` |
| 卡片 | `#fff`、`border-radius: 10–14px`、`border: 0.5px solid rgba(0,0,0,0.1)` |
| 字體 | `-apple-system, BlinkMacSystemFont, "Segoe UI", ...` |
| 表頭 | 紫底白字、`position: sticky` |
| 斑馬紋 | 偶數列 `#fdf9ff`、hover `#f0e6f5` |

不要引入 Tailwind、不要換 CSS 框架、不要改成多檔案、不要加 build step。這是刻意的單檔設計，方便直接丟 GitHub Pages。

## 2. 不可改名的 DOM id / 函式名

JS 全靠 `getElementById`，改名即壞。

**id：**
`abbr-view` `level-view` `cmf-view` `abbr-actions` `cmf-actions` `abbr-file-input` `cmf-file-input` `search` `clear-btn` `cat-grid` `results` `add-modal` `add-cat` `add-newcat` `add-abbr` `add-full` `add-zh` `cmf-filters` `cmf-f-brand` `cmf-f-material` `cmf-f-project` `cmf-search` `cmf-summary` `cmf-summary-text` `cmf-content` `cmf-detail-modal` `cmf-detail-body` `cmf-edit-modal` `cmf-edit-body` `cmf-export-btn` `drop-overlay` `toast` `level-img-error`

**全域函式（inline `onclick` 依賴）：**
`switchView` `openAddModal` `closeAddModal` `submitAdd` `toggleAbbr`
`cmfApplyFilters` `cmfReset` `cmfExport` `openCmfDetail` `openCmfEdit` `closeCmfEdit` `saveCmfEdit` `closeCmfDetail` `deleteCmfRow` `updateColorSwatch`

**全域資料：**
`ABBR_DATA`、`CMF_DEFAULT`、`cmfAllData`、`cmfFiltered`、`CMF_DISPLAY_COLS`、`CMF_EDIT_FIELDS`

---

## 3. 安全的擴充方式

### 在總表加一欄
只改陣列，不動 `renderCmfTable()`：
```js
const CMF_DISPLAY_COLS = ['Brand','Material','Project','Customer Color Name_PN',
  'Wstron Color_PN','Manufacturing Methods','Material SPEC/Apply to.',
  'OEM Vendor','Material Supplier',
  'Surface Finishing'];   // ← 只加這行
```
表格 `min-width: 1100px` 可能要跟著加大。色塊 highlight 只綁在 `Wstron Color_PN`（用 `Wstron Color HEX` 算亮度決定黑字白字）——要讓別欄也上色，複製那段亮度判斷邏輯，不要改寫。

### 在詳細視窗加一欄
1. 在 `openCmfDetail()` 的主表加 `html += '<tr><th>...</th><td>' + g('欄位') + '</td></tr>'`
2. **同時把欄位名加進 `usedKeys` 集合**——否則它會在下方「其他資訊」再出現一次。這是最容易漏掉的一步。

### 加篩選器
複製一個 `.cmf-filter-group`，加 `<select id="cmf-f-xxx">`，然後：
- `cmfPopulateFilters()` 加一個 `Set` 與 `cmfFillSelect` 呼叫
- `cmfApplyFilters()` 加一條 `&&` 條件
- `cmfReset()` 清空它

### 加編輯欄位
加進 `CMF_EDIT_FIELDS` 即可，`openCmfEdit()` 會自動生表單（它用 `new Set([...CMF_EDIT_FIELDS, ...Object.keys(row)])`，所以資料裡有的欄位就算不在清單也會出現）。

---

## 4. 必要的 bug 修補（不算改設計）

### 4.1 重複的 `cmf-edit-modal`
HTML 裡有兩個 `id="cmf-edit-modal"` 的 div。`getElementById` 只回傳第一個，第二個（綠色標題那個）是死代碼，但會佔 DOM。
→ **刪掉第二個**（`<h2 class="green">編輯產品資料</h2>` 那一整塊）。

### 4.2 全形百分號
```css
.main { max-width: 100％; }   /* ← U+FF05 全形，CSS 整條失效 */
```
→ 改成 `100%`。

### 4.3 Drag & drop 偽造事件無效
```js
document.getElementById('abbr-file-input').dispatchEvent(
  Object.assign(new Event('change'), {target:{files:[file]}}));
```
`Event.target` 是唯讀的，`Object.assign` 蓋不掉，dispatch 後 handler 讀到的 `this.files[0]` 是 undefined。
→ 把解析邏輯抽成 `handleAbbrFile(file)`，change handler 與 drop handler 都呼叫它。

### 4.4 `deleteCmfRow` 用 index 找原陣列
```js
const allIdx = cmfAllData.indexOf(row);   // 靠物件參考，篩選後仍成立
```
這段其實是對的（`cmfFiltered` 存的是同一批物件參考），但**一旦接了後台 DB、資料重新 fetch 就會失效**。接 DB 時改用 `record_id` 定位。

### 4.5 `openCmfDetail(idx)` 用的是 `cmfFiltered` 的 index
篩選變動後 index 會位移。目前因為每次篩選都重繪，暫時安全。接 DB 後一律改用 `record_id`。

---

## 5. 目前的資料持久化狀況（重要）

**沒有持久化。** 新增縮寫、編輯 CMF、刪除列——全部只改記憶體中的 JS 物件，重新整理就消失。使用者現在的 workflow 應該是：改完 → 按「匯出篩選結果」下載 xlsx → 手動存檔。

這就是需要後台的理由。接後台的最小改動（**UI 完全不動**）：

```js
// 原本：
let cmfAllData = JSON.parse(JSON.stringify(CMF_DEFAULT));

// 改成：
let cmfAllData = [];
async function loadCmf() {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/v_cmf_flat?select=*`, {
    headers: { apikey: SUPABASE_ANON_KEY }
  });
  cmfAllData = await r.json();          // VIEW 欄位名與 CMF_DEFAULT 完全一致
  cmfFiltered = [...cmfAllData];
  cmfPopulateFilters();
  renderCmfTable(cmfFiltered);
}
loadCmf();
```

`saveCmfEdit()` / `deleteCmfRow()` 各多一個 `fetch` PATCH / DELETE。其餘 render、篩選、匯出邏輯**一行都不用改**——這是把 VIEW 欄位名設計成和舊欄位一模一樣的全部意義。

> anon key 只給 `SELECT` 權限；寫入走 Supabase Auth 登入後的 role。詳見 `references/database.md`。
