# 後台資料庫設計 (Postgres / Supabase)

完整建表語法在 `assets/schema.sql`，可直接貼進 Supabase SQL Editor。這份文件解釋**為什麼這樣設計**。

---

## 1. 核心決定：VIEW 是前端與 DB 的合約

前端吃扁平列，DB 存正規化資料。中間用一個 VIEW 接起來：

```
cmf_records ──┬─ record_projects ─ projects
              ├─ record_specs ──── material_specs
              ├─ record_vendors ── vendors (role: oem/material/finish_applicator/finish_supplier)
              ├─ colors
              └─ measurements
                        │
                        ▼
                  v_cmf_flat   ← 欄位名 100% 等同現有 CMF_DEFAULT
                        │
                        ▼
                    前端 fetch()
```

**`v_cmf_flat` 的欄位名必須逐字等於現有前端用的名字**，包含 `Wstron Color_PN`（少一個 i）、`Material SPEC/Apply to.`（結尾有句點）、`WZS_B`（大寫 B）這些歷史包袱。Postgres 用雙引號保留大小寫與空格：

```sql
SELECT c.wistron_color_pn AS "Wstron Color_PN"
```

這樣做的代價是 VIEW 有點醜，但換來的是**前端零改動**。值得。

---

## 2. 表結構

### 2.1 主檔（lookup tables）

| 表 | 說明 |
|---|---|
| `customers` | 客戶：Dell、HPE、Cisco、NVIDIA、Ubiquiti |
| `owners` | 內部負責人：Cindy、Rosa、Naomi、Yama Kyo |
| `projects` | 專案：Pegasus、Tornado、Fractal、17G、M8 1U… |
| `materials` | Metal / Plastic / Printing（enum 也行，但做成表方便之後加）|
| `material_specs` | 底材：SGCC、SUS 304、PC+ABS、AL6063 T5、ZA8、AZ91D |
| `manufacturing_methods` | canonical 工法 + `pn_suffix`（色號後綴，用來做一致性驗證）|
| `vendors` | 所有供應商（**一張表**，用 `record_vendors.role` 區分角色）|
| `colors` | 色號主檔：`wistron_color_pn` 為 unique key |

> **供應商為什麼只用一張表？** 因為現實中同一家會扮演多種角色——Karrie 既是 OEM Vendor 也做表面處理；Akzo Nobel 是 Material Supplier 也是 Finish Supplier。分四張表會重複建檔，之後要「查 Akzo 相關的所有料」就得 union 四次。

### 2.2 事實表

`cmf_records` = 一筆「客戶 × 顏色 × 材質 × 工法」的組合，也就是前端的一列。

多值欄位用中介表：`record_projects`、`record_specs`、`record_vendors`。

### 2.3 量測表

`measurements` 一列 = 一個量測來源（Customer / WHQ / WZS / FA）的一組 Lab。

```sql
CREATE TABLE measurements (
  id           bigserial PRIMARY KEY,
  record_id    uuid REFERENCES cmf_records(id) ON DELETE CASCADE,
  source       measurement_source NOT NULL,   -- enum
  l_value      numeric CHECK (l_value BETWEEN 0 AND 100),
  a_value      numeric CHECK (a_value BETWEEN -128 AND 127),
  b_value      numeric CHECK (b_value BETWEEN -128 AND 127),
  delta_e      numeric CHECK (delta_e >= 0),  -- ← DB 層直接擋掉負 ΔE
  gloss_raw    text,                          -- 保留 "5±1" "7~13" 原字串
  gloss_min    numeric,
  gloss_max    numeric,
  film_thickness numeric,
  light_source text,
  UNIQUE (record_id, source)
);
```

`CHECK (delta_e >= 0)` 這一條**直接讓現有那 8 筆 b/E 錯位的資料匯不進去**，逼你在 migration 時修掉，而不是把髒資料帶進新系統。這是刻意的。

---

## 3. `v_cmf_flat` VIEW

把 24 個量測欄位攤回去，靠 `FILTER` 聚合：

```sql
CREATE VIEW v_cmf_flat AS
SELECT
  r.id                                            AS record_id,
  cu.name                                         AS "Brand",
  m.name                                          AS "Material",
  string_agg(DISTINCT p.name, ' / ')              AS "Project",
  mm.name                                         AS "Manufacturing Methods",
  string_agg(DISTINCT ms.code, ', ')              AS "Material SPEC/Apply to.",
  string_agg(DISTINCT v.name, ' / ')
    FILTER (WHERE rv.role = 'oem')                AS "OEM Vendor",
  string_agg(DISTINCT v.name, ' / ')
    FILTER (WHERE rv.role = 'material_supplier')  AS "Material Supplier",
  c.customer_color_pn                             AS "Customer Color Name_PN",
  c.wistron_color_pn                              AS "Wstron Color_PN",
  c.wistron_hex                                   AS "Wstron Color HEX",
  c.customer_hex                                  AS "Customer Color HEX",
  r.light_source                                  AS "Light Source",
  r.surface_finishing                             AS "Surface Finishing",
  r.remark                                        AS "Remark",
  max(ms2.l_value) FILTER (WHERE ms2.source='WZS') AS "WZS_L",
  max(ms2.a_value) FILTER (WHERE ms2.source='WZS') AS "WZS_a",
  max(ms2.b_value) FILTER (WHERE ms2.source='WZS') AS "WZS_B",   -- 大寫 B，配合舊前端
  max(ms2.gloss_raw) FILTER (WHERE ms2.source='WZS') AS "WZS_Gloss",
  -- ... WHQ_ / Customer_ / FA_ 同理
  ...
FROM cmf_records r
LEFT JOIN customers cu ON cu.id = r.customer_id
...
GROUP BY r.id, cu.name, m.name, mm.name, c.customer_color_pn, ...;
```

完整版在 `assets/schema.sql`。

**驗收標準**：把 VIEW 的輸出跟現有的 `CMF_DEFAULT` 逐欄 diff，除了已知要修的髒資料外應該完全一致。migration 完成後跑這個 diff，這是唯一可靠的驗收方式。

---

## 4. RLS（Supabase 必做）

```sql
ALTER TABLE cmf_records ENABLE ROW LEVEL SECURITY;

-- 所有人（含 anon）可讀
CREATE POLICY "read_all" ON cmf_records FOR SELECT USING (true);

-- 只有登入者可寫
CREATE POLICY "write_auth" ON cmf_records FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');
```

前端的 anon key 是公開的（會出現在 GitHub Pages 的原始碼裡），**絕對不要用 service_role key**。anon 只能 SELECT，編輯功能要 Supabase Auth 登入後才開放。

## 5. 稽核軌跡

CMF 資料的核心價值是「這個色號當初是誰、為什麼、什麼時候定的」。加一張 `cmf_audit`，用 trigger 記錄每次 UPDATE / DELETE 的 before/after JSONB + `auth.uid()` + timestamp。這是 Excel 永遠做不到的事，也是說服團隊從 Excel 搬過來的主要理由。

## 6. 圖片

Supabase Storage bucket `cmf-images`，路徑 `{wistron_color_pn}/{uuid}.jpg`。`cmf_records.images` 存 public URL 陣列。現有資料裡的 `/images/pms-659c.png` 是 repo 內相對路徑，migration 時可保留，之後再搬。

---

## 7. 不想寫後端的替代方案

如果不想維護 Supabase：

| 方案 | 適合場景 |
|---|---|
| **NocoDB / Baserow** 接同一個 Postgres | 想要現成的表格後台介面給非工程師填資料 |
| **GitHub repo 裡放 `cmf.json` + PR 流程** | 團隊小、改動不頻繁、想要 git 版本控制當稽核軌跡 |
| **Google Sheets + Apps Script 匯出 JSON** | 大家已經在用 Excel，想無痛過渡 |

前兩者前端改動都一樣小（把 `CMF_DEFAULT` 換成 `fetch`）。第三個的問題是回到了 Excel 的老路，schema 驗證沒地方掛，只建議當短期過渡。
