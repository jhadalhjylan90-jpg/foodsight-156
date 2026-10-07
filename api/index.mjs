import crypto from 'node:crypto';
const RPC=new Set(['dashboard','forecast','place_order','receive_stock','record_waste','count_stock','transfer_stock','receive_bundle']);
const send=(res,status,body)=>{res.statusCode=status;res.setHeader('Content-Type','application/json; charset=utf-8');res.setHeader('Cache-Control','no-store');res.end(JSON.stringify(body));};
function signature(key,stamp){return crypto.createHmac('sha256',key).update('foodsight-csrf:'+stamp).digest('hex');}
function validToken(key,token){if(typeof token!=='string')return false;const [stamp,sig]=token.split('.');if(!/^\d+$/.test(stamp)||!/^[a-f0-9]{64}$/.test(sig||'')||Math.abs(Date.now()-Number(stamp))>86400000)return false;return crypto.timingSafeEqual(Buffer.from(sig,'hex'),Buffer.from(signature(key,stamp),'hex'));}
export default async function handler(req,res){
 try{
 const key=process.env.SUPABASE_SECRET_KEY||'';
 const url=process.env.SUPABASE_URL||'https://ksemtrbeouvagobyrbvi.supabase.co';
 const name=req.query?.route||new URL(req.url,'https://foodsight.invalid').searchParams.get('route');
 if(process.env.FOODSIGHT_BRIDGE_KEY){
  const allowed=new Set(['status',...RPC,'save_plan','purchase']);
  if(!allowed.has(name))return send(res,404,{error:'عملية غير معروفة'});
  if((name==='status'&&req.method!=='GET')||(name!=='status'&&req.method!=='POST'))return send(res,405,{error:'طلب غير صالح'});
  if(req.headers.origin){const origin=new URL(req.headers.origin);if(origin.protocol!=='https:'||origin.host!==req.headers.host)return send(res,403,{error:'المصدر غير مسموح'});}
  if(req.method==='POST'&&!String(req.headers['content-type']||'').startsWith('application/json'))return send(res,415,{error:'طلب غير صالح'});
  const body=req.method==='POST'?(typeof req.body==='string'?req.body:JSON.stringify(req.body||{})):undefined;
  if(body&&Buffer.byteLength(body)>100000)return send(res,413,{error:'الطلب كبير جدًا'});
  const upstream=await fetch(url+'/functions/v1/foodsight-vercel-bridge?route='+encodeURIComponent(name),{
   method:req.method,
   headers:{'content-type':'application/json','x-foodsight-bridge':process.env.FOODSIGHT_BRIDGE_KEY,'x-foodsight-origin':'https://'+req.headers.host,'x-foodsight-token':req.headers['x-foodsight-token']||''},
   body,signal:AbortSignal.timeout(28000)
  });
  const data=await upstream.json().catch(()=>({error:'تعذر الاتصال بقاعدة البيانات'}));
  return send(res,upstream.status,data);
 }
 if(name==='status'&&req.method==='GET'){const stamp=String(Date.now());return send(res,200,{hosted:true,configured:!!key,token:key?stamp+'.'+signature(key,stamp):''});}
 if(name==='configure')return send(res,404,{error:'إعداد الاتصال يتم في متغيرات بيئة Vercel فقط'});
 if(req.method!=='POST')return send(res,405,{error:'طلب غير صالح'});
 if(!key)return send(res,503,{error:'أضف مفتاح الاتصال إلى إعدادات الخادم في Vercel'});
 if(!validToken(key,req.headers['x-foodsight-token']))return send(res,403,{error:'حدّث الصفحة ثم حاول مجددًا'});
 if(req.headers.origin){const origin=new URL(req.headers.origin);if(origin.protocol!=='https:'||origin.host!==req.headers.host)return send(res,403,{error:'المصدر غير مسموح'});}
 if(!String(req.headers['content-type']||'').startsWith('application/json'))return send(res,415,{error:'طلب غير صالح'});
 const body=typeof req.body==='string'?JSON.parse(req.body):req.body||{};
 if(JSON.stringify(body).length>100000)return send(res,413,{error:'الطلب كبير جدًا'});
 let endpoint,prefer,payload=body;
 if(RPC.has(name)){
 endpoint='rpc/'+name;
 if(name==='forecast'&&(!Number.isInteger(body.p_days)||body.p_days<1||body.p_days>28))throw Error('فترة التنبؤ غير صحيحة');
 if(name==='place_order'&&(!Array.isArray(body.p_items)||body.p_items.length>50||body.p_items.some(x=>!Number.isInteger(x.quantity)||x.quantity<1||x.quantity>1000)))throw Error('كمية الطلب غير صحيحة');
 }else if(name==='save_plan'){
 const rows=body.rows;
 if(!Array.isArray(rows)||!rows.length||rows.length>500)throw Error('خطة غير صالحة');
 for(const r of rows)if(![1,2,3].includes(r.branch_id)||![1,2,3,4,5].includes(r.meal_id)||!Number.isInteger(r.quantity)||r.quantity<0||r.quantity>10000||!/^\d{4}-\d{2}-\d{2}$/.test(r.plan_date))throw Error('بيانات الخطة غير صحيحة');
 endpoint='preparation_plans?on_conflict=branch_id,meal_id,plan_date';prefer='resolution=merge-duplicates,return=representation';payload=rows.map(({branch_id,meal_id,plan_date,quantity})=>({branch_id,meal_id,plan_date,quantity}));
 }else if(name==='purchase'){
 const {branch_id,ingredient_id,quantity,expected_on}=body;
 if(![1,2,3].includes(branch_id)||!Number.isInteger(ingredient_id)||ingredient_id<1||ingredient_id>11||!Number.isFinite(quantity)||quantity<=0||quantity>10000000||!/^\d{4}-\d{2}-\d{2}$/.test(expected_on))throw Error('بيانات التوريد غير صحيحة');
 endpoint='purchase_orders';payload={branch_id,ingredient_id,quantity,expected_on};prefer='return=representation';
 }else return send(res,404,{error:'عملية غير معروفة'});
 const headers={apikey:key,'Content-Type':'application/json'};
 if(key.startsWith('eyJ'))headers.Authorization='Bearer '+key;
 if(prefer)headers.Prefer=prefer;
 const r=await fetch(url+'/rest/v1/'+endpoint,{method:'POST',headers,body:JSON.stringify(payload),signal:AbortSignal.timeout(25000)});
 const data=await r.json().catch(()=>null);
 if(!r.ok)return send(res,400,{error:data?.message||'تعذر تنفيذ العملية'});
 return send(res,200,data);
 }catch(e){return send(res,400,{error:e.name==='TimeoutError'?'انتهت مهلة الاتصال؛ حاول مجددًا':e.message});}
}
