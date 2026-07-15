-- =====================================================================
-- Wistron CMF Knowledge Base — Postgres / Supabase schema
-- 貼進 Supabase SQL Editor 直接執行。
-- 設計重點：v_cmf_flat 的欄位名 100% 等同現有前端 CMF_DEFAULT，
--            所以前端一行都不用改。
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------- ENUMs ----------
create type measurement_source as enum ('Customer', 'WHQ', 'WZS', 'FA');
create type vendor_role        as enum ('oem', 'material_supplier', 'finish_applicator', 'finish_supplier');
create type material_kind      as enum ('Metal', 'Plastic', 'Printing');

-- ---------- 主檔 ----------
-- Brand 欄 = 客戶代號（Cindy / Rosa / Naomi / Yama Kyo / HPE），原樣存放。
create table customers (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique,   -- 客戶代號，前端 Brand 欄顯示的就是這個
  note  text
);

create table projects (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,  -- Pegasus / Tornado / Fractal / 17G ...
  customer_id  uuid references customers(id),
  status       text                   -- active / EOL / abandoned
);

create table material_specs (
  id    uuid primary key default gen_random_uuid(),
  code  text not null unique,         -- SGCC / SUS 304 / PC+ABS / AL6063 T5 / ZA8 / AZ91D
  kind  material_kind                 -- 這個底材屬於哪類
);

-- 工法分兩類：forming（成型）與 finish（表面處理）。
-- 舊資料把兩者塞在同一欄，這是這套 schema 要解決的核心問題。
create type process_kind as enum ('forming', 'finish');

create table manufacturing_methods (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,    -- Powder Coating / Anodizing / Stamping ...
  kind       process_kind not null,
  pn_suffix  text                     -- 只有 finish 才有：PE / E / T / P / ED
);

-- 供應商用一張表，角色靠 record_vendors.role 區分。
-- 理由：Karrie 既是 OEM 也做表面處理；Akzo Nobel 既賣塗料也是 finish supplier。
create table vendors (
  id       uuid primary key default gen_random_uuid(),
  name     text not null unique,      -- Karrie / PRIVER / SABIC / Akzo Nobel / TIGER
  name_zh  text,                      -- 品固 / 鴻昌 / 奇美
  country  text,
  note     text
);

create table colors (
  id                 uuid primary key default gen_random_uuid(),
  wistron_color_pn   text unique,     -- ACS-S8233PE-02
  customer_color_pn  text,            -- Standard Black - DPN: PH202
  wistron_hex        text check (wistron_hex  ~ '^#[0-9A-F]{6}$'),
  customer_hex       text check (customer_hex ~ '^#[0-9A-F]{6}$'),
  pantone_ref        text,            -- PMS BLACK C / Pantone 285C
  color_family       text,            -- 由 PN 首碼推導：Black / Blue / Silver ...
  pn_exempt          boolean default false   -- 外購件沿用供應商編號，不套 PN 規則
);

-- ---------- 事實表：一筆 = 前端的一列 ----------
create table cmf_records (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid references customers(id),
  color_id           uuid references colors(id),
  material           material_kind not null,
  forming_id         uuid references manufacturing_methods(id),   -- 成型工法
  finish_id          uuid references manufacturing_methods(id),   -- 表面處理（可為 null = 原料本色）
  finish_note        text,            -- 從工法名抽出的顏色修飾：Black / Silver
  surface_finishing  text,            -- 噴砂 / 鈍化 / 封孔 / 防指紋
  texture_code       text,            -- MT11010 / MT11020 / SPI B2
  material_grade     text,            -- Lexan 925 / C6600 / Cycoloy C2950HF
  light_source       text,
  standards_color    text,
  gloss_units        text,
  spec_url           text,
  images             text[] default '{}',
  remark             text,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now(),
  created_by         uuid,
  updated_by         uuid
);

-- ---------- 多值中介表 ----------
create table record_projects (
  record_id  uuid references cmf_records(id) on delete cascade,
  project_id uuid references projects(id),
  primary key (record_id, project_id)
);

create table record_specs (
  record_id uuid references cmf_records(id) on delete cascade,
  spec_id   uuid references material_specs(id),
  primary key (record_id, spec_id)
);

create table record_vendors (
  record_id uuid references cmf_records(id) on delete cascade,
  vendor_id uuid references vendors(id),
  role      vendor_role not null,
  primary key (record_id, vendor_id, role)
);

-- ---------- 量測值 ----------
-- CHECK (delta_e >= 0) 會直接擋掉現有那批 b/E 錯位的資料，
-- 逼你在 migration 時修掉，而不是把問題帶進新系統。這是刻意的。
create table measurements (
  id             bigserial primary key,
  record_id      uuid references cmf_records(id) on delete cascade,
  source         measurement_source not null,
  l_value        numeric check (l_value between 0 and 100),
  a_value        numeric check (a_value between -128 and 127),
  b_value        numeric check (b_value between -128 and 127),
  delta_e        numeric check (delta_e >= 0),
  gloss_raw      text,               -- 保留 "5±1" / "7~13" / "5.2(4~6)" 原字串
  gloss_min      numeric,
  gloss_max      numeric,
  film_thickness numeric,            -- FT (μm)
  light_source   text,
  measured_at    date,
  unique (record_id, source)
);

-- ---------- 稽核軌跡 ----------
create table cmf_audit (
  id         bigserial primary key,
  record_id  uuid,
  action     text,                   -- INSERT / UPDATE / DELETE
  before     jsonb,
  after      jsonb,
  actor      uuid,
  at         timestamptz default now()
);

create or replace function fn_cmf_audit() returns trigger as $$
begin
  insert into cmf_audit(record_id, action, before, after, actor)
  values (
    coalesce(new.id, old.id),
    tg_op,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,
    auth.uid()
  );
  return coalesce(new, old);
end;
$$ language plpgsql security definer;

create trigger trg_cmf_audit
  after insert or update or delete on cmf_records
  for each row execute function fn_cmf_audit();

-- ---------- 索引 ----------
create index on cmf_records (customer_id);
create index on cmf_records (color_id);
create index on cmf_records (material);
create index on cmf_records (finish_id);   -- 讓「列出所有做陽極的件」變成一次索引掃描
create index on measurements (record_id, source);
create index on colors (wistron_color_pn);

-- =====================================================================
-- v_cmf_flat — 攤平回前端要的形狀
-- 欄位名刻意保留歷史包袱：Wstron（少一個 i）、結尾句點、WZS_B 大寫。
-- 這是前端零改動的關鍵，不要「順手修正」這些名字。
-- =====================================================================
create or replace view v_cmf_flat as
with m as (
  select
    record_id,
    max(l_value)   filter (where source='Customer') as customer_l,
    max(a_value)   filter (where source='Customer') as customer_a,
    max(b_value)   filter (where source='Customer') as customer_b,
    max(gloss_raw) filter (where source='Customer') as customer_gloss,
    max(film_thickness) filter (where source='Customer') as customer_ft,
    max(l_value)   filter (where source='WHQ') as whq_l,
    max(a_value)   filter (where source='WHQ') as whq_a,
    max(b_value)   filter (where source='WHQ') as whq_b,
    max(gloss_raw) filter (where source='WHQ') as whq_gloss,
    max(film_thickness) filter (where source='WHQ') as whq_ft,
    max(l_value)   filter (where source='WZS') as wzs_l,
    max(a_value)   filter (where source='WZS') as wzs_a,
    max(b_value)   filter (where source='WZS') as wzs_b,
    max(delta_e)   filter (where source='WZS') as wzs_e,
    max(gloss_raw) filter (where source='WZS') as wzs_gloss,
    max(film_thickness) filter (where source='WZS') as wzs_ft,
    max(l_value)   filter (where source='FA') as fa_l,
    max(a_value)   filter (where source='FA') as fa_a,
    max(b_value)   filter (where source='FA') as fa_b,
    max(delta_e)   filter (where source='FA') as fa_e,
    max(gloss_raw) filter (where source='FA') as fa_gloss,
    max(film_thickness) filter (where source='FA') as fa_ft
  from measurements group by record_id
)
select
  r.id::text                                             as "record_id",
  cu.name                                                as "Brand",
  r.material::text                                       as "Material",
  (select string_agg(p.name, ' / ' order by p.name)
     from record_projects rp join projects p on p.id = rp.project_id
    where rp.record_id = r.id)                           as "Project",
  -- 舊前端只有一欄，攤平時 finish 優先；兩欄的原始值另外用 Forming/Finish 欄提供
  coalesce(fin.name, frm.name)                           as "Manufacturing Methods",
  frm.name                                               as "Forming Process",
  fin.name                                               as "Finish Process",
  (select string_agg(sp.code, ', ' order by sp.code)
     from record_specs rs join material_specs sp on sp.id = rs.spec_id
    where rs.record_id = r.id)                           as "Material SPEC/Apply to.",
  (select string_agg(v.name, ' / ' order by v.name)
     from record_vendors rv join vendors v on v.id = rv.vendor_id
    where rv.record_id = r.id and rv.role = 'oem')       as "OEM Vendor",
  (select string_agg(v.name, ' / ' order by v.name)
     from record_vendors rv join vendors v on v.id = rv.vendor_id
    where rv.record_id = r.id and rv.role = 'material_supplier') as "Material Supplier",
  (select string_agg(v.name, ' / ' order by v.name)
     from record_vendors rv join vendors v on v.id = rv.vendor_id
    where rv.record_id = r.id and rv.role = 'finish_applicator') as "Finish Applicator",
  (select string_agg(v.name, ' / ' order by v.name)
     from record_vendors rv join vendors v on v.id = rv.vendor_id
    where rv.record_id = r.id and rv.role = 'finish_supplier')   as "Finish Supplier",
  c.customer_color_pn                                    as "Customer Color Name_PN",
  c.wistron_color_pn                                     as "Wstron Color_PN",
  c.wistron_hex                                          as "Wstron Color HEX",
  c.customer_hex                                         as "Customer Color HEX",
  r.light_source                                         as "Light Source",
  r.standards_color                                      as "Standards Color",
  r.gloss_units                                          as "Gloss Units",
  r.surface_finishing                                    as "Surface Finishing",
  r.remark                                               as "Remark",
  r.spec_url                                             as "URL",
  array_to_string(r.images, ',')                         as "image",
  m.customer_l  as "Customer_L", m.customer_a as "Customer_a", m.customer_b as "Customer_b",
  m.customer_gloss as "Customer_Gloss", m.customer_ft as "Customer_FT",
  m.whq_l as "WHQ_L", m.whq_a as "WHQ_a", m.whq_b as "WHQ_b",
  m.whq_gloss as "WHQ_Gloss", m.whq_ft as "WHQ_FT",
  m.wzs_l as "WZS_L", m.wzs_a as "WZS_a",
  m.wzs_b as "WZS_B",          -- 大寫 B：配合舊前端，不要改
  m.wzs_e as "WZS_E", m.wzs_gloss as "WZS_Gloss", m.wzs_ft as "WZS_FT",
  m.fa_l as "FA_L", m.fa_a as "FA_a", m.fa_b as "FA_b",
  m.fa_e as "FA_E", m.fa_gloss as "FA_Gloss", m.fa_ft as "FA_FT"
from cmf_records r
left join customers cu on cu.id = r.customer_id
left join colors    c  on c.id  = r.color_id
left join manufacturing_methods frm on frm.id = r.forming_id
left join manufacturing_methods fin on fin.id = r.finish_id
left join m on m.record_id = r.id;

-- =====================================================================
-- RLS — anon 只能讀，寫入要登入
-- 前端的 anon key 會公開在 GitHub Pages 原始碼裡，絕不可用 service_role。
-- =====================================================================
alter table cmf_records  enable row level security;
alter table measurements enable row level security;
alter table colors       enable row level security;

create policy "read_all"  on cmf_records  for select using (true);
create policy "write_auth" on cmf_records for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

create policy "read_all"  on measurements for select using (true);
create policy "write_auth" on measurements for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

create policy "read_all"  on colors for select using (true);
create policy "write_auth" on colors for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
