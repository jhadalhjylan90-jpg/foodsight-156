import {mkdir,copyFile,cp} from 'node:fs/promises';
await mkdir('public',{recursive:true});
for(const file of ['index.html','app.js','logic.js','styles.css'])await copyFile(file,'public/'+file);
await cp('assets','public/assets',{recursive:true});
console.log('FoodSight static files prepared; secrets and database sources excluded.');
