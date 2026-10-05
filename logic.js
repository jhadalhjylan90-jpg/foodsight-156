export const DAY=86400000;
export function dateKey(date=new Date()){return new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Riyadh',year:'numeric',month:'2-digit',day:'2-digit'}).format(date);}
export function addDays(d,n){return new Date(new Date(d+'T12:00:00Z').getTime()+n*DAY).toISOString().slice(0,10);}
export function unitName(u){return {g:'غ',ml:'مل',piece:'حبة',kg:'كجم',l:'لتر',pack:'عبوة'}[u]||u;}
export function displayQty(q,u){const divisor=(u==='g'||u==='ml')&&Math.abs(q)>=1000?1000:1;return new Intl.NumberFormat('ar-SA',{maximumFractionDigits:2}).format(q/divisor)+' '+unitName(divisor===1000?(u==='g'?'kg':'l'):u);}
export function requirements(items,recipes){const sums=new Map();for(const item of items){for(const r of recipes.filter(r=>r.meal_id===item.meal_id)){sums.set(r.ingredient_id,(sums.get(r.ingredient_id)||0)+r.quantity*item.quantity);}}return [...sums].map(([ingredient_id,quantity])=>({ingredient_id,quantity}));}
// Simulates FEFO by branch and day. Does not pool stock across branches.
// Pending deliveries have unknown expiry: use demo shelf duration and label that assumption in UI.
export function supplyPlan(data,forecast,today=dateKey()){
 const rows=[];
 const days=[...new Set(forecast.days.map(x=>x.day))].sort();
 for(const branch of data.branches){for(const ing of data.ingredients){
 const relevant=forecast.days.filter(x=>x.branch_id===branch.id);if(!relevant.length)continue;
 const lots=data.lots.filter(l=>l.branch_id===branch.id&&l.ingredient_id===ing.id).map(l=>({q:Number(l.remaining),expiry:l.expires_at,arrival:l.received_at.slice(0,10),actual:true}));
 for(const p of data.purchases.filter(p=>p.branch_id===branch.id&&p.ingredient_id===ing.id&&p.status==='pending'))lots.push({q:Number(p.quantity),expiry:addDays(p.expected_on,ing.demo_shelf_days)+'T00:00:00+03:00',arrival:p.expected_on,actual:false});
 let need=0,missing=0,used=0,firstShort=null,expiring=0;const daily=[];
 for(const day of days){
 const noon=day+'T12:00:00+03:00';
 const menu=relevant.filter(x=>x.day===day).map(x=>({meal_id:x.meal_id,quantity:Math.max(0,Number(x.planned)-(day===today?Number(x.actual_sold||0):0))}));
 const required=requirements(menu,data.recipes).find(x=>x.ingredient_id===ing.id)?.quantity||0;need+=required;
 for(const lot of lots){if(lot.q>0&&lot.actual&&new Date(lot.expiry)<=new Date(noon)){expiring+=lot.q;lot.q=0;}}
 let left=required;
 for(const lot of lots.sort((a,b)=>a.expiry.localeCompare(b.expiry))){if(lot.q<=0||lot.arrival>day||new Date(lot.expiry)<=new Date(noon))continue;const take=Math.min(lot.q,left);lot.q-=take;left-=take;used+=take;if(left<=0)break;}
 if(left>0){missing+=left;firstShort??=day;}daily.push({day,required,short:left});
 }
 const quantity=Math.ceil(missing/Number(ing.pack_size))*Number(ing.pack_size);
 rows.push({branch_id:branch.id,ingredient_id:ing.id,need,covered:used,missing,quantity,firstShort,orderBy:firstShort?addDays(firstShort,-ing.lead_days):null,expiring,daily});
 }}return rows;
}
export function escapeHTML(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
