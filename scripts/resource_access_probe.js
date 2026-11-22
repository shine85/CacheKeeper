'use strict';
// Temporary, explicit developer window. Never returns path, key, message or content.
// The host replaces this literal after validating the requested target/window.
const CONFIG = __CK_RESOURCE_CONFIG__;
const APPS = {
    'com.baidu.netdisk': 'documents',
    'com.tencent.mqq': 'documents',
    'com.ss.iphone.ugc.Aweme': 'support',
    'app.swiftgram.ios': 'swiftgroup'
};
const MAX_EVENTS = 512, MAX_MODULES = 64, MAX_NODES = 128;
const listeners = [], modules = [], nodes = [], events = [], apiCoverage = [];
const moduleIDs = new Map(), nodeIDs = new Map(), objectIDs = new Map();
const inputCoverage = {calls: 0, reentrant: 0, relative: 0, outside: 0, matched: 0, errors: 0, limited: 0};
let busy = false, ended = false, endRequested = false, dropped = 0, timer = null, objcHits = 0, calls = 0;
const setupDiagnostic = {phase: 'setup', error: 'none', methodCount: 0, matchedMethods: 0};
function queryAttachError(error) {
    const text = error instanceof Error ? error.message : '';
    if (/^unable to intercept (?:function|instruction) at 0x[0-9a-fA-F]+; no instruction could be decoded there$/.test(text)) return 'invalidInstruction';
    // Frida's generic relocation failure does not establish an Objective-C ABI mismatch.
    if (/^unable to intercept (?:function|instruction) at 0x[0-9a-fA-F]+; please file a bug$/.test(text)) return 'interceptionFailed';
    if (text === 'already attached to this function') return 'alreadyAttached';
    if (text === 'not permitted by code-signing policy') return 'codeSigningPolicy';
    if (text === 'wrong type') return 'wrongType';
    return 'unclassified';
}
const receipt = {schemaVersion: 1, scope: 'privateResourceAccess', bundle: CONFIG.bundle,
    state: 'failed', reason: 'setup', modules, nodes, events, image: null, inputCoverage,
    counters: {matched: 0, dropped: 0, objcObserved: 0},
    observation: 'passiveAppCalls', resourceContract: 'notGranted', physicalRelease: 'notMeasured',
    coverage: 'fixedAPIsAbsolutePathsRenameSourceOnly', apiCoverage, queryCoverage: 'notApplicable',
    cleanup: {state: 'notStarted', failures: 0}, ownerIdentity: 'windowPointerAliasOnly', swiftOwner: 'blockedABI'};
function address(name) { const p = Module.findGlobalExportByName(name); if (p === null) throw Error('api'); return p; }
function call(name, result, args) { return new NativeFunction(address(name), result, args); }
function cstring(p, limit = 4096) {
    if (p.isNull()) throw Error('null');
    for (let n = 0; n < limit; n++) { if (p.add(n).readU8() === 0) return p.readUtf8String(n); }
    throw Error('bound');
}
function openIntent(api, args) {
    const unknown = {api, access: 'unknown', create: null, truncate: null, append: null};
    if (api === 'fopen') {
        let mode;
        try { mode = cstring(args[1], 8); } catch (_) { return unknown; }
        if (!/^[rwa](?:b?\+?|\+b)$/.test(mode)) return unknown;
        return {api, access: mode.includes('+') ? 'readWrite' : mode[0] === 'r' ? 'readOnly' : 'writeOnly',
            create: mode[0] !== 'r', truncate: mode[0] === 'w', append: mode[0] === 'a'};
    }
    // Constants verified in the project's iPhoneOS SDK sys/fcntl.h.
    const flags = args[api === 'openat' ? 2 : 1].toUInt32();
    return {api, access: (flags & 0x40008000) !== 0 ? 'unknown' : ['readOnly', 'writeOnly', 'readWrite', 'unknown'][flags & 3],
        create: (flags & 0x200) !== 0, truncate: (flags & 0x400) !== 0, append: (flags & 8) !== 0};
}
function uuid(base) {
    if (base.readU32() !== 0xfeedfacf) throw Error('macho');
    const count = base.add(16).readU32(), size = base.add(20).readU32();
    if (count > 2048 || size > 262144) throw Error('bounds');
    let offset = 32, found = null;
    for (let n = 0; n < count; n++) {
        if (offset + 8 > 32 + size) throw Error('bounds');
        const p = base.add(offset), length = p.add(4).readU32();
        if (length < 8 || length % 8 || offset + length > 32 + size) throw Error('bounds');
        if (p.readU32() === 0x1b) {
            if (length !== 24 || found !== null) throw Error('uuid');
            found = Array.from(new Uint8Array(p.add(8).readByteArray(16)), b => b.toString(16).padStart(2, '0')).join('');
        }
        offset += length;
    }
    if (offset !== 32 + size || found === null) throw Error('uuid');
    return found;
}
function moduleOrigin(path) {
    const unknown = {location: 'unknown', library: 'unknown'};
    if (typeof path !== 'string' || !path.startsWith('/') || path.length > 4096) return unknown;
    const parts = path.split('/');
    if (parts.slice(1).some(part => !part || part === '.' || part === '..')) return {location: 'other', library: 'unknown'};
    const system = path.startsWith('/System/Library/') || path.startsWith('/usr/lib/');
    const libraries = {
        'Postbox.framework/Postbox': 'postbox', 'PostboxFramework.framework/PostboxFramework': 'postbox',
        'TelegramUI.framework/TelegramUI': 'telegramUI', 'TelegramUIFramework.framework/TelegramUIFramework': 'telegramUI',
        'WCDB.framework/WCDB': 'wcdb', 'MMKV.framework/MMKV': 'mmkv',
        'AwemeCore.framework/AwemeCore': 'awemeCore', 'EffectSDK.framework/EffectSDK': 'effectSDK'
    };
    const library = path === '/usr/lib/libsqlite3.dylib' ? 'sqlite3' :
        libraries[parts.slice(-2).join('/')] || 'unknown';
    // A fixed technical label is only a loader-origin hint. Keep the UUID and
    // offsets as the identity evidence; never serialize the module path/name.
    return {location: system ? 'appleSystem' : 'other', library};
}
function moduleAt(pc) {
    const p = pc.strip('ia'), module = Process.findModuleByAddress(p);
    if (module === null) return null;
    const key = module.base.toString();
    if (!moduleIDs.has(key)) {
        if (modules.length >= MAX_MODULES) { dropped++; return null; }
        const id = modules.length + 1;
        modules.push({id, uuid: uuid(module.base), role: module.base.equals(mainBase) ? 'app' : 'other', origin: moduleOrigin(module.path)});
        moduleIDs.set(key, id);
    }
    return {module: moduleIDs.get(key), offset: p.sub(module.base).toString()};
}
function descriptorHint(path) {
    const leaf=path.substring(path.lastIndexOf('/')+1).toLowerCase();
    if (/\.(?:db|sqlite|sqlite3)-(?:wal|shm|journal)$/.test(leaf)) return 'databaseSidecarName';
    if (/\.(?:db|sqlite|sqlite3)$/.test(leaf)) return 'databaseName';
    if (/\.(?:jpg|jpeg|png|webp|heic|gif)$/.test(leaf)) return 'imageName';
    if (/\.(?:mp4|mov|m4a|mp3|aac)$/.test(leaf)) return 'mediaName';
    if (/\.(?:json|plist)$/.test(leaf)) return 'structuredName';
    if (/\.(?:log|alog)$/.test(leaf)) return 'logName';
    return 'unknown';
}
function descriptorResult(api,text) {
    const n=Number(text);
    if (!Number.isSafeInteger(n) || n < -1) return {outcome:'unavailable',bytes:null};
    if (n===-1) return {outcome:'failed',bytes:null};
    if (api==='ftruncate') return {outcome:n===0 ? 'returned':'unavailable',bytes:null};
    return {outcome:'returned',bytes:n};
}
function installDescriptorObservation(target) {
    const apis=['write','pwrite','writev','mmap','ftruncate'],objects=[],keys=new Map();
    const empty=state=>({state,listed:0,vnode:0,outside:0,unresolved:0,matched:0,errors:0,objects:[]});
    const d={schemaVersion:1,scope:'selectedRootOpenDescriptors',state:'partial',coverage:'vnodeFDsAndFixedCallsNotMappingsOrReferences',objects,
        before:empty('unavailable'),after:empty('unavailable'),apiCoverage:[],events:[],
        counters:{calls:0,reentrant:0,outside:0,unresolved:0,matched:0,errors:0,limited:0,dropped:0}};
    receipt.descriptorObservation=d;
    let stat,fdpath,list;
    function metadata(fd) {
        const buffer=Memory.alloc(144);
        if (stat(fd,buffer)!==0) return null;
        const mode=buffer.add(4).readU16();
        if ((mode&0xf000)!==0x8000) return null;
        const size=Number(buffer.add(96).readS64().toString()),blocks=Number(buffer.add(104).readS64().toString());
        if (!Number.isSafeInteger(size)||size<0||!Number.isSafeInteger(blocks)||blocks<0||blocks>Math.floor(Number.MAX_SAFE_INTEGER/512)) return null;
        return {key:[buffer.readS32(),buffer.add(8).readU64().toString(),buffer.add(80).readS64().toString(),buffer.add(88).readS64().toString()].join(':'),
            sample:{logicalBytes:size,allocatedBytes:blocks*512,links:buffer.add(6).readU16()}};
    }
    function identify(fd) {
        if (fd<0) return {state:'unresolved'};
        const first=metadata(fd);if (first===null) return {state:'unresolved'};
        const path=Memory.alloc(4096);
        if (fdpath(fd,50,path)!==0) return {state:'unresolved'};
        const text=cstring(path),node=target(text);
        if (node===null) return {state:'outside'};
        const last=metadata(fd);if(last===null||first.key!==last.key) return {state:'unresolved'};
        const key=first.key+':'+node;
        if (!keys.has(key)) {
            if(objects.length>=128) return {state:'limited'};
            const id=objects.length+1;keys.set(key,id);objects.push({id,node,hint:descriptorHint(text)});
        }
        return {state:'matched',object:keys.get(key),node,key:first.key,sample:last.sample};
    }
    function snapshot() {
        const row=empty('complete');
        try {
            const buffer=Memory.alloc(2048*8),bytes=list(Process.id,1,0,buffer,2048*8);
            if(bytes<=0||bytes%8||bytes>2048*8) {row.state='readError';return row;}
            if(bytes===2048*8) row.state='entryLimit';
            const until=Date.now()+750;
            for(let at=0;at<bytes;at+=8) {
                if(Date.now()>until){row.state='timeLimit';break;}
                row.listed++;
                if(buffer.add(at+4).readU32()!==1) continue;
                row.vnode++;
                try {
                    const value=identify(buffer.add(at).readS32());
                    if(value.state==='matched') {
                        if(row.objects.length>=128){row.unresolved++;row.state='entryLimit';break;}
                        row.matched++;row.objects.push({object:value.object,node:value.node,sample:value.sample});
                    }
                    else if(value.state==='outside') row.outside++;
                    else if(value.state==='limited') {row.unresolved++;row.state='entryLimit';break;}
                    else row.unresolved++;
                } catch(_){row.errors++;}
            }
        } catch(_){row.state='readError';}
        if(row.state==='complete'&&(row.errors||row.unresolved)) row.state='partial';
        return row;
    }
    try {
        stat=call('fstat','int',['int','pointer']);
        // Darwin arm64 passes variadic arguments on the stack, not as fixed args.
        fdpath=call('fcntl','int',['int','int','...','pointer']);
        list=call('proc_pidinfo','int',['int','int','uint64','pointer','int']);
        busy=true;try{d.before=snapshot();}finally{busy=false;}
        for(const api of apis) {
            const p=Module.findGlobalExportByName(api),row={api,state:p===null?'missing':'installing'};d.apiCoverage.push(row);
            if(p===null)continue;
            try {
                listeners.push(Interceptor.attach(p,{
                    onEnter(args){
                        this.fdRecord=null;if(ended||endRequested)return;
                        if(busy){d.counters.reentrant=Math.min(Number.MAX_SAFE_INTEGER,d.counters.reentrant+1);return;}
                        if(d.counters.calls>=4096){d.counters.limited=1;return;}
                        const saved=this.errno;busy=true;
                        try{
                            d.counters.calls++;
                            const fd=args[api==='mmap'?4:0].toInt32(),value=identify(fd);
                            if(value.state==='outside'){d.counters.outside++;return;}
                            if(value.state==='unresolved'){d.counters.unresolved++;return;}
                            if(value.state==='limited'){d.counters.unresolved++;d.counters.limited=1;return;}
                            const frames=Thread.backtrace(this.context,Backtracer.ACCURATE).slice(0,8).map(moduleAt).filter(x=>x!==null);
                            this.fdRecord={fd,key:value.key,event:{api,object:value.object,node:value.node,frames}};d.counters.matched++;
                        }catch(_){d.counters.errors++;}finally{busy=false;this.errno=saved;}
                    },
                    onLeave(value){
                        const r=this.fdRecord;if(!r||ended)return;
                        if(d.events.length>=128){d.counters.dropped++;return;}
                        const saved=this.errno;busy=true;
                        try{
                            const outcome=api==='mmap'?{outcome:value.equals(ptr('0xffffffffffffffff'))?'failed':'returned',bytes:null}:
                                descriptorResult(api,api==='ftruncate'?String(value.toInt32()):new Int64(value.toString()).toString());
                            const after=metadata(r.fd);
                            d.events.push({...r.event,...outcome,identityAfter:after===null?'unavailable':after.key===r.key?'same':'changed'});
                        }catch(_){d.counters.dropped++;}finally{busy=false;this.errno=saved;}
                    }
                }));row.state='installed';
            }catch(_){row.state='failed';}
        }
    }catch(_){/* Explicit unavailable/partial state; original path observation continues. */}
    return ()=>{
        if(list&&stat&&fdpath){busy=true;try{d.after=snapshot();}finally{busy=false;}}
        // Calls still in flight at the window boundary have no observed result.
        d.counters.dropped=d.counters.matched-d.events.length;
        const covered=d.apiCoverage.length===5&&d.apiCoverage.every(x=>x.state==='installed');
        d.state=covered&&d.before.state==='complete'&&d.after.state==='complete'&&!d.counters.unresolved&&!d.counters.errors&&!d.counters.dropped&&!d.counters.limited?'complete':'partial';
        keys.clear();
    };
}
function capabilityType(text) {
    const value=text.replace(/^[rnNoORV]+/,'');
    if(value==='@?')return 'block';if(value[0]==='@')return 'object';if(value[0]==='^')return 'pointer';
    return {':':'selector','v':'void','B':'bool','i':'int32','I':'uint32','q':'int64','Q':'uint64','d':'double','f':'float','#':'class','c':'int8','C':'uint8','s':'int16','S':'uint16','*':'cstring'}[value]||'other';
}
function collectCapabilityMetadata() {
    const names=['SDImageCache','SDDiskCache','YYCache','YYDiskCache','YYKVStorage','PINCache','PINDiskCache','MMKV','WCTDatabase','FMDatabase','TransFileListDAO','BDPanThumbnailCacheCleaner'];
    const selectors=['initWithPath:','initWithName:','initWithNamespace:diskCacheDirectory:config:','sharedCache','sharedInstance','diskCache','diskCachePath','path','ioQueue',
        'removeAllData','removeAllObjects','removeAllObjectsWithBlock:','removeAllObjectsWithProgressBlock:endBlock:','trimToCost:','trimToAge:',
        'setObject:forKey:','setData:forKey:','setExtendedData:forKey:','totalCost','totalCount','clearMemoryCache','clearDiskCache','close','removeAllItems'];
    const result={state:'complete',classes:[]};const until=Date.now()+500;
    try {
        const lookup=call('objc_lookUpClass','pointer',['pointer']),meta=call('object_getClass','pointer',['pointer']);
        const list=call('class_copyMethodList','pointer',['pointer','pointer']),getName=call('method_getName','pointer',['pointer']);
        const register=call('sel_registerName','pointer',['pointer']),countArgs=call('method_getNumberOfArguments','uint',['pointer']);
        const getArg=call('method_getArgumentType','void',['pointer','uint','pointer','ulong']),getReturn=call('method_getReturnType','void',['pointer','pointer','ulong']);
        const imp=call('method_getImplementation','pointer',['pointer']),free=call('free','void',['pointer']);
        const wanted=selectors.map(s=>register(Memory.allocUtf8String(s))),buffer=Memory.alloc(128);
        function typeOf(method,index) {buffer.writeByteArray(new Uint8Array(128));if(index<0)getReturn(method,buffer,128);else getArg(method,index,buffer,128);return capabilityType(cstring(buffer,128));}
        for(let i=0;i<names.length;i++) {
            const row={id:i+1,state:'unavailable',methods:[]};result.classes.push(row);
            if(Date.now()>until){result.state='partial';continue;}
            try{
                const owner=lookup(Memory.allocUtf8String(names[i]));
                if(owner.isNull()){row.state='absent';continue;}
                row.state='present';
                let methodsSeen=0;const signatures=new Set();
                for(const [kind,cls] of [['instance',owner],['class',meta(owner)]]) {
                    const count=Memory.alloc(4);count.writeU32(0);const methods=list(cls,count);
                    try {
                        const n=count.readU32();if(n>4096-methodsSeen||n&&methods.isNull())throw Error('methods');methodsSeen+=n;
                        for(let j=0;j<n;j++) {
                            if(Date.now()>until)throw Error('deadline');
                            const method=methods.add(j*Process.pointerSize).readPointer(),selector=getName(method);
                            const index=wanted.findIndex(s=>s.equals(selector));if(index<0)continue;
                            const signature=kind+':'+index;if(signatures.has(signature))throw Error('ambiguous');signatures.add(signature);
                            const number=countArgs(method);if(number<2||number>12)throw Error('ABI');
                            const code=moduleAt(imp(method));if(code===null)throw Error('image');
                            row.methods.push({id:index+1,kind,arguments:number,types:Array.from({length:number},(_,k)=>typeOf(method,k)),result:typeOf(method,-1),code});
                        }
                    }finally{if(!methods.isNull())free(methods);}
                }
            }catch(_){row.state='unavailable';row.methods=[];result.state='partial';}
        }
    }catch(_){result.state='partial';}
    while(result.classes.length<names.length)result.classes.push({id:result.classes.length+1,state:'unavailable',methods:[]});
    return result;
}
function collectQQImageMethods() {
    const out={schemaVersion:1,scope:'SDImageCacheRuntimeTables',state:'unsupportedIdentity',reason:'identity',stoppedAt:'none',classes:[],methods:[]};
    if(CONFIG.bundle!=='com.tencent.mqq'||CONFIG.version!=='9.3.86'||CONFIG.build!=='9.3.86.617'||CONFIG.uuid!=='a0a54fb62ee23508ae266be2c332bbf8')return out;
    out.state='partial';out.reason='runtime';const until=Date.now()+500;
    try {
        const lookup=call('objc_lookUpClass','pointer',['pointer']),meta=call('object_getClass','pointer',['pointer']);
        const parent=call('class_getSuperclass','pointer',['pointer']),name=call('class_getName','pointer',['pointer']);
        const list=call('class_copyMethodList','pointer',['pointer','pointer']),getName=call('method_getName','pointer',['pointer']);
        const selectorName=call('sel_getName','pointer',['pointer']),countArgs=call('method_getNumberOfArguments','uint',['pointer']);
        const arg=call('method_getArgumentType','void',['pointer','uint','pointer','ulong']),result=call('method_getReturnType','void',['pointer','pointer','ulong']);
        const imp=call('method_getImplementation','pointer',['pointer']),free=call('free','void',['pointer']);
        let cls=lookup(Memory.allocUtf8String('SDImageCache'));if(cls.isNull()){out.state='absent';out.reason='classAbsent';return out;}
        const seenClasses=new Set(),buffer=Memory.alloc(128);
        function type(method,i){buffer.writeByteArray(new Uint8Array(128));if(i<0)result(method,buffer,128);else arg(method,i,buffer,128);return capabilityType(cstring(buffer,128));}
        while(!cls.isNull()) {
            out.reason='deadline';if(Date.now()>until)return out;
            out.reason='className';const className=cstring(name(cls),129);
            if(!/^[A-Za-z_$][A-Za-z0-9_.$]{0,127}$/.test(className))return out;
            if(className==='NSObject'){out.stoppedAt='NSObject';break;}
            out.reason='classLimit';if(out.classes.length>=8)return out;
            out.reason='classCycle';if(seenClasses.has(cls.toString()))return out;seenClasses.add(cls.toString());
            const id=out.classes.length+1;out.classes.push({id,name:className});
            for(const [kind,owner] of [['instance',cls],['class',meta(cls)]]) {
                out.reason='runtime';if(owner.isNull())return out;
                const count=Memory.alloc(4);count.writeU32(0);const methods=list(owner,count);
                try {
                    const n=count.readU32();out.reason='tableLimit';if(n>4096||n&&!methods||n&&methods.isNull())return out;
                    const signatures=new Set();
                    for(let i=0;i<n;i++) {
                        out.reason='deadline';if(Date.now()>until)return out;
                        out.reason='methodLimit';if(out.methods.length>=256)return out;
                        const method=methods.add(i*Process.pointerSize).readPointer();out.reason='selector';
                        const selector=cstring(selectorName(getName(method)),193);
                        if(!/^[A-Za-z_$][A-Za-z0-9_$:]{0,191}$/.test(selector)&&selector!=='.cxx_destruct'&&selector!=='.cxx_construct')return out;
                        out.reason='duplicate';if(signatures.has(selector))return out;signatures.add(selector);
                        out.reason='abi';const number=countArgs(method);if(number<2||number>12)return out;
                        out.reason='source';const code=moduleAt(imp(method));if(code===null)return out;
                        out.methods.push({class:id,kind,selector,arguments:number,types:Array.from({length:number},(_,j)=>type(method,j)),result:type(method,-1),code});
                    }
                }finally{if(methods&&!methods.isNull()){try{free(methods);}catch(error){out.reason='release';throw error;}}}
            }
            cls=parent(cls);
        }
        if(cls.isNull())out.stoppedAt='root';out.state='complete';out.reason='none';
    }catch(_){/* Only the current closed phase crosses the output boundary. */}
    return out;
}
function collectQQImageCode() {
    const out={schemaVersion:1,scope:'fixedSDImageCacheCodeWindows',state:'unsupportedIdentity',reason:'identity',methods:[]};
    if(CONFIG.bundle!=='com.tencent.mqq'||CONFIG.version!=='9.3.86'||CONFIG.build!=='9.3.86.617'||CONFIG.uuid!=='a0a54fb62ee23508ae266be2c332bbf8')return out;
    out.state='partial';out.reason='metadata';
    try {
        const table=receipt.qqImageMethods;
        if(!table||table.state!=='complete'||table.reason!=='none'||table.stoppedAt==='none')throw Error('metadata');
        const main=modules.filter(row=>row.uuid===CONFIG.uuid&&row.role==='app');
        if(main.length!==1)throw Error('module');
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
        const observed=table.methods.filter(row=>row.class===1&&row.kind==='instance'),byName=new Map(observed.map(row=>[row.selector,row]));
        if(observed.length<fixed.length||byName.size!==observed.length||observed.some(row=>!fixed.some(entry=>entry[0]===row.selector)&&!['.cxx_destruct','.cxx_construct'].includes(row.selector)))throw Error('methodMissing');
        for(const row of fixed)if(!byName.has(row[0]))throw Error('methodMissing');
        const lookup=call('objc_lookUpClass','pointer',['pointer']),methodOf=call('class_getInstanceMethod','pointer',['pointer','pointer']);
        const getName=call('method_getName','pointer',['pointer']),selName=call('sel_getName','pointer',['pointer']),register=call('sel_registerName','pointer',['pointer']);
        const argumentCount=call('method_getNumberOfArguments','uint',['pointer']),argumentType=call('method_getArgumentType','void',['pointer','uint','pointer','ulong']);
        const returnType=call('method_getReturnType','void',['pointer','pointer','ulong']),implementation=call('method_getImplementation','pointer',['pointer']);
        const methodList=call('class_copyMethodList','pointer',['pointer','pointer']),free=call('free','void',['pointer']);
        const cls=lookup(Memory.allocUtf8String('SDImageCache'));if(cls.isNull())throw Error('methodMissing');
        const buffer=Memory.alloc(128),deadline=Date.now()+500;
        function type(method,index){buffer.writeByteArray(new Uint8Array(128));if(index<0)returnType(method,buffer,128);else argumentType(method,index,buffer,128);return capabilityType(cstring(buffer,128));}
        function capture(address,length){const data=address.readByteArray(length);if(data===null||data.byteLength!==length)throw Error('read');
            return {bytes:Array.from(new Uint8Array(data),byte=>byte.toString(16).padStart(2,'0')).join(''),sha256:Checksum.compute('sha256',data)};}
        const ownMethods=new Map(),listCount=Memory.alloc(4);listCount.writeU32(0);let list=null;
        try{
            list=methodList(cls,listCount);const count=listCount.readU32();
            if(count>4096||count&&!list||count&&list.isNull())throw Error('metadata');
            for(let i=0;i<count;i++){
                if(Date.now()>deadline)throw Error('deadline');
                const method=list.add(i*Process.pointerSize).readPointer(),selector=cstring(selName(getName(method)),193);
                if(ownMethods.has(selector))throw Error('metadata');ownMethods.set(selector,method);
            }
        }finally{if(list&&!list.isNull())free(list);}
        const staged=[];
        for(let i=0;i<fixed.length;i++){
            if(Date.now()>deadline)throw Error('deadline');
            const [selector,offset,args,types,result]=fixed[i],row=byName.get(selector);
            if(row.code.module!==main[0].id||row.code.offset!==offset||row.arguments!==args||row.result!==result||row.types.length!==types.length||types.some((t,j)=>row.types[j]!==t))throw Error('implementation');
            const sel=register(Memory.allocUtf8String(selector)),method=methodOf(cls,sel);
            if(method.isNull()||!getName(method).equals(sel)||!ownMethods.has(selector)||ownMethods.get(selector).toString()!==method.toString())throw Error('methodMissing');
            const count=argumentCount(method);if(count!==args||count<2||count>12)throw Error('abi');
            if(type(method,-1)!==result||Array.from({length:count},(_,j)=>type(method,j)).some((t,j)=>t!==types[j]))throw Error('abi');
            const imp=implementation(method),address=imp.strip('ia'),module=moduleAt(imp);
            if(imp.isNull()||!module||module.module!==main[0].id||module.offset!==offset)throw Error('implementation');
            const planned=i+1<fixed.length?parseInt(fixed[i+1][1],16)-parseInt(offset,16):160;
            const currentOffset=parseInt(offset,16),allOffsets=table.methods.filter(item=>item.code.module===main[0].id&&item.code.offset!==offset)
                .map(item=>parseInt(item.code.offset,16)).filter(value=>Number.isSafeInteger(value)&&value>currentOffset);
            const nextObserved=allOffsets.length?Math.min(...allOffsets)-currentOffset:planned;
            const length=Math.min(planned,nextObserved);
            if(length<4||length>4096||(length&3))throw Error('bounds');
            const region=Process.findRangeByAddress(address);
            if(!region||region.protection!=='r-x')throw Error('protection');
            const end=region.base.add(region.size),windowEnd=address.add(length);
            if(address.compare(region.base)<0||windowEnd.compare(end)>0)throw Error('bounds');
            const startModule=Process.findModuleByAddress(address),endModule=Process.findModuleByAddress(windowEnd.sub(1));
            if(!startModule||!endModule||!startModule.base.equals(endModule.base)||address.compare(startModule.base)<0||windowEnd.compare(startModule.base.add(startModule.size))>0)throw Error('bounds');
            const before=capture(address,length);
            if(implementation(method).strip('ia').toString()!==address.toString())throw Error('changed');
            const after=capture(address,length);
            if(implementation(method).strip('ia').toString()!==address.toString()||before.bytes!==after.bytes||before.sha256!==after.sha256)throw Error('changed');
            const finalLocation=moduleAt(implementation(method));
            if(!finalLocation||finalLocation.module!==main[0].id||finalLocation.offset!==offset)throw Error('changed');
            staged.push({selector,arguments:args,types,result,code:{module:main[0].id,offset,protection:region.protection,windowLength:length,bytesHex:after.bytes,sha256Before:before.sha256,sha256After:after.sha256}});
        }
        out.methods=staged;out.state='complete';out.reason='none';
    }catch(error){
        out.reason=error&&['metadata','module','deadline','methodMissing','abi','implementation','protection','bounds','read','changed'].includes(error.message)?error.message:'metadata';
        out.methods=[];
    }
    return out;
}
function installYYOwnerObservation(classifyPath) {
    const d={state:'unavailable',reason:'identity',identity:'windowPointerAliasOnly',scope:'fixedYYDiskCacheNaturalCalls',
        source:null,owners:[],paths:[],events:[],counters:{calls:0,matched:0,unresolved:0,errors:0,dropped:0,limited:0,reentrant:0}};
    receipt.yyOwnerObservation=d;
    const detail={schemaVersion:1,calls:{write:0,path:0},rejections:{selectorMismatch:0,receiverMismatch:0,ownerLimit:0,pathUnavailable:0,pathLimit:0},
        receivers:[],receiverUnavailable:0,receiverDropped:0,sites:[],siteDropped:0};d.callDetails=detail;
    const owners=new Map(),paths=new Map(),receivers=new Map(),sites=new Map();let installed=false;
    const done=()=>{
        d.counters.dropped=d.counters.matched-d.events.length;
        if(installed)d.state=d.counters.unresolved||d.counters.errors||d.counters.dropped||d.counters.limited?'partial':d.events.length?'observed':'notTriggered';
        owners.clear();paths.clear();receivers.clear();sites.clear();
    };
    if(CONFIG.bundle!=='com.ss.iphone.ugc.Aweme'||CONFIG.version!=='41.2.0'||CONFIG.build!=='412021'||CONFIG.uuid!=='ef0e0cba15dd3f35aab8c9b571693881')return done;
    try {
        const lookup=call('objc_lookUpClass','pointer',['pointer']),selector=call('sel_registerName','pointer',['pointer']);
        const methodOf=call('class_getInstanceMethod','pointer',['pointer','pointer']),implementation=call('method_getImplementation','pointer',['pointer']);
        const getClass=call('object_getClass','pointer',['pointer']),superclass=call('class_getSuperclass','pointer',['pointer']);
        const classImage=call('class_getImageName','pointer',['pointer']);
        const count=call('method_getNumberOfArguments','uint',['pointer']),arg=call('method_getArgumentType','void',['pointer','uint','pointer','ulong']);
        const result=call('method_getReturnType','void',['pointer','pointer','ulong']);
        const length=call('CFStringGetLength','long',['pointer']),utf8=call('CFStringGetCString','uint8',['pointer','pointer','long','uint32']);
        d.reason='class';const cls=lookup(Memory.allocUtf8String('YYDiskCache')),nsString=lookup(Memory.allocUtf8String('NSString')),mutableString=lookup(Memory.allocUtf8String('NSMutableString'));
        if(cls.isNull()||nsString.isNull()||mutableString.isNull())return done;
        const specs=[['write','setObject:forKey:','0x1563f9f4',['object','selector','object','object'],'void'],['path','path','0x12da3ff4',['object','selector'],'object']];
        const hooks=[],sources={};
        for(const [api,name,offset,types,returns] of specs) {
            const wanted=selector(Memory.allocUtf8String(name)),method=methodOf(cls,wanted);if(method.isNull())return done;
            d.reason='source';const code=implementation(method).strip('ia'),source=moduleAt(code);
            if(!source||source.offset!==offset||modules[source.module-1].uuid!=='cc3b646814e43c7fa8708f1eb5f4adeb')return done;
            // Gum may resolve an initial B recursively to a different function.
            // The fixed IMP alone does not authorize instrumenting that target.
            d.reason='entryUnreadable';const first=code.readU32();
            if((first&0xfc000000)===0x14000000){d.reason='entryRedirectUnverified';return done;}
            d.reason='abi';if(count(method)!==types.length)return done;
            const buffer=Memory.alloc(128),type=(i)=>{buffer.writeByteArray(new Uint8Array(128));if(i<0)result(method,buffer,128);else arg(method,i,buffer,128);return capabilityType(cstring(buffer,128));};
            if(type(-1)!==returns||types.some((t,i)=>type(i)!==t))return done;
            sources[api]=source;hooks.push({api,wanted,code});
        }
        function pathText(value) {
            if(value.isNull())return null;
            let current=getClass(value),found=false;
            for(let n=0;n<16&&!current.isNull();n++) {
                if(current.equals(mutableString))return null;
                if(current.equals(nsString)){found=true;break;}
                const image=cstring(classImage(current));
                if(!image.startsWith('/System/Library/')&&!image.startsWith('/usr/lib/'))return null;
                current=superclass(current);
            }
            if(!found)return null;
            const size=Number(length(value).toString());if(!Number.isSafeInteger(size)||size<=0||size>4095)return null;
            const bytes=Memory.alloc(4096);if(!utf8(value,bytes,4096,0x08000100))return null;
            const text=cstring(bytes);return text.length===size?text:null;
        }
        function rejectedReceiver(api,actual,wanted,pinned) {
            try {
                if(actual.isNull()){detail.receiverUnavailable++;return;}
                const key=api+':'+actual.toString(),known=receivers.get(key);
                if(known){known.calls++;return;}
                if(receivers.size>=16){detail.receiverDropped++;return;}
                const name=cstring(call('class_getName','pointer',['pointer'])(actual),129);
                let current=actual,relation='depthLimit',depth=null;const seen=new Set();
                for(let n=0;n<16;n++) {
                    if(current.isNull()){relation='unrelated';break;}
                    if(seen.has(current.toString())){relation='unavailable';break;}
                    seen.add(current.toString());
                    current=superclass(current);
                    if(current.equals(cls)){relation='subclass';depth=n+1;break;}
                }
                const method=methodOf(actual,wanted);
                const resolved=method.isNull()?'absent':implementation(method).strip('ia').equals(pinned)?'pinned':'other';
                const row={api,className:/^[A-Za-z_$][A-Za-z0-9_.$]{0,127}$/.test(name)?name:null,
                    relation,depth,resolvedImplementation:resolved,calls:1};
                receivers.set(key,row);detail.receivers.push(row);
            }catch(_){detail.receiverUnavailable++;}
        }
        function rejectedSite(api,reason,address) {
            try {
                const caller=moduleAt(address),key=api+':'+reason+':'+JSON.stringify(caller),known=sites.get(key);
                if(known){known.calls++;return;}
                if(sites.size>=16){detail.siteDropped++;return;}
                const row={api,reason,caller,calls:1};sites.set(key,row);detail.sites.push(row);
            }catch(_){detail.siteDropped++;}
        }
        d.reason='attach';const staged=[];
        try {
            for(const {api,wanted,code} of hooks)staged.push(Interceptor.attach(code,{
                onEnter(args) {
                    this.yyRecord=null;if(ended||endRequested||!installed)return;
                    if(busy){d.counters.reentrant=Math.min(Number.MAX_SAFE_INTEGER,d.counters.reentrant+1);return;}
                    if(d.counters.calls>=128){d.counters.limited=1;return;}
                    const saved=this.errno;busy=true;
                    try {
                        d.counters.calls++;detail.calls[api]++;
                        if(!args[1].equals(wanted)){d.counters.unresolved++;detail.rejections.selectorMismatch++;rejectedSite(api,'selectorMismatch',this.returnAddress);return;}
                        const actual=getClass(args[0]);
                        if(!actual.equals(cls)){d.counters.unresolved++;detail.rejections.receiverMismatch++;rejectedReceiver(api,actual,wanted,code);rejectedSite(api,'receiverMismatch',this.returnAddress);return;}
                        const key=args[0].toString();
                        if(!owners.has(key)&&owners.size>=64){d.counters.unresolved++;detail.rejections.ownerLimit++;d.counters.limited=1;return;}
                        const caller=moduleAt(this.returnAddress);
                        if(!owners.has(key)){const id=owners.size+1;owners.set(key,id);d.owners.push({id});}
                        this.yyRecord={api,owner:owners.get(key),path:null,returned:true,caller};d.counters.matched++;
                    }catch(_){d.counters.errors++;}finally{busy=false;this.errno=saved;}
                },
                onLeave(value) {
                    const record=this.yyRecord;if(record===null||ended)return;
                    const saved=this.errno;busy=true;
                    try {
                        if(d.events.length>=64)return;
                        if(api==='path') {
                            const text=pathText(value),path=text===null?null:classifyPath(text);
                            if(path===null){d.counters.matched--;d.counters.unresolved++;detail.rejections.pathUnavailable++;return;}
                            if(!paths.has(path.key)&&paths.size>=32){d.counters.matched--;d.counters.unresolved++;detail.rejections.pathLimit++;d.counters.limited=1;return;}
                            if(!paths.has(path.key)){const id=paths.size+1;paths.set(path.key,id);d.paths.push({id,scope:path.scope,selectedRootSpelling:path.selectedRootSpelling});}
                            record.path=paths.get(path.key);
                        }
                        d.events.push(record);
                    }catch(_){d.counters.matched--;d.counters.errors++;}finally{busy=false;this.errno=saved;}
                }
            }));
        }catch(error) {
            for(const listener of staged){try{listener.detach();}catch(_){listeners.push(listener);}}
            throw error;
        }
        listeners.push(...staged);installed=true;d.source=sources;d.reason='none';d.state='notTriggered';
    }catch(_){/* Fixed reason only; no arbitrary exception text. */}
    return done;
}
let yyOwnerFinalize=null;
let descriptorFinalize=null;
function finish(reason) {
    if (ended) return; ended = true;
    if (timer !== null) clearTimeout(timer);
    let failures = 0;
    for (const listener of listeners) { try { listener.detach(); } catch (_) { failures++; } }
    if(typeof descriptorFinalize==='function') descriptorFinalize();
    if(typeof yyOwnerFinalize==='function') yyOwnerFinalize();
    listeners.length = 0; nodeIDs.clear(); objectIDs.clear(); moduleIDs.clear();
    receipt.cleanup = {state: failures ? 'failed' : 'detached', failures};
    const incomplete = !!receipt.qqImageMethods && ['partial','unsupportedIdentity'].includes(receipt.qqImageMethods.state) || !!receipt.qqImageCode && receipt.qqImageCode.state!=='complete' || !!receipt.yyOwnerObservation && ['partial','unavailable'].includes(receipt.yyOwnerObservation.state) || !!receipt.capabilityMetadata && receipt.capabilityMetadata.state!=='complete' || !!receipt.descriptorObservation && receipt.descriptorObservation.state!=='complete' || apiCoverage.length !== 6 || apiCoverage.some(row => row.state !== 'installed') ||
        CONFIG.bundle === 'com.baidu.netdisk' && receipt.queryCoverage !== 'installed';
    const descriptorObserved=receipt.yyOwnerObservation && receipt.yyOwnerObservation.events.length || receipt.descriptorObservation && (receipt.descriptorObservation.objects.length||receipt.descriptorObservation.events.length);
    receipt.state = failures || reason === 'setupRejected' ? 'failed' : dropped || reason !== 'windowEnded' || incomplete ? 'partial' : events.length || descriptorObserved ? 'observed' : 'notTriggered';
    receipt.reason = failures ? 'detachFailed' : reason;
    receipt.counters = {matched: events.length, dropped, objcObserved: objcHits};
    send(receipt);
}
function requestFinish(reason) { if (!endRequested) { endRequested = true; setImmediate(() => finish(reason)); } }
let mainBase = ptr(0);
try {
    if (!APPS[CONFIG.bundle] || !Number.isInteger(CONFIG.seconds) || CONFIG.seconds < 1 || CONFIG.seconds > 90 ||
        !/^[0-9a-f]{32}$/.test(CONFIG.uuid) || !/^[0-9]+(?:\.[0-9]+){0,5}$/.test(CONFIG.version) ||
        !/^[0-9]+(?:\.[0-9]+){0,5}$/.test(CONFIG.build)) throw Error('configuration');
    const lookup = call('objc_lookUpClass', 'pointer', ['pointer']);
    const sel = call('sel_registerName', 'pointer', ['pointer']);
    const msg = call('objc_msgSend', 'pointer', ['pointer', 'pointer']);
    const msg1 = new NativeFunction(address('objc_msgSend'), 'pointer', ['pointer', 'pointer', 'pointer']);
    const str = value => { if (value.isNull()) throw Error('string'); return cstring(msg(value, sel(Memory.allocUtf8String('UTF8String')))); };
    const string = value => msg1(lookup(Memory.allocUtf8String('NSString')), sel(Memory.allocUtf8String('stringWithUTF8String:')), Memory.allocUtf8String(value));
    const bundle = msg(lookup(Memory.allocUtf8String('NSBundle')), sel(Memory.allocUtf8String('mainBundle')));
    const property = name => str(msg1(bundle, sel(Memory.allocUtf8String('objectForInfoDictionaryKey:')), string(name)));
    if (str(msg(bundle, sel(Memory.allocUtf8String('bundleIdentifier')))) !== CONFIG.bundle ||
        property('CFBundleShortVersionString') !== CONFIG.version || property('CFBundleVersion') !== CONFIG.build) throw Error('identity');
    const realpath = call('realpath', 'pointer', ['pointer', 'pointer']);
    function canonical(path) { const out = Memory.alloc(4096); return realpath(Memory.allocUtf8String(path), out).isNull() ? null : cstring(out); }
    const executable = canonical(str(msg(bundle, sel(Memory.allocUtf8String('executablePath')))));
    const getCount = call('_dyld_image_count', 'uint', []);
    const getHeader = call('_dyld_get_image_header', 'pointer', ['uint']);
    const getName = call('_dyld_get_image_name', 'pointer', ['uint']);
    const count = getCount(); if (count > 4096 || executable === null) throw Error('image');
    const matches = [];
    for (let i = 0; i < count; i++) {
        const name = cstring(getName(i));
        if (canonical(name) === executable) matches.push({base: getHeader(i), index: i});
    }
    if (matches.length !== 1 || getCount() !== count) throw Error('image');
    mainBase = matches[0].base;
    if (mainBase.add(12).readU32() !== 2 || uuid(mainBase) !== CONFIG.uuid) throw Error('image');
    receipt.image = {uuid: uuid(mainBase), fileType: 2, dyldIndex: matches[0].index, bundlePathMatched: true,
        indexZeroSame: mainBase.equals(getHeader(0)), processMainSame: mainBase.equals(Process.mainModule.base)};
    const home = str(call('NSHomeDirectory', 'pointer', [])());
    let rawRoot, role = APPS[CONFIG.bundle];
    if (role === 'swiftgroup') {
        const manager = msg(lookup(Memory.allocUtf8String('NSFileManager')), sel(Memory.allocUtf8String('defaultManager')));
        const url = msg1(manager, sel(Memory.allocUtf8String('containerURLForSecurityApplicationGroupIdentifier:')), string('group.app.swiftgram.ios'));
        if (url.isNull()) throw Error('mapping');
        rawRoot = str(msg(url, sel(Memory.allocUtf8String('path'))));
    } else rawRoot = home + (role === 'support' ? '/Library/Application Support' : '/Documents');
    const root = canonical(rawRoot); if (root === null || root === '/') throw Error('mapping');
    const spellings = [root, rawRoot, root.startsWith('/private/') ? root.substring(8) : '/private' + root];
    const safe = new Set(['postbox', 'media', 'cache', 'db', 'logs', 'download', 'model', 'models', 'EffectSDK', 'ByteDownload']);
    function target(path) {
        // Most host calls are outside this scope. Reject them before realpath.
        if (!spellings.some(prefix => path.startsWith(prefix + '/'))) return null;
        if (path.split('/').some(part => part === '.' || part === '..')) return null;
        let resolved = canonical(path);
        if (resolved === null) {
            const slash = path.lastIndexOf('/'), parent = canonical(path.substring(0, slash));
            if (parent === null) return null; resolved = parent + path.substring(slash);
        }
        if (!resolved.startsWith(root + '/')) return null;
        const parts = resolved.substring(root.length + 1).split('/');
        if (parts.some(part => part === '.' || part === '..' || !part)) return null;
        // The observed group layout nests postbox/logs below account directories.
        // Only bounded directory components count; a same-named leaf is not a scope.
        const scopeDirectories = parts.slice(0, Math.min(3, parts.length - 1));
        if (role === 'swiftgroup' && !scopeDirectories.some(part => part === 'postbox' || part === 'logs')) return null;
        const key = parts.slice(0, role === 'swiftgroup' ? 4 : 2).join('/');
        if (!nodeIDs.has(key)) {
            if (nodes.length >= MAX_NODES) { dropped++; return null; }
            const id = nodes.length + 1;
            nodes.push({id, role, labels: parts.slice(0, role === 'swiftgroup' ? 4 : 2).map(part => safe.has(part) ? part : 'unknown')});
            nodeIDs.set(key, id);
        }
        return nodeIDs.get(key);
    }
    const hooks = [['open', 0, 'open'], ['openat', 1, 'open'], ['fopen', 0, 'open'],
        ['unlink', 0, 'unlink'], ['rename', 0, 'rename'], ['mkdir', 0, 'mkdir']];
    for (const [name, argument, kind] of hooks) {
        const p = Module.findGlobalExportByName(name);
        const coverage = {api: name, state: p === null ? 'missing' : 'installing'}; apiCoverage.push(coverage);
        if (p === null) continue;
        listeners.push(Interceptor.attach(p, {
            onEnter(args) {
                this.record = null;
                if (ended || endRequested) return;
                if (busy) { inputCoverage.reentrant = Math.min(Number.MAX_SAFE_INTEGER, inputCoverage.reentrant + 1); return; }
                const savedErrno=this.errno;
                busy = true;
                try {
                    inputCoverage.calls++;
                    if (++calls > 20000) { inputCoverage.limited++; requestFinish('callLimit'); return; }
                    const path = cstring(args[argument]);
                    if (!path.startsWith('/')) { inputCoverage.relative++; return; }
                    const node = target(path);
                    if (node === null) { inputCoverage.outside++; return; }
                    const frames = Thread.backtrace(this.context, Backtracer.ACCURATE).slice(0, 8).map(moduleAt).filter(x => x !== null);
                    this.record = {kind, node, frames};
                    if (kind === 'open') this.record.access = openIntent(name, args);
                    inputCoverage.matched++;
                } catch (_) { this.record = null; inputCoverage.errors++; dropped++; } finally { busy = false; this.errno=savedErrno; }
            },
            onLeave(value) {
                if (this.record === null || ended) return;
                if (events.length >= MAX_EVENTS) { dropped++; requestFinish('eventLimit'); return; }
                const success = name === 'fopen' ? !value.isNull() : value.toInt32() >= 0;
                this.record.result = success ? 'returned' : 'failed';
                events.push(this.record);
                if (events.length >= MAX_EVENTS) requestFinish('eventLimit');
            }
        }));
        coverage.state = 'installed';
    }
    descriptorFinalize=installDescriptorObservation(target);
    busy=true;try{receipt.capabilityMetadata=collectCapabilityMetadata();}finally{busy=false;}
    if(CONFIG.bundle==='com.tencent.mqq'){busy=true;try{receipt.qqImageMethods=collectQQImageMethods();receipt.qqImageCode=collectQQImageCode();}finally{busy=false;}}
    if(CONFIG.bundle==='com.ss.iphone.ugc.Aweme') {
        const homeSpellings=[home,canonical(home)].filter(x=>x!==null);
        yyOwnerFinalize=installYYOwnerObservation(path=>{
            if(!path.startsWith('/')||path.includes('\\')||path.split('/').slice(1).some(p=>!p||p==='.'||p==='..'))return null;
            const base=homeSpellings.find(p=>path.startsWith(p+'/'));
            let scope='groupOrOther';
            if(base) {
                const relative=path.substring(base.length+1);
                const under=p=>relative===p||relative.startsWith(p+'/');
                scope=under('Library/Caches')?'caches':under('tmp')?'tmp':under('Documents')?'documents':under('Library/Application Support')?'support':'mainOther';
            }
            const selectedRootSpelling=spellings.some(p=>path===p||path.startsWith(p+'/'));
            if(selectedRootSpelling)scope='support';
            return {key:path,scope,selectedRootSpelling};
        });
    }
    // This exact Objective-C ABI is proven in the installed image. Only receiver
    // equality, nil shape and BOOL result are observed; no query is invoked.
    if (CONFIG.bundle === 'com.baidu.netdisk') {
        const queryIdentityMatches = CONFIG.version === '13.37.5' && CONFIG.build === '13.37.5.10' &&
            CONFIG.uuid === 'b2b9d30a1caf31b482cac776e7eb2ba1';
        if (!queryIdentityMatches) {
            receipt.queryCoverage = 'unsupportedIdentity';
        } else {
        setupDiagnostic.phase = 'queryLookup';
        const owner = lookup(Memory.allocUtf8String('TransFileListDAO'));
        receipt.queryCoverage = owner.isNull() ? 'classMissing' : 'methodMissing';
        if (!owner.isNull()) {
            setupDiagnostic.phase = 'queryRuntimeAPIs';
            const meta = call('object_getClass', 'pointer', ['pointer'])(owner);
            const list = call('class_copyMethodList', 'pointer', ['pointer', 'pointer']);
            const type = call('method_getTypeEncoding', 'pointer', ['pointer']);
            const nameOf = call('method_getName', 'pointer', ['pointer']);
            const imp = call('method_getImplementation', 'pointer', ['pointer']);
            const free = call('free', 'void', ['pointer']);
            setupDiagnostic.phase = 'queryList';
            const length = Memory.alloc(4); length.writeU32(0); const methods = list(meta, length);
            let queryFailed = false;
            try {
                const n = length.readU32(); if (n > 4096) throw Error('methods');
                setupDiagnostic.methodCount = n;
                const wanted = sel(Memory.allocUtf8String('hasTransFileWithBlockMD5List:status:fileNameArray:usinDB:'));
                setupDiagnostic.phase = 'querySelector';
                for (let i = 0; i < n; i++) {
                    const method = methods.add(i * Process.pointerSize).readPointer();
                    if (!nameOf(method).equals(wanted)) continue;
                    setupDiagnostic.matchedMethods++;
                    setupDiagnostic.phase = 'queryEncoding';
                    if (cstring(type(method)) !== 'B48@0:8@16@24@32@40') { receipt.queryCoverage = 'ABIRejected'; continue; }
                    setupDiagnostic.phase = 'queryOwner';
                    const code = imp(method).strip('ia'); const containing = Process.findModuleByAddress(code);
                    if (containing === null || !containing.base.equals(mainBase)) throw Error('owner');
                    setupDiagnostic.phase = 'queryAttach';
                    try {
                    listeners.push(Interceptor.attach(code, {onEnter(args) {
                        this.record = undefined; if (ended || endRequested) return;
                        const object = args[0].toString();
                        if (!objectIDs.has(object)) { if (objectIDs.size >= 64) return; objectIDs.set(object, objectIDs.size + 1); }
                        try { this.record = {kind: 'referenceQuery', owner: objectIDs.get(object), statusNil: args[3].isNull(),
                            databaseNil: args[5].isNull(), frames: [moduleAt(this.returnAddress)].filter(x => x !== null)}; }
                        catch (_) { dropped++; }
                    }, onLeave(value) {
                        if (this.record === undefined || ended) return;
                        if (events.length >= MAX_EVENTS) { dropped++; requestFinish('eventLimit'); return; }
                        this.record.result = (value.toInt32() & 0xff) === 0 ? 'falseAmbiguous' : 'true';
                        events.push(this.record); objcHits++; if (events.length >= MAX_EVENTS) requestFinish('eventLimit');
                    }}));
                    receipt.queryCoverage = 'installed';
                    } catch (error) {
                        // Preserve the supported file window and make the missing query explicit.
                        receipt.queryCoverage = 'installationFailed';
                        receipt.queryDiagnostic = {phase: 'queryAttach', error: queryAttachError(error),
                            methodCount: setupDiagnostic.methodCount, matchedMethods: setupDiagnostic.matchedMethods};
                    }
                }
            } catch (error) {
                queryFailed = true;
                throw error;
            } finally {
                if (!methods.isNull()) {
                    try { free(methods); }
                    catch (releaseError) {
                        setupDiagnostic.releaseFailed = true;
                        if (!queryFailed) {
                            setupDiagnostic.phase = 'queryFree';
                            throw releaseError;
                        }
                    }
                }
            }
        }
        }
    }
    setupDiagnostic.phase = 'timer';
    timer = setTimeout(() => finish('windowEnded'), CONFIG.seconds * 1000);
} catch (error) {
    const text = error instanceof Error ? error.message : '';
    setupDiagnostic.error = ['api', 'null', 'bound', 'methods', 'owner'].includes(text) ? text : 'unclassified';
    receipt.setupDiagnostic = setupDiagnostic;
    finish('setupRejected');
}
