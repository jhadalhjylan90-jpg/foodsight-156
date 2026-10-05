import http from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import crypto from 'node:crypto';
const root = path.dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(await readFile(path.join(root, 'config.json'), 'utf8'));
const PORT = Number(process.env.PORT || 3000);
const url = config.supabaseUrl;
let key = process.env.SUPABASE_SECRET_KEY || '';
const token = crypto.randomBytes(32).toString('hex');
const RPC = new Set(['dashboard', 'forecast', 'place_order', 'receive_stock', 'record_waste', 'count_stock', 'transfer_stock', 'receive_bundle']);
function send(res, status, body) {
  res.writeHead(status, {'Content-Type':'application/json; charset=utf-8', 'Cache-Control':'no-store'});
  res.end(JSON.stringify(body));
}
async function db(endpoint, method='POST', body, prefer, connectionKey=key) {
  const headers = {apikey:connectionKey, 'Content-Type':'application/json'};
  if (connectionKey.startsWith('eyJ')) headers.Authorization = `Bearer ${connectionKey}`;
  if (prefer) headers.Prefer = prefer;
  const response = await fetch(`${url}/rest/v1/${endpoint}`, {
    method, headers, body:body===undefined?undefined:JSON.stringify(body), signal:AbortSignal.timeout(30000)
  });
  const raw = await response.text();
  let data;
  try { data=raw?JSON.parse(raw):null; } catch { throw Error('تعذر قراءة استجابة قاعدة البيانات'); }
  if (!response.ok) throw Error(data?.message || 'فشل الاتصال بقاعدة البيانات');
  return data;
}
const staticFiles = new Map([
  ['/','index.html'], ['/index.html','index.html'], ['/app.js','app.js'], ['/logic.js','logic.js'],
  ['/styles.css','styles.css'], ['/assets/logo.png','assets/logo.png'], ['/assets/icon.png','assets/icon.png'],
  ['/assets/regular.ttf','assets/regular.ttf'], ['/assets/bold.ttf','assets/bold.ttf']
]);
const mime = {'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png','.ttf':'font/ttf'};
const server = http.createServer(async (req,res) => {
  res.setHeader('X-Content-Type-Options','nosniff');
  res.setHeader('Referrer-Policy','no-referrer');
  res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'");
  try {
    const host=req.headers.host;
    if (host!==`localhost:${PORT}` && host!==`127.0.0.1:${PORT}`) return send(res,403,{error:'المضيف غير مسموح'});
    const pathname=new URL(req.url,`http://${host}`).pathname;
    if (pathname==='/api/status' && req.method==='GET') return send(res,200,{configured:!!key,token});
    if (pathname.startsWith('/api/')) {
      if (req.method!=='POST') return send(res,405,{error:'طلب غير صالح'});
      if (req.headers['x-foodsight-token']!==token) return send(res,403,{error:'أعد تحميل الصفحة'});
      if (req.headers.origin && !new Set([`http://localhost:${PORT}`,`http://127.0.0.1:${PORT}`]).has(req.headers.origin)) return send(res,403,{error:'المصدر غير مسموح'});
      let raw='';
      for await (const chunk of req) { raw+=chunk; if(raw.length>100000) return send(res,413,{error:'الطلب كبير جدًا'}); }
      const body=JSON.parse(raw||'{}');
      const name=pathname.slice(5);
      if (name==='configure') {
        if (key) return send(res,409,{error:'الاتصال معدّ بالفعل. لتغييره عدّل ملف .env ثم أعد التشغيل.'});
        const candidate=String(body.key||'').trim();
        if (!/^[A-Za-z0-9_.-]{30,2000}$/.test(candidate) || !(candidate.startsWith('sb_secret_') || candidate.startsWith('eyJ'))) throw Error('أدخل Secret key أو service_role من إعدادات Supabase');
        const rows=await db('branches?select=id&limit=1','GET',undefined,undefined,candidate);
        if (!Array.isArray(rows) || rows.length!==1) throw Error('هذا المفتاح لا يملك صلاحية الاتصال المطلوبة');
        await writeFile(path.join(root,'.env'),`SUPABASE_SECRET_KEY=${candidate}\nPORT=${PORT}\n`,{mode:0o600});
        key=candidate;
        return send(res,200,{ok:true});
      }
      if (!key) return send(res,503,{error:'أكمل ربط قاعدة البيانات مرة واحدة أولًا'});
      if (RPC.has(name)) return send(res,200,await db('rpc/'+name,'POST',body));
      if (name==='save_plan') {
        const rows=body.rows;
        if (!Array.isArray(rows)||!rows.length||rows.length>500) throw Error('خطة غير صالحة');
        for (const r of rows) if (![1,2,3].includes(r.branch_id)||![1,2,3,4,5].includes(r.meal_id)||!Number.isInteger(r.quantity)||r.quantity<0||!/^\d{4}-\d{2}-\d{2}$/.test(r.plan_date)) throw Error('بيانات الخطة غير صحيحة');
        return send(res,200,await db('preparation_plans?on_conflict=branch_id,meal_id,plan_date','POST',rows.map(({branch_id,meal_id,plan_date,quantity})=>({branch_id,meal_id,plan_date,quantity})),'resolution=merge-duplicates,return=representation'));
      }
      if (name==='purchase') {
        const {branch_id,ingredient_id,quantity,expected_on}=body;
        if (![1,2,3].includes(branch_id)||!Number.isInteger(ingredient_id)||!Number.isFinite(quantity)||quantity<=0||!/^\d{4}-\d{2}-\d{2}$/.test(expected_on)) throw Error('بيانات التوريد غير صحيحة');
        return send(res,200,await db('purchase_orders','POST',{branch_id,ingredient_id,quantity,expected_on},'return=representation'));
      }
      return send(res,404,{error:'عملية غير معروفة'});
    }
    if (req.method!=='GET') return send(res,405,{error:'طلب غير صالح'});
    const file=staticFiles.get(pathname);
    if (!file) return send(res,404,{error:'الصفحة غير موجودة'});
    const bytes=await readFile(path.join(root,file));
    res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream'});
    res.end(bytes);
  } catch (e) {
    send(res,400,{error:e.name==='TimeoutError'?'انتهت مهلة الاتصال، حاول مجددًا':e.message});
  }
});
server.listen(PORT,'127.0.0.1',()=>console.log(`FoodSight: http://localhost:${PORT}\n${key?'Connected configuration loaded.':'Complete one-time database setup in the app.'}`));
