-- Richmax Print Estimator — Supabase schema (idempotent, safe to re-run)
create extension if not exists pgcrypto;

create table if not exists public.staff_profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  employee_id text unique,
  full_name text,
  email text,
  role text not null default 'pending' check (role in ('admin','staff','pending')),
  created_at timestamptz not null default now()
);

create table if not exists public.quotes(
  id uuid primary key default gen_random_uuid(),
  quote_no text unique not null,
  kind text not null default 'quote' check (kind in ('quote','order')),
  status text not null default 'new',
  process text not null,
  product_type text not null,
  spec jsonb not null,
  qty integer not null,
  subtotal numeric(14,2),
  vat numeric(14,2),
  total numeric(14,2),
  contact_name text not null,
  company text,
  email text,
  phone text,
  notes text,
  consent boolean not null default false,
  device_id text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.saved_jobs(
  id uuid primary key default gen_random_uuid(),
  device_id text not null,
  user_id uuid references auth.users(id),
  process text not null,
  form jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists saved_jobs_device_idx on public.saved_jobs(device_id);
create index if not exists quotes_created_idx on public.quotes(created_at desc);

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from staff_profiles where id=auth.uid() and role in ('admin','staff'))
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from staff_profiles where id=auth.uid() and role='admin')
$$;
create or replace function public.req_device() returns text
language sql stable as $$
  select coalesce(current_setting('request.headers',true)::json->>'x-device-id','')
$$;
create or replace function public.staff_email_for(emp text) returns text
language sql stable security definer set search_path=public as $$
  select email from staff_profiles where upper(employee_id)=upper(emp) and role in ('admin','staff') limit 1
$$;
grant execute on function public.staff_email_for(text) to anon, authenticated;

-- First sign-up becomes admin; later sign-ups stay 'pending' until an admin approves them.
create or replace function public.handle_new_staff() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into staff_profiles(id,employee_id,full_name,email,role)
  values(new.id,new.raw_user_meta_data->>'employee_id',new.raw_user_meta_data->>'full_name',new.email,
         case when not exists(select 1 from staff_profiles) then 'admin' else 'pending' end)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created_rmx on auth.users;
create trigger on_auth_user_created_rmx after insert on auth.users
  for each row execute function public.handle_new_staff();

alter table public.staff_profiles enable row level security;
alter table public.quotes enable row level security;
alter table public.saved_jobs enable row level security;

drop policy if exists sp_read on public.staff_profiles;
create policy sp_read on public.staff_profiles for select to authenticated using (id=auth.uid() or public.is_staff());
drop policy if exists sp_admin on public.staff_profiles;
create policy sp_admin on public.staff_profiles for update to authenticated using (public.is_admin());

drop policy if exists q_insert on public.quotes;
create policy q_insert on public.quotes for insert to authenticated with check (public.is_staff());
drop policy if exists q_staff_read on public.quotes;
create policy q_staff_read on public.quotes for select to authenticated using (public.is_staff());
drop policy if exists q_staff_update on public.quotes;
create policy q_staff_update on public.quotes for update to authenticated using (public.is_staff());

drop policy if exists sj_rw on public.saved_jobs;
create policy sj_rw on public.saved_jobs for all to anon, authenticated
  using (device_id = public.req_device()) with check (device_id = public.req_device());

grant select, insert, update, delete on public.saved_jobs to anon, authenticated;
revoke insert on public.quotes from anon;
grant insert on public.quotes to authenticated;
grant select, update on public.quotes to authenticated;
grant select, update on public.staff_profiles to authenticated;

-- Rate card (customer cost is public-readable for pricing; staff cost is staff-only)
create table if not exists public.rate_card(id text primary key,grp text not null,name_th text,name_en text,unit text,cust_cost numeric(14,4) not null default 0,sort integer not null default 0,updated_at timestamptz not null default now(),updated_by uuid);
create table if not exists public.rate_card_internal(id text primary key references public.rate_card(id) on delete cascade,staff_cost numeric(14,4) not null default 0,updated_at timestamptz not null default now(),updated_by uuid);
create table if not exists public.rate_card_history(id bigint generated always as identity primary key,rate_id text not null,field text not null,old_value numeric(14,4),new_value numeric(14,4),changed_by uuid,changed_email text,changed_at timestamptz not null default now());
create index if not exists rate_hist_idx on public.rate_card_history(changed_at desc);
create or replace function public.log_rate_change() returns trigger language plpgsql security definer set search_path=public as $$
declare f text; o numeric; n numeric;
begin
 new.updated_at := now(); new.updated_by := auth.uid();
 if TG_TABLE_NAME='rate_card' then f:='cust'; o:=old.cust_cost; n:=new.cust_cost; else f:='staff'; o:=old.staff_cost; n:=new.staff_cost; end if;
 if o is distinct from n then
  insert into rate_card_history(rate_id,field,old_value,new_value,changed_by,changed_email) values(new.id,f,o,n,auth.uid(),(select email from auth.users where id=auth.uid()));
 end if;
 return new;
end $$;
drop trigger if exists trg_rate_card_log on public.rate_card;
create trigger trg_rate_card_log before update on public.rate_card for each row execute function public.log_rate_change();
drop trigger if exists trg_rate_internal_log on public.rate_card_internal;
create trigger trg_rate_internal_log before update on public.rate_card_internal for each row execute function public.log_rate_change();
alter table public.rate_card enable row level security;
alter table public.rate_card_internal enable row level security;
alter table public.rate_card_history enable row level security;
drop policy if exists rc_read on public.rate_card;
create policy rc_read on public.rate_card for select to authenticated using (public.is_staff());
drop policy if exists rc_ins on public.rate_card;
create policy rc_ins on public.rate_card for insert to authenticated with check (public.is_staff());
drop policy if exists rc_upd on public.rate_card;
create policy rc_upd on public.rate_card for update to authenticated using (public.is_staff()) with check (public.is_staff());
drop policy if exists rci_all on public.rate_card_internal;
create policy rci_all on public.rate_card_internal for all to authenticated using (public.is_staff()) with check (public.is_staff());
drop policy if exists rch_read on public.rate_card_history;
create policy rch_read on public.rate_card_history for select to authenticated using (public.is_staff());
revoke insert, update, delete on public.rate_card from anon;
revoke all on public.rate_card_internal from anon;
revoke all on public.rate_card_history from anon;
revoke select on public.rate_card from anon;
grant select on public.rate_card to authenticated;
grant insert, update on public.rate_card to authenticated;
grant select, insert, update on public.rate_card_internal to authenticated;
grant select on public.rate_card_history to authenticated;

-- Seed rate card (placeholder values — edit in the app)
insert into public.rate_card(id,grp,name_th,name_en,unit,cust_cost,sort) values
('paper.pond','paper','กระดาษปอนด์','Bond paper','kg',42.5,0),
('paper.artgloss','paper','อาร์ตมัน','Gloss art','kg',47.5,1),
('paper.artmatt','paper','อาร์ตด้าน','Matt art','kg',47.5,2),
('paper.artcard1','paper','อาร์ตการ์ด 1 หน้า','C1S art card','kg',50,3),
('paper.artcard2','paper','อาร์ตการ์ด 2 หน้า','C2S art card','kg',55,4),
('paper.duplex','paper','กล่องแป้งหลังขาว/เทา','Duplex board','kg',37.5,5),
('paper.kraft','paper','คราฟท์น้ำตาล','Brown kraft','kg',40,6),
('film.PET','film','ฟิล์ม PET','PET film','m2',8.75,7),
('film.BOPP','film','ฟิล์ม BOPP','BOPP film','m2',6.875,8),
('film.OPPMATT','film','ฟิล์ม OPPMATT','OPPMATT film','m2',9.375,9),
('film.NYLON','film','ฟิล์ม NYLON','NYLON film','m2',13.75,10),
('film.MPET','film','ฟิล์ม MPET','MPET film','m2',10.625,11),
('film.AL','film','ฟิล์ม AL','AL film','m2',18.75,12),
('film.LLDPE','film','ฟิล์ม LLDPE','LLDPE film','m2',7.5,13),
('film.EVOH','film','ฟิล์ม EVOH','EVOH film','m2',22.5,14),
('film.MCPP','film','ฟิล์ม MCPP','MCPP film','m2',10,15),
('film.CPP','film','ฟิล์ม CPP','CPP film','m2',7.5,16),
('film.PETG','film','ฟิล์ม PETG','PETG film','m2',15,17),
('film.PVC','film','ฟิล์ม PVC','PVC film','m2',11.25,18),
('film.OPS','film','ฟิล์ม OPS','OPS film','m2',12.5,19),
('plate.offset','setup','เพลทออฟเซ็ท','Offset plate','plate',812.5,20),
('mr.offset','setup','ตั้งเครื่องออฟเซ็ท + ตรวจไฟล์','Offset make-ready & preflight','form',1500,21),
('plate.flexo','setup','เพลทเฟล็กโซ','Flexo plate','color',4750,22),
('mr.flexo','setup','ตั้งเครื่องเฟล็กโซ + ตรวจไฟล์','Flexo make-ready & preflight','job',6250,23),
('cyl.gravure','setup','กระบอกพิมพ์กราเวียร์','Gravure cylinder','color',10625,24),
('mr.gravure','setup','ตั้งเครื่องกราเวียร์ + ตรวจไฟล์','Gravure make-ready & preflight','job',10000,25),
('press.offset','press','ค่าพิมพ์ออฟเซ็ท','Offset press run','m2c',1.375,26),
('press.flexo','press','ค่าพิมพ์เฟล็กโซ','Flexo press run','m2c',1.125,27),
('press.gravure','press','ค่าพิมพ์กราเวียร์','Gravure press run','m2c',0.6875,28),
('fin.gold.set','finish','ปั้มทอง · ค่าบล็อก/ตั้งเครื่อง','Gold foil · setup','job',2250,29),
('fin.gold','finish','ปั้มทอง · ต่อชิ้น','Gold foil · per piece','pc',0.3125,30),
('fin.silver.set','finish','ปั้มเงิน · ค่าบล็อก/ตั้งเครื่อง','Silver foil · setup','job',2250,31),
('fin.silver','finish','ปั้มเงิน · ต่อชิ้น','Silver foil · per piece','pc',0.3125,32),
('fin.color.set','finish','ปั้มฟอยล์สี · ค่าบล็อก/ตั้งเครื่อง','Colour foil · setup','job',2250,33),
('fin.color','finish','ปั้มฟอยล์สี · ต่อชิ้น','Colour foil · per piece','pc',0.375,34),
('fin.emboss.set','finish','ปั้มนูน · ค่าบล็อก/ตั้งเครื่อง','Emboss · setup','job',1875,35),
('fin.emboss','finish','ปั้มนูน · ต่อชิ้น','Emboss · per piece','pc',0.225,36),
('fin.deboss.set','finish','ปั้มยุบ · ค่าบล็อก/ตั้งเครื่อง','Deboss · setup','job',1875,37),
('fin.deboss','finish','ปั้มยุบ · ต่อชิ้น','Deboss · per piece','pc',0.225,38),
('fin.diecut.set','finish','ปั้มไดคัท · ค่าบล็อก/ตั้งเครื่อง','Die-cut · setup','job',3125,39),
('fin.diecut','finish','ปั้มไดคัท · ต่อชิ้น','Die-cut · per piece','pc',0.15,40),
('coat.offset.varnish','finish','เคลือบเงาวานิช','Gloss varnish','m2',7.5,41),
('coat.offset.uvfull','finish','เคลือบ UV ทั้งใบ','Full UV','m2',12.5,42),
('coat.offset.uvspot','finish','เคลือบ UV เฉพาะจุด','Spot UV','m2',15,43),
('coat.offset.uvspot.set','finish','เคลือบ UV เฉพาะจุด · ค่าบล็อก','Spot UV · setup','job',1875,44),
('coat.offset.pvcgloss','finish','เคลือบ PVC เงา','Gloss lamination','m2',22.5,45),
('coat.offset.pvcmatt','finish','เคลือบ PVC ด้าน','Matt lamination','m2',25,46),
('coat.offset.matt','finish','เคลือบด้าน','Matt coating','m2',17.5,47),
('coat.flexible.mattv','finish','เคลือบวานิชด้าน (Flexo)','Matt varnish (Flexo)','m2',2.25,48),
('coat.gravure.mattv','finish','เคลือบวานิชด้าน (Gravure)','Matt varnish (Gravure)','m2',2,49),
('coat.gravure.glossv','finish','เคลือบวานิชเงา (Gravure)','Gloss varnish (Gravure)','m2',1.5,50),
('conv.lam','convert','ลามิเนตฟิล์ม','Film lamination','lay',2.75,51),
('conv.boxglue','convert','ปะกาวขึ้นรูปกล่อง','Box folding & gluing','pc',0.4375,52),
('conv.bag','convert','ขึ้นรูปถุง + หูเชือก','Bag making + handles','pc',3.5,53),
('conv.bind','convert','เข้าเล่มไสกาว · ต่อเล่ม','Perfect binding · per book','pc',3.75,54),
('conv.bindpage','convert','เข้าเล่มไสกาว · ต่อหน้า','Perfect binding · per page','page',0.025,55),
('conv.pouch.center','convert','ขึ้นรูปซองซีลกลาง','Centre-seal pouch making','pc',0.1875,56),
('conv.pouch.gusset','convert','ขึ้นรูปซองพับข้าง','Side-gusset pouch making','pc',0.3125,57),
('conv.pouch.3side','convert','ขึ้นรูปซอง 3 ซีล','3-side seal pouch making','pc',0.225,58),
('conv.pouch.4side','convert','ขึ้นรูปซอง 4 ซีล','4-side seal pouch making','pc',0.275,59),
('conv.pouch.standup','convert','ขึ้นรูปซองตั้ง','Stand-up pouch making','pc',0.5625,60),
('conv.zip','convert','ติดซิปล็อค','Zip closure','pc',0.4375,61),
('conv.hanger','convert','เจาะรูแขวน','Hang hole','pc',0.1,62),
('conv.thomson.set','convert','ใบมีด Thomson','Thomson die','job',7500,63),
('conv.thomson','convert','ไดคัท Thomson · ต่อชิ้น','Thomson die-cut · per piece','pc',0.375,64),
('conv.sleeve','convert','ประกบตะเข็บ + ตัดชิ้น (Sleeve)','Sleeve seaming & cutting','pc',0.15,65),
('conv.labelcut','convert','สลิตและตัดชิ้นฉลาก','Label slitting & cutting','pc',0.0625,66),
('conv.slit','convert','สลิตและกรอม้วน','Slitting & rewinding','pc',0.0375,67)
on conflict (id) do nothing;
insert into public.rate_card_internal(id,staff_cost) values
('paper.pond',34),
('paper.artgloss',38),
('paper.artmatt',38),
('paper.artcard1',40),
('paper.artcard2',44),
('paper.duplex',30),
('paper.kraft',32),
('film.PET',7),
('film.BOPP',5.5),
('film.OPPMATT',7.5),
('film.NYLON',11),
('film.MPET',8.5),
('film.AL',15),
('film.LLDPE',6),
('film.EVOH',18),
('film.MCPP',8),
('film.CPP',6),
('film.PETG',12),
('film.PVC',9),
('film.OPS',10),
('plate.offset',650),
('mr.offset',1200),
('plate.flexo',3800),
('mr.flexo',5000),
('cyl.gravure',8500),
('mr.gravure',8000),
('press.offset',1.1),
('press.flexo',0.9),
('press.gravure',0.55),
('fin.gold.set',1800),
('fin.gold',0.25),
('fin.silver.set',1800),
('fin.silver',0.25),
('fin.color.set',1800),
('fin.color',0.3),
('fin.emboss.set',1500),
('fin.emboss',0.18),
('fin.deboss.set',1500),
('fin.deboss',0.18),
('fin.diecut.set',2500),
('fin.diecut',0.12),
('coat.offset.varnish',6),
('coat.offset.uvfull',10),
('coat.offset.uvspot',12),
('coat.offset.uvspot.set',1500),
('coat.offset.pvcgloss',18),
('coat.offset.pvcmatt',20),
('coat.offset.matt',14),
('coat.flexible.mattv',1.8),
('coat.gravure.mattv',1.6),
('coat.gravure.glossv',1.2),
('conv.lam',2.2),
('conv.boxglue',0.35),
('conv.bag',2.8),
('conv.bind',3),
('conv.bindpage',0.02),
('conv.pouch.center',0.15),
('conv.pouch.gusset',0.25),
('conv.pouch.3side',0.18),
('conv.pouch.4side',0.22),
('conv.pouch.standup',0.45),
('conv.zip',0.35),
('conv.hanger',0.08),
('conv.thomson.set',6000),
('conv.thomson',0.3),
('conv.sleeve',0.12),
('conv.labelcut',0.05),
('conv.slit',0.03)
on conflict (id) do nothing;

-- New materials (stickers, boards)
insert into public.rate_card(id,grp,name_th,name_en,unit,cust_cost,sort) values
('paper.greenread','paper','กระดาษถนอมสายตา (กรีนรีด)','Green-read book paper','kg',45,100),
('paper.ivory','paper','การ์ดขาวไอวอรี่','Ivory board','kg',52.5,101),
('paper.fancy','paper','กระดาษแฟนซี / สัมผัสพิเศษ','Fancy textured paper','kg',150,102),
('paper.kraftbox','paper','คราฟท์กล่อง','Kraft board','kg',37.5,103),
('paper.eflute','paper','ลูกฟูก E-flute','E-flute corrugated','m2',11.25,104),
('paper.st_gloss','paper','สติกเกอร์กระดาษขาวมัน','Gloss paper sticker','m2',15,105),
('paper.st_matt','paper','สติกเกอร์กระดาษขาวด้าน','Matt paper sticker','m2',15,106),
('paper.st_ppw','paper','สติกเกอร์ PP ขาว (กันน้ำ)','White PP sticker (waterproof)','m2',27.5,107),
('paper.st_ppc','paper','สติกเกอร์ PP ใส','Clear PP sticker','m2',30,108),
('paper.st_holo','paper','สติกเกอร์โฮโลแกรม','Holographic sticker','m2',47.5,109),
('paper.st_kraft','paper','สติกเกอร์คราฟท์','Kraft sticker','m2',20,110)
on conflict (id) do nothing;
insert into public.rate_card_internal(id,staff_cost) values
('paper.greenread',36),
('paper.ivory',42),
('paper.fancy',120),
('paper.kraftbox',30),
('paper.eflute',9),
('paper.st_gloss',12),
('paper.st_matt',12),
('paper.st_ppw',22),
('paper.st_ppc',24),
('paper.st_holo',38),
('paper.st_kraft',16)
on conflict (id) do nothing;

-- Staff can view/delete saved jobs from all devices
drop policy if exists sj_staff on public.saved_jobs;
create policy sj_staff on public.saved_jobs for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- Artwork storage bucket
insert into storage.buckets(id,name,public) values('artworks','artworks',true) on conflict (id) do nothing;
drop policy if exists art_insert on storage.objects;
create policy art_insert on storage.objects for insert to anon, authenticated with check (bucket_id='artworks');
drop policy if exists art_staff_del on storage.objects;
create policy art_staff_del on storage.objects for delete to authenticated using (bucket_id='artworks' and public.is_staff());

-- Job files (production files), separate from artwork
insert into storage.buckets(id,name,public) values('job-files','job-files',true) on conflict (id) do nothing;
drop policy if exists jf_insert on storage.objects;
create policy jf_insert on storage.objects for insert to anon, authenticated with check (bucket_id='job-files');
drop policy if exists jf_staff_del on storage.objects;
create policy jf_staff_del on storage.objects for delete to authenticated using (bucket_id='job-files' and public.is_staff());

drop policy if exists q_staff_delete on public.quotes;
create policy q_staff_delete on public.quotes for delete to authenticated using (public.is_staff());
grant delete on public.quotes to authenticated;

create table if not exists public.material_sheets(id text primary key,sizes text not null default '',updated_at timestamptz not null default now(),updated_by uuid);
alter table public.material_sheets enable row level security;
drop policy if exists ms_read on public.material_sheets;
create policy ms_read on public.material_sheets for select to anon, authenticated using (true);
drop policy if exists ms_write on public.material_sheets;
create policy ms_write on public.material_sheets for all to authenticated using (public.is_staff()) with check (public.is_staff());
grant select on public.material_sheets to anon, authenticated;
grant insert, update, delete on public.material_sheets to authenticated;
