# ตั้งค่าแจ้งเตือน LINE OA (@922akkqt)

เมื่อลูกค้ากด **ขอใบเสนอราคา** หรือ **สั่งผลิตเลย** ระบบจะส่งข้อความเข้า LINE ของเจ้าหน้าที่/กลุ่มทีมขายอัตโนมัติ

## 1. เปิด Messaging API
1. เข้า https://manager.line.biz → เลือกบัญชี @922akkqt
2. ตั้งค่า → Messaging API → **เปิดใช้งาน Messaging API** (เลือก/สร้าง Provider)
3. ตั้งค่า → การตอบกลับ → เปิด **Webhook** · ปิด "ข้อความตอบกลับอัตโนมัติ" (ถ้าไม่ต้องการ)
4. ตั้งค่า → บัญชี → เปิด **อนุญาตให้บัญชีเข้าร่วมกลุ่ม** (ถ้าจะใช้กลุ่ม)

## 2. คัดลอกรหัสจาก LINE Developers
https://developers.line.biz/console → Provider → Channel ของ @922akkqt
- แท็บ **Basic settings** → Channel secret → คัดลอก
- แท็บ **Messaging API** → Channel access token (long-lived) → Issue → คัดลอก

## 3. ใส่ Secret ใน Supabase
Supabase → Project Settings → Edge Functions → Secrets (หรือ Edge Functions → Secrets)
- `LINE_TOKEN` = Channel access token
- `LINE_SECRET` = Channel secret

## 4. Deploy webhook และหารหัสผู้รับ
```
supabase functions deploy line-webhook --no-verify-jwt
```
1. LINE Developers → Messaging API → **Webhook URL** = `https://<project-ref>.supabase.co/functions/v1/line-webhook` → Verify → เปิด Use webhook
2. เชิญ @922akkqt เข้ากลุ่ม LINE ทีมขาย (หรือแอดเพื่อนแบบส่วนตัว)
3. พิมพ์ `id` ในกลุ่ม → OA จะตอบ `groupId: Cxxxxxxxx...`
4. ใส่ Secret `LINE_TO` = ค่าที่ได้ (หลายผู้รับคั่นด้วย ,)

## 5. Deploy estimate ใหม่
```
supabase functions deploy estimate --no-verify-jwt
```
ทดสอบ: กดขอใบเสนอราคาจากหน้าเว็บ → ข้อความควรเข้ากลุ่มภายในไม่กี่วินาที
ถ้าไม่เข้า ดู Supabase → Edge Functions → estimate → Logs (ข้อความ "LINE push failed")

> หมายเหตุ: ข้อความ push นับรวมในโควตาข้อความรายเดือนของแพ็กเกจ LINE OA
