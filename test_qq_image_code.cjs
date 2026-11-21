const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(__dirname+'/scripts/resource_access_probe.js','utf8');
const start=source.indexOf('function collectQQImageCode()'),end=source.indexOf('function installYYOwnerObservation(',start);
if(!(start>=0&&end>start)){console.error('FAIL QQ code-window contract: fixed code collector is missing');process.exit(1);}
const identity='a0a54fb62ee23508ae266be2c332bbf8',imageBase=0x1000000;
const fixed=[
 ['init','0x15f1164',2,['object','selector'],'object'],['dealloc','0x15f1398',2,['object','selector'],'void'],['cachePathForKey:','0x15f1534',3,['object','selector','object'],'object'],
 ['storeKeyWithDataToDisk:','0x15f1670',3,['object','selector','object'],'void'],['notifyDelegate:','0x15f17b0',3,['object','selector','object'],'void'],['queryDiskCacheOperation:','0x15f18e4',3,['object','selector','object'],'void'],
 ['storeImage:imageData:forKey:toDisk:','0x15f1b88',6,['object','selector','object','object','object','bool'],'void'],['storeImage:forKey:','0x15f1c88',4,['object','selector','object','object'],'void'],
 ['syncStoreImage:forKey:','0x15f1cd4',4,['object','selector','object','object'],'void'],['storeImage:forKey:toDisk:','0x15f1d70',5,['object','selector','object','object','bool'],'void'],
 ['imageFromKey:','0x15f1dbc',3,['object','selector','object'],'object'],['imageFromKey:fromDisk:','0x15f1dcc',4,['object','selector','object','bool'],'object'],
 ['queryDiskCacheForKey:delegate:userInfo:','0x15f1eac',5,['object','selector','object','object','object'],'void'],['removeImageForKey:','0x15f204c',3,['object','selector','object'],'void'],
 ['removeImageForKey:fromDisk:','0x15f205c',4,['object','selector','object','bool'],'void'],['clearMemory','0x15f20f8',2,['object','selector'],'void'],
 ['clearDisk','0x15f2130',2,['object','selector'],'void'],['cleanDisk','0x15f21b4',2,['object','selector'],'void'],['getSize','0x15f2424',2,['object','selector'],'int32'],
 ['getDiskCount','0x15f25f4',2,['object','selector'],'int32'],['getMemorySize','0x15f2680',2,['object','selector'],'int32'],['getMemoryCount','0x15f27ec',2,['object','selector'],'int32']
];
function table(mode){
 const result={schemaVersion:1,scope:'SDImageCacheRuntimeTables',state:mode==='partialTable'?'partial':'complete',reason:mode==='partialTable'?'selector':'none',stoppedAt:mode==='partialTable'?'none':'NSObject',classes:[{id:1,name:'SDImageCache'}],methods:fixed.map(([selector,offset,arguments,types,result])=>({class:1,kind:'instance',selector,arguments,types,result,code:{module:1,offset}}))};
 if(['compilerBoundary','nearestClassBoundary','unalignedBoundary'].includes(mode))result.methods.push(
  {class:1,kind:'instance',selector:'.cxx_destruct',arguments:2,types:['object','selector'],result:'void',code:{module:1,offset:'0x15f2800'}},
  {class:1,kind:'instance',selector:'.cxx_construct',arguments:2,types:['object','selector'],result:'object',code:{module:1,offset:'0x15f2810'}});
 if(['nearestClassBoundary','unalignedBoundary'].includes(mode))result.methods.push({class:1,kind:'class',selector:'sharedStorage',arguments:2,types:['object','selector'],result:'object',code:{module:1,offset:mode==='unalignedBoundary'?'0x15f27ee':'0x15f27f0'}});
 return result;
}
function run(mode='good'){
 let now=0,reads=0,businessCalls=0;const implementations=new Map(),methods=fixed.map(([selector,offset,arguments,types,result],index)=>({selector,offset:parseInt(offset,16),arguments,types,result,address:0x200+index*8}));const list=mode==='missingMethod'?methods.slice(0,21):methods;
 const pointer=(value)=>({value,toString(){return '0x'+this.value.toString(16)},isNull(){return this.value===0},equals(other){return !!other&&this.value===other.value},add(n){return pointer(this.value+n)},sub(other){return pointer(this.value-(other&&other.value!==undefined?other.value:other))},compare(other){return this.value-other.value},strip(){return this},readByteArray(length){reads++;if(mode==='shortRead')return new Uint8Array(length-1).buffer;const b=new Uint8Array(length).fill((this.value>>2)&255);if(mode==='unstableBytes'&&reads%2===0)b[0]^=1;return b.buffer}});
 const cls=pointer(0x300),imp=(m)=>pointer(imageBase+m.offset),impCount=new Map();
 const findMethod=(p)=>methods.find(m=>m.address===p.value),buffer=()=>({value:0,text:'',writeU32(v){this.value=v},readU32(){return this.value},writeByteArray(){this.text=''},isNull(){return false},add(n){return{readU8:()=>n<this.text.length?this.text.charCodeAt(n):0}},readUtf8String(n){return this.text.slice(0,n)}});
 const apis={objc_lookUpClass:()=>cls,sel_registerName:(p)=>p,class_getInstanceMethod:(_c,s)=>{const m=list.find(x=>x.selector===s);return m?pointer(m.address):pointer(0)},
  class_copyMethodList:(_c,out)=>{out.writeU32(list.length);return{isNull:()=>false,add(n){return{readPointer:()=>pointer(list[n/8].address)}}}},
  method_getName:(p)=>{const m=findMethod(p);return m?{selector:m.selector,equals:s=>s===m.selector}:null},sel_getName:p=>({text:p.selector}),
  method_getImplementation:(p)=>{const m=findMethod(p),calls=(impCount.get(m.selector)||0)+1;impCount.set(m.selector,calls);return mode==='changedImp'&&m.selector==='init'&&calls>1?pointer(imp(m).value+4):imp(m)},
  method_getNumberOfArguments:p=>findMethod(p).arguments,method_getArgumentType:(p,i,out)=>{out.text=findMethod(p).types[i]},method_getReturnType:(p,out)=>{out.text=findMethod(p).result},free:()=>{}};
 const context={console,CONFIG:{bundle:mode==='wrongIdentity'?'wrong':'com.tencent.mqq',version:'9.3.86',build:'9.3.86.617',uuid:identity},receipt:{qqImageMethods:table(mode)},modules:[{id:1,uuid:mode==='wrongModule'? 'ff'.repeat(16):identity,role:'app'}],
  String,Array,Map,Error,Number,Date:{now(){now+=mode==='deadline'?1000:1;return now}},call:name=>apis[name],Memory:{alloc:buffer,allocUtf8String:s=>s},Process:{pointerSize:8,
   findModuleByAddress:p=>p.value>=imageBase&&p.value<imageBase+0x2000000?{base:pointer(imageBase),size:0x2000000}:null,
   findRangeByAddress:p=>({base:pointer(p.value-0x100),size:mode==='crossRange'?8:0x20000,protection:mode==='writable'?'rwx':mode==='nonExecutable'?'r--':'r-x'})},
  moduleAt:p=>({module:mode==='wrongModule'?2:1,offset:pointer(p.value-imageBase).toString()}),cstring:p=>p.text,capabilityType:s=>s,Checksum:{compute:(kind,data)=>{assert.equal(kind,'sha256');return require('node:crypto').createHash('sha256').update(Buffer.from(data)).digest('hex')}} ,invokeBusinessMethod(){businessCalls++;throw Error('must not be invoked')}};
 vm.createContext(context);vm.runInContext(source.slice(start,end),context);const out=context.collectQQImageCode();assert.equal(businessCalls,0);
 if(['good','compilerBoundary','nearestClassBoundary'].includes(mode)){
  assert.equal(out.state,'complete',JSON.stringify(out));assert.equal(out.reason,'none');assert.equal(out.methods.length,22);assert.equal(reads,44);
  assert.equal(out.methods[0].selector,'init');assert.equal(out.methods.at(-1).selector,'getMemoryCount');assert.equal(out.methods.at(-1).code.windowLength,{good:160,compilerBoundary:20,nearestClassBoundary:4}[mode]);
  assert(out.methods.every(row=>row.code.protection==='r-x'&&row.code.sha256Before===row.code.sha256After&&row.code.bytesHex.length===row.code.windowLength*2));
 }else{
  assert.equal(out.state,mode==='wrongIdentity'?'unsupportedIdentity':'partial',mode);assert.equal(out.methods.length,0,mode+' must not expose unverified windows');
 }
 return {qqImageMethods:context.receipt.qqImageMethods,qqImageCode:out};
}
if(process.argv[2]==='--receipt'){
 assert(['good','compilerBoundary','nearestClassBoundary'].includes(process.argv[3]));
 process.stdout.write(JSON.stringify(run(process.argv[3])));
}else{
 for(const mode of ['good','compilerBoundary','nearestClassBoundary','unalignedBoundary','wrongIdentity','missingMethod','partialTable','wrongModule','writable','nonExecutable','crossRange','shortRead','unstableBytes','deadline','changedImp'])run(mode);
 console.log('PASS QQ bounded code windows: 15 scenarios, 22 exact identity/ABI/IMP bindings, 160/20/4-byte tail windows, read-only executable regions, stable SHA-256, closed failures, no business calls');
}
