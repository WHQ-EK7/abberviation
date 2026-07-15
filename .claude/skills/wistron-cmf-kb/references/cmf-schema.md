# CMF 欄位字典 (Canonical Schema)

目錄
1. 欄位總表
2. Enum 值與正規化對照
3. 色號 (Wstron Color_PN) 編碼規則
4. Lab / Gloss 量測值模型
5. 舊欄位 → 新欄位對照（migration map）
6. 資料品質規則（驗證器實作的規則）

---

## 1. 欄位總表

### 1.1 識別與歸屬

| Canonical | 舊欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|---|
| `customer` | `Brand` | string | ✅ | **客戶代號**：`Cindy`、`Rosa`、`Naomi`、`Yama Kyo`、`HPE` |
| `projects` | `Project` | string[] | ✅ | 專案清單。原欄位以 `/` `,` `;` 分隔，需切成陣列 |
| `record_id` | — | string | ✅ | 系統生成：`{customer}-{wistron_color_pn}-{material}-{seq}` |

> `Brand` 存的是**客戶代號**，原樣沿用，不做任何推導或拆分。
> 已知代號清單寫在 `assets/cmf_schema.json` 的 `enums.customer`，驗證器只拿它做拼字檢查（W102）——
> 出現清單外的值時提醒一句「這是新客戶還是打錯字？」，不會自作主張改資料。
> 新增客戶時把代號加進那個清單即可。

### 1.2 材質與工法

> ## ⭐ 最重要的一次拆分：forming vs finish
>
> 舊的 `Manufacturing Methods` 一欄同時裝了兩種完全不同的東西：
>
> - **成型工法 (forming)**：Injection Molding、Stamping、Die-Casting、Extrusion+CNC、Composite Machining、Raw Material
> - **表面處理 (finish)**：Powder Coating、Liquid Coating、Anodizing、Electrophoresis、PVD、Pad Print、LBL
>
> 更麻煩的是，**當這一欄放成型工法時，表面處理就被塞進 `Remark`**：
>
> | Wstron Color_PN | Manufacturing Methods | Remark | 真正的 finish |
> |---|---|---|---|
> | `ACS-S3008E` | Stamping | `1.PVD2.Handle` | PVD |
> | `ACS-S8240E` | Extrusion+CNC | `1.Anodize2.Handle` | Anodizing |
> | `ACS-S0376PE-2` | Stamping | `1.Powder coating\n2.#EN3KHC` | Powder Coating |
> | `ACS-S0376PE-4` | Stamping | `1.Liquid Paint\n2.Light Pipe Bracket` | Liquid Coating |
>
> 這導致「列出所有做陽極的件」這種基本查詢做不出來。Canonical 拆成兩欄後才有救。
> `normalize_cmf.py` 的 `finish_from_remark()` 負責從 Remark 挖回來。


| Canonical | 舊欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|---|
| `material` | `Material` | enum | ✅ | `Metal` / `Plastic` / `Printing` |
| `forming_process` | `Manufacturing Methods`（部分） | enum | ✅ | **成型工法**：Injection Molding / Stamping / Die-Casting / Extrusion+CNC / Raw Material |
| `finish_process` | `Manufacturing Methods`（部分）**或 `Remark`** | enum | | **表面處理**：Powder Coating / Anodizing / PVD / Pad Print / Electrophoresis |
| `material_specs` | `Material SPEC/Apply to.` | string[] | ✅ | 底材規格：`SGCC`、`SUS 304`、`PC+ABS`、`AL6063 T5`、`ZA8`、`AZ91D`、`Die-Casting` |
| `finish_note` | （原本混在工法裡） | string | | 從工法名稱抽出的顏色/位置修飾：`Black`、`Silver`、`Light Gray` |
| `surface_finishing` | `Surface Finishing` | string | | 表面處理補充：噴砂、鈍化、封孔、防指紋、蝕紋（MT11010 / MT11020）|
| `texture_code` | （原本埋在 Remark） | string | | 蝕紋編號 `MT11010`、`MT11020`、SPI 等級 `B2` |

> `Material SPEC/Apply to.` 這欄名稱本身就在打架——它同時裝「底材規格」（SGCC）和「適用對象」（Metal, Plastic）。Printing 類的列，這欄裝的是「印在什麼上面」。Canonical 用 `material_specs` 統一表示「底材」，Printing 列的底材就是被印的那個材質，語意反而更一致。

### 1.3 顏色

| Canonical | 舊欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|---|
| `wistron_color_pn` | `Wstron Color_PN` | string | ✅* | 緯創色號，見 §3。（*與 `customer_color_pn` 至少要有一個）|
| `wistron_color_hex` | `Wstron Color HEX` | hex | | `#RRGGBB` 大寫 |
| `customer_color_pn` | `Customer Color Name_PN` | string | | 客戶色名/料號：`Standard Black - DPN: PH202`、`Pantone 285C` |
| `customer_color_hex` | `Customer Color HEX` | hex | | |
| `pantone_ref` | （原埋在 Remark / 色名） | string | | 從 `Similar to Pantone 200U`、`PMS BLACK C` 抽出 |
| `standards_color` | `Standards Color` | string | | 標準色板 |
| `light_source` | `Light Source` | enum | | `CWF/F2` / `D65` / `A` / `TL84` |

> 注意舊欄位拼字是 `Wstron`（少了 i），**前端與現有 Excel 都用這個拼法，不要擅自改**，只在 canonical 層正名為 `wistron_*`，靠 migration map 對映。

### 1.4 供應商（四種角色，不要混）

| Canonical | 舊欄位 | 說明 |
|---|---|---|
| `oem_vendor` | `OEM Vendor` | 組裝/成型廠：`Karrie`、`PRIVER`、`Amtek`、`SOUTHCO`、`AVC`、`品固`、`鴻昌` |
| `material_supplier` | `Material Supplier` | 原料/塗料供應商：`SABIC`、`Covestro`、`Akzo Nobel`、`TIGER`、`PPG`、`奇美` |
| `finish_applicator` | `Finish Applicator` | 表面處理施作廠（目前多為空，前端 fallback 到 `OEM Vendor`）|
| `finish_supplier` | `Finish Supplier` | 塗料/藥水供應商（目前多為空，前端 fallback 到 `Material Supplier`）|

> 前端 `openCmfDetail()` 已經寫了 fallback：`Finish Applicator || OEM Vendor`。這個 fallback 是資料缺失的補丁，正規化後應該把值真的填進去，而不是靠 UI 猜。

`material_supplier` 目前混了**公司名**與**料號**（`Sabic (Lexan 925)`、`Bayblend(FR6005)`、`SILICONE 70°`、`RPT 100FR`）。Canonical 拆成：
- `material_supplier` → 公司（`SABIC`）
- `material_grade` → 牌號（`Lexan 925`、`C6600`、`Cycoloy C2950HF`）

### 1.5 附件與備註

| Canonical | 舊欄位 | 型別 |
|---|---|---|
| `images` | `image` + `Color Images` + `Sample images` | string[]（合併三欄，逗號分隔）|
| `spec_url` | `URL` | url |
| `remark` | `Remark` | text |

---

## 2. Enum 值與正規化對照

### 2.1 `material`
`Metal` / `Plastic` / `Printing`
（若未來出現 `Rubber`、`Film`、`Label`，加進 enum，不要塞進 `Plastic`。現有的 `Silicon Rubber` 目前歸在 Plastic，可接受但應標記。）

### 2.2 工法 — canonical 值、類別與別名

**`kind` 欄決定它是 forming 還是 finish。色號後綴只看 finish。**

| Canonical | kind | PN 後綴 | 別名（資料中實際出現的寫法） |
|---|---|---|---|
| `Injection Molding` | forming | — | Injection Molding |
| `Double Injection` | forming | — | Double Injection |
| `Die-Casting` | forming | — | Die-Casting |
| `Stamping` | forming | — | Stamping |
| `Extrusion + CNC` | forming | — | Extrusion+CNC |
| `Composite Machining` | forming | — | Composite Machining |
| `Raw Material` | forming | — | Raw material（＝不做表面處理，原料本色）|
| `Powder Coating` | **finish** | `PE` | Powder coating, Powder Painting, Black Powder Painting, Silver Powder Painting, Black Painting, Light Gray Painting |
| `Liquid Coating` | **finish** | `T` | Liquid Paint, Low bake Wet Paint |
| `Anodizing` | **finish** | `E` | Anodized, Anodizing, Black Anodized (黑色陽極) |
| `Electrophoresis` | **finish** | `ED` | Black electrophoresis (黑色電著), ED, E-Coat |
| `PVD` | **finish** | `E` | PVD |
| `NCVM` | **finish** | `E` | NCVM |
| `Pad Print` | **finish** | `P` | Pad Print |
| `LBL` | **finish** | `P` | LBL(Layer-by-Layer) |

**別名裡的顏色詞（Black / Silver / Light Gray）不要丟掉** —— 搬去 `finish_note`。

**當工法欄是 forming 時，去 `Remark` 找 finish**（`remark_finish_patterns`）：
`pvd` → PVD、`anodize`/`陽極` → Anodizing、`powder coating`/`powder painting` → Powder Coating、`liquid paint`/`wet paint` → Liquid Coating、`electrophoresis`/`電著` → Electrophoresis、`pad print` → Pad Print。

### 2.3 `light_source`
`CWF/F2`（Cisco 系常用）、`D65`（Wistron 內部標準）。空值代表未指定，不要預設填值。

---

## 3. 色號 (Wstron Color_PN) 編碼規則

```
ACS-S 8233 PE -02
│     │    │   └── 變體序號（同色不同底材/供應商）
│     │    └────── 製程後綴
│     └─────────── 色系流水號（4 碼）
└───────────────── 固定前綴
```

**色系流水號的第一碼有明顯規律**（從 92 筆歸納，可用於驗證，但非絕對）：

| 首碼 | 色系 | 例 |
|---|---|---|
| `0` | 黑 / 灰 / 白 | ACS-S0425 (Black), ACS-S0483 (White) |
| `1` | 紅 | ACS-S1020 (Wistron Red) |
| `2` | 橘 / 棕 / 酒紅 | ACS-S2017 (Orange), ACS-S2026 (Burgundy) |
| `3` | 金 / 香檳 | ACS-S3001 (Pantone 4239C) |
| `4` | 綠 | ACS-S4028 (Lime Green) |
| `5` | 藍 | ACS-S5027, ACS-S5040, ACS-S5053 |
| `8` | 銀 / 鋁 | ACS-S8209, ACS-S8233 (Satin Aluminum) |

**後綴一致性規則（驗證器會擋）：**
- 工法是 Powder Coating → 色號必須以 `PE` 結尾
- 工法是 Anodizing → 必須以 `E` 結尾（但不是 `PE`、不是 `ED`）
- 工法是 Raw Material / Injection Molding → **不可**有 `PE`/`E`/`T` 後綴
- 例外：`ANODIZE BLACK`（North Island 4U handle）是外購件沿用供應商編號，不套規則 → 標記 `pn_exempt: true`

---

## 4. Lab / Gloss 量測值模型

現有前端有 4 組量測來源，每組 6 個欄位（`L a b E Gloss FT`）：

| 前綴 | 意義 |
|---|---|
| `Customer_` | 客戶提供的標準值 |
| `WHQ_` | 緯創總部（Hsinchu HQ）量測 |
| `WZS_` | 中山廠（Zhongshan）量測 |
| `FA_` | Finish Applicator（表面處理廠）量測 |

**Canonical 改成一個 `measurements` 陣列**（Level 2/3），Level 1 匯出時再攤回 24 個欄位：

```json
"measurements": [
  {"source": "WZS", "L": 81.13, "a": -0.45, "b": 0.57,
   "delta_e": null, "gloss_raw": "10±3", "gloss_min": 7, "gloss_max": 13,
   "ft": null, "light_source": "CWF/F2"}
]
```

**規則：**
- `L ∈ [0,100]`；`a`, `b ∈ [-128,127]`；`delta_e ≥ 0`（**負值 = 資料錯位，見下**）
- **ΔE 錯位修正**：若 `*_E < 0` 且對應 `*_b` 為空 → 把 `E` 的值搬進 `b`，`E` 設為 null。現有資料至少 8 筆中招（Cindy 的 PP/PC+ABS 原料列）。
- `Gloss` 保留原字串（`5±1`、`7~13`、`5.2(4~6)`、`9°±3° Gu`），另解析出 `gloss_min` / `gloss_max` 供篩選用。`°` 是誤植（光澤單位是 GU，不是度），解析時忽略。
- `FT` = Film Thickness（膜厚，μm）。目前 92 筆全空，但欄位保留。

---

## 5. 舊欄位 → 新欄位對照（migration map）

```
Brand                     → customer  (原樣沿用，僅做拼字檢查)
Project                   → projects[]              (split on / , ;)
Material                  → material
Manufacturing Methods     → forming_process | finish_process + finish_note
                            (先判斷 kind；若是 forming，再去 Remark 找 finish)
Material SPEC/Apply to.   → material_specs[]        (split on , /)
OEM Vendor                → oem_vendor[]            (split on /)
Material Supplier         → material_supplier + material_grade    (拆括號)
Finish Applicator         → finish_applicator       (空 → 沿用 oem_vendor)
Finish Supplier           → finish_supplier         (空 → 沿用 material_supplier)
Customer Color Name_PN    → customer_color_pn + pantone_ref
Wstron Color_PN           → wistron_color_pn        (含後綴驗證)
Wstron Color HEX          → wistron_color_hex       (upper, #RRGGBB)
Customer Color HEX        → customer_color_hex
Light Source              → light_source
Standards Color           → standards_color
Gloss Units               → gloss_units
Surface Finishing         → surface_finishing
Remark                    → remark + texture_code + pantone_ref + finish_process (抽取)
URL                       → spec_url
image / Color Images / Sample images  → images[]
{Customer,WHQ,WZS,FA}_{L,a,b,E,Gloss,FT}  → measurements[]
WZS_B                     → measurements[WZS].b     (注意舊資料是大寫 B！)
```

⚠️ **`WZS_B` 是大寫**，其他來源都是小寫 `b`。前端 `openCmfDetail()` 已經用 `altKey` 硬補了這個不一致。Canonical 一律用小寫 `b`，但讀舊資料/舊 Excel 時要同時接受 `WZS_B` 和 `WZS_b`。

---

## 6. 資料品質規則（驗證器實作）

| 代碼 | 等級 | 規則 |
|---|---|---|
| `E001` | error | 缺必填：`customer` / `material` / `manufacturing_method` |
| `E002` | error | 沒有任何色號（`wistron_color_pn` 與 `customer_color_pn` 皆空）|
| `E003` | error | HEX 格式錯誤（非 `#RRGGBB`）|
| `E004` | error | `L` 不在 0–100，或 `a`/`b` 不在 −128–127 |
| `E005` | error | `delta_e < 0`（多半是 b 值錯位，可自動修）|
| `E006` | error | 色號後綴與工法不符（例：`ACS-S0425` 標 Powder coating）|
| `W101` | warn | `manufacturing_method` 不在 canonical 清單，需人工歸類 |
| `W102` | warn | `Brand` 值無法對映到 `customer`／`owner` |
| `W103` | warn | HEX 與 Lab 換算差距 ΔE > 10（HEX 可能是目測填的）|
| `W104` | warn | `material_supplier` 內含括號料號，應拆成 `material_grade` |
| `W105` | warn | 同一 `wistron_color_pn` 出現多組不一致的 HEX |
| `W106` | warn | `Project` 為空（92 筆中約 6 筆）|
| `W107` | warn | 疑似重複列（`customer + wistron_color_pn + material_specs` 相同）|
