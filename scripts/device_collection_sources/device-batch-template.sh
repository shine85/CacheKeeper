#!/bin/bash
# Prepared input for the existing parent-owned queue. No phone files are created.
timeout 1800 bash -s <<'CK_ALLAPP_TECH_136_SCRIPT'
set -o pipefail
export LC_ALL=C
CKB_TAG=CK_ALLAPP_TECH_136_V2
CKB_TOTAL_LIMIT=134217728
CKB_IMAGE_LIMIT=16777216
CKB_SDKS='@@SDK_NAMES@@'
CKB_TOTAL=0
CKB_IMAGES=0
CKB_SDK_IMAGES=0
CKB_APP_COUNT=0
CKB_STARTED=$SECONDS
CKB_PLUTIL=none
printf '%s_BEGIN\n' "$CKB_TAG"
for ckb_tool in rootfs uicache stat dd od awk base64 sha256sum timeout realpath find bash wc tr tail; do
    command -v "$ckb_tool" >/dev/null 2>&1 || { printf 'FATAL|missingTool|%s\n' "$ckb_tool"; exit 20; }
done
ckb_help=$(timeout 3 plutil -help 2>&1)
case "$ckb_help" in *-extract*) CKB_PLUTIL=extract;; *-convert*'-o'*) CKB_PLUTIL=xmlstdout;; esac
printf 'TOOLS|plutil|binaryTechnicalKeys+%s\n' "$CKB_PLUTIL"
ckb_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
ckb_hash() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
ckb_check_budget() { [ $((SECONDS-CKB_STARTED)) -lt 1680 ]; }
ckb_identity() { stat -c '%d|%i|%f|%s|%Y|%Z' -- "$1" 2>/dev/null; }
# bplist trailer/object table decoding; only three top-level technical scalars
# can leave the process. No whole plist or arbitrary field is emitted.
ckb_plist_binary() {
    timeout 3 od -An -v -t u1 -- "$1" 2>/dev/null | awk -v key="$2" '
    function uint(p,c, i,v){v=0;if(c<1||c>8||p<1||p+c-1>N){bad=1;return 0}for(i=0;i<c;i++){v=v*256+a[p+i];if(v>9007199254740991){bad=1;return 0}}return v}
    function object(ref, v){if(ref<0||ref>=count){bad=1;return 0}v=uint(table+ref*os+1,os)+1;if(v<9||v>table){bad=1;return 0}return v}
    function lengthAt(p,info,bytes){lp=p+1;if(info<15)return info;if(int(a[lp]/16)!=1){bad=1;return 0}bytes=2^(a[lp]%16);lp++;lv=uint(lp,bytes);lp+=bytes;return lv}
    function scalar(ref, p,t,info,len,i,c,s){p=object(ref);t=int(a[p]/16);info=a[p]%16;s="";
      if(t==1){if(2^info>8){bad=1;return ""}return sprintf("%.0f",uint(p+1,2^info))}
      if(t!=5&&t!=6){bad=1;return ""}len=lengthAt(p,info);p=lp;
      if(len<1||len>4096||p+(t==6?2:1)*len>table+1){bad=1;return ""}
      for(i=0;i<len;i++){c=t==6?uint(p+i*2,2):a[p+i];if(c<32||c>126){bad=1;return ""}s=s sprintf("%c",c)}return s}
    {for(i=1;i<=NF;i++)a[++N]=$i}
    END{if(N<40||N>1048576||a[1]!=98||a[2]!=112||a[3]!=108||a[4]!=105||a[5]!=115||a[6]!=116||a[7]!=48||a[8]!=48)exit 21;
      os=a[N-25];rs=a[N-24];count=uint(N-23,8);top=uint(N-15,8);table=uint(N-7,8);
      if(os<1||os>8||rs<1||rs>8||count<1||count>65536||table<8||table+count*os>N-32)exit 22;
      p=object(top);if(int(a[p]/16)!=13)exit 22;num=lengthAt(p,a[p]%16);p=lp;
      if(num<1||num>4096||p+2*num*rs>table+1)exit 22;
      for(j=0;j<num;j++){k=scalar(uint(p+j*rs,rs));if(k==key){value=scalar(uint(p+(num+j)*rs,rs));hits++}}
      if(bad||hits!=1||value !~ /^[A-Za-z0-9_.+() -]+$/)exit 22;print value}'
}
ckb_plist_key() {
    case "$2" in CFBundleShortVersionString|CFBundleVersion|CFBundleExecutable) ;; *) return 20;; esac
    [ -f "$1" ] && [ ! -L "$1" ] || return 22
    [ "$(stat -c '%s' -- "$1" 2>/dev/null)" -le 1048576 ] || return 23
    local ckb_scalar ckb_scalar_status
    ckb_scalar=$(ckb_plist_binary "$1" "$2"); ckb_scalar_status=$?
    if [ "$ckb_scalar_status" -eq 0 ]; then printf '%s\n' "$ckb_scalar"; return; fi
    if [ "$ckb_scalar_status" -ne 21 ]; then return "$ckb_scalar_status"; fi
    if [ "$CKB_PLUTIL" = extract ]; then
        timeout 3 plutil -extract "$2" raw -o - "$1" 2>/dev/null
    elif [ "$CKB_PLUTIL" = xmlstdout ]; then
        # Conversion goes to an in-memory pipe. Only the requested scalar exits.
        timeout 3 plutil -convert xml1 -o - "$1" 2>/dev/null | awk -v key="$2" '
        $0 ~ "<key>" key "</key>" {want=1;next}
        want {if($0 ~ /^[[:space:]]*<(string|integer)>[A-Za-z0-9_.+() -]+<\/(string|integer)>[[:space:]]*$/){sub(/^[[:space:]]*<[^>]+>/,"");sub(/<[^>]+>[[:space:]]*$/,"");value=$0;n++}want=0}
        END{if(n==1)print value;else exit 21}'
    else
        # Plain XML plist is parsed locally; nested duplicates fail closed.
        timeout 3 awk -v key="$2" '
        /<plist[ >]/{plist=1}
        $0 ~ "<key>" key "</key>" {want=1;next}
        want {if($0 ~ /^[[:space:]]*<(string|integer)>[A-Za-z0-9_.+() -]+<\/(string|integer)>[[:space:]]*$/){sub(/^[[:space:]]*<[^>]+>/,"");sub(/<[^>]+>[[:space:]]*$/,"");value=$0;n++}want=0}
        END{if(plist&&n==1)print value;else exit 21}' "$1" 2>/dev/null
    fi
}
ckb_baseline() {
    CKB_OLD_VERSION=; CKB_OLD_BUILD=; CKB_OLD_PATH=; CKB_OLD_EXEC=; CKB_OLD_KNOWN=0; CKB_ALOG=0
    case "$1" in
@@BASELINE_CASES@@
    esac
}
# Read only the named range, keep the bytes in bounded shell memory, then emit
# exact decoded length and SHA. Pipe errors cannot masquerade as empty success.
ckb_range() {
    local ckb_file=$1 ckb_kind=$2 ckb_off=$3 ckb_len=$4 ckb_blob ckb_code ckb_n ckb_sha
    if [ "$ckb_len" -le 0 ] || [ "$ckb_len" -gt 1048576 ] ||
       [ $((CKB_IMAGE_BYTES+ckb_len)) -gt "$CKB_IMAGE_LIMIT" ] ||
       [ $((CKB_TOTAL+ckb_len)) -gt "$CKB_TOTAL_LIMIT" ] || ! ckb_check_budget; then
        printf 'RANGE_SKIP|%s|%s|%s|budget\n' "$ckb_kind" "$ckb_off" "$ckb_len"; return 23
    fi
    ckb_blob=$(timeout 10 dd if="$ckb_file" bs=65536 skip="$ckb_off" count="$ckb_len" iflag=skip_bytes,count_bytes status=none 2>/dev/null | base64)
    ckb_code=$?
    [ "$ckb_code" -eq 0 ] || { printf 'RANGE_FAIL|%s|%s|%s|read\n' "$ckb_kind" "$ckb_off" "$ckb_len"; return 24; }
    ckb_n=$(printf '%s' "$ckb_blob" | base64 -d | wc -c | tr -d '[:space:]')
    [ "$ckb_n" = "$ckb_len" ] || { printf 'RANGE_FAIL|%s|%s|%s|shortRead\n' "$ckb_kind" "$ckb_off" "$ckb_len"; return 25; }
    ckb_sha=$(printf '%s' "$ckb_blob" | base64 -d | sha256sum | awk '{print $1}')
    CKB_IMAGE_BYTES=$((CKB_IMAGE_BYTES+ckb_len)); CKB_TOTAL=$((CKB_TOTAL+ckb_len))
    printf 'RANGE_BEGIN|%s|%s|%s|%s\n' "$ckb_kind" "$ckb_off" "$ckb_len" "$ckb_sha"
    printf '%s\n' "$ckb_blob"
    printf 'RANGE_END|%s\n' "$ckb_kind"
}
# Thin ARM64 load commands only. This declares ranges; the desktop parser
# independently validates every range against the retained original header.
ckb_layout() {
    timeout 5 dd if="$1" bs=65536 count="$2" iflag=count_bytes status=none 2>/dev/null |
    od -An -v -t u4 | awk '
    function text(w,n, i,j,v,c,s){s="";for(i=0;i<n;i++){v=a[w+i];for(j=0;j<4;j++){c=v%256;v=int(v/256);if(c==0)return s;s=s sprintf("%c",c)}}return s}
    function u64(w){if(a[w+1]>2097151){bad=1;return 0}return a[w]+4294967296*a[w+1]}
    function want(seg,s){return ((seg=="__DATA"||seg=="__DATA_CONST"||seg=="__AUTH"||seg=="__AUTH_CONST") && (s=="__objc_const"||s=="__objc_data"||s=="__objc_classlist"||s=="__objc_catlist"||s=="__objc_protolist"||s=="__objc_classrefs"||s=="__objc_selrefs"||s=="__objc_imageinfo")) || (seg=="__TEXT" && (s=="__objc_classname"||s=="__objc_methname"||s=="__objc_methtype"||s ~ /^__swift5_/))}
    {for(i=1;i<=NF;i++)a[++n]=$i}
    END {
      if(n<8||a[1]!=4277009103||a[2]!=16777228||a[5]>2048||32+a[6]!=n*4){print "REJECT|header";exit 30}
      p=9;uuid=0
      for(k=0;k<a[5];k++){
        cmd=a[p];sz=a[p+1];if(sz<8||sz%4||p+sz/4-1>n){bad=1;break}
        if(cmd==27 && sz==24){uuid++;s="";for(i=p+2;i<p+6;i++){v=a[i];for(j=0;j<4;j++){s=s sprintf("%02x",v%256);v=int(v/256)}}print "UUID|" s}
        if(cmd==44 && sz>=24)print "CRYPT|" a[p+2] "|" a[p+3] "|" a[p+4]
        if(cmd==25 && sz>=72){seg=text(p+2,4);ns=a[p+16];if(72+80*ns>sz){bad=1;break};for(i=0;i<ns;i++){q=p+18+i*20;s=text(q,4);if(want(seg,s))printf("SECTION|%s,%s|%.0f|%.0f\n",seg,s,a[q+12],u64(q+10))}}
        if(cmd==2147483700 || cmd==2147483699)printf("LINKEDIT|%s|%.0f|%.0f\n",cmd==2147483700?"chained_fixups":"exports_trie",a[p+2],a[p+3])
        if(cmd==34||cmd==2147483682){for(i=0;i<5;i++)printf("LINKEDIT|dyld_%d|%.0f|%.0f\n",i,a[p+2+i*2],a[p+3+i*2])}
        if(cmd==2 && sz==24){printf("LINKEDIT|nlist64|%.0f|%.0f\n",a[p+2],a[p+3]*16);printf("LINKEDIT|strings|%.0f|%.0f\n",a[p+4],a[p+5])}
        p+=sz/4
      }
      if(bad||uuid!=1||p!=n+1){print "REJECT|loadCommands";exit 31}
      print "LAYOUT_OK"
    }'
}
ckb_image() {
    local ckb_app=$1 ckb_sdk=$2 ckb_file="$1/Frameworks/$2.framework/$2" ckb_before ckb_after ckb_size ckb_words ckb_hlen ckb_layout_text ckb_uuid ckb_type ckb_kind ckb_off ckb_len ckb_extra ckb_overlap ckb_version ckb_build ckb_real ckb_chunk ckb_remaining ckb_cursor
    CKB_IMAGES=$((CKB_IMAGES+1)); CKB_IMAGE_BYTES=0
    if [ "$ckb_sdk" = PRIMARY ]; then ckb_file="$ckb_app/$3"; else CKB_SDK_IMAGES=$((CKB_SDK_IMAGES+1)); fi
    printf 'IMAGE_BEGIN|%s|%s\n' "$CKB_ALIAS" "$ckb_sdk"
    if { [ "$ckb_sdk" != PRIMARY ] && [ "$CKB_SDK_IMAGES" -gt 96 ]; } || ! ckb_check_budget; then printf 'IMAGE_END|budget\n'; return; fi
    if [ ! -f "$ckb_file" ] || [ -L "$ckb_file" ]; then printf 'IMAGE_END|notRegular\n'; return; fi
    ckb_real=$(realpath -- "$ckb_file" 2>/dev/null)
    case "$ckb_real" in "$ckb_app"/*) ;; *) printf 'IMAGE_END|outsideBundle\n'; return;; esac
    ckb_before=$(ckb_identity "$ckb_file") || { printf 'IMAGE_END|statUnavailable\n'; return; }
    ckb_size=$(printf '%s' "$ckb_before" | awk -F'|' '{print $4}')
    printf 'IDENTITY_BEFORE|%s\n' "$ckb_before"
    ckb_version=$(ckb_plist_key "$ckb_app/Frameworks/$ckb_sdk.framework/Info.plist" CFBundleShortVersionString)
    ckb_vcode=$?
    ckb_build=$(ckb_plist_key "$ckb_app/Frameworks/$ckb_sdk.framework/Info.plist" CFBundleVersion)
    ckb_bcode=$?
    printf 'FRAMEWORK_VERSION|%s|%s|%s|%s\n' "$ckb_vcode" "$(ckb_b64 "$ckb_version")" "$ckb_bcode" "$(ckb_b64 "$ckb_build")"
    ckb_words=$(timeout 5 od -An -v -t u4 -N 32 -- "$ckb_file" 2>/dev/null | awk '{for(i=1;i<=NF;i++)a[++n]=$i} END{if(n==8&&a[1]==4277009103&&a[2]==16777228&&a[5]<=2048&&a[6]<=65504&&a[6]%4==0)printf("%.0f",32+a[6]);else exit 30}')
    [ $? -eq 0 ] && [ -n "$ckb_words" ] && [ "$ckb_words" -le "$ckb_size" ] || { printf 'IMAGE_END|unsupportedOrMalformedHeader\n'; return; }
    ckb_hlen=$ckb_words
    ckb_range "$ckb_file" header 0 "$ckb_hlen" || { printf 'IMAGE_END|headerReadFailed\n'; return; }
    ckb_layout_text=$(ckb_layout "$ckb_file" "$ckb_hlen")
    [ $? -eq 0 ] && [ "$(printf '%s\n' "$ckb_layout_text" | tail -n 1)" = LAYOUT_OK ] || { printf 'IMAGE_END|layoutRejected\n'; return; }
    ckb_uuid=$(printf '%s\n' "$ckb_layout_text" | awk -F'|' '$1=="UUID"{print $2}')
    printf 'UUID|%s\n' "$ckb_uuid"
    if [ "$ckb_sdk" = PRIMARY ]; then
        ckb_after=$(ckb_identity "$ckb_file"); printf 'IDENTITY_AFTER|%s\n' "$ckb_after"
        if [ "$ckb_before" = "$ckb_after" ]; then printf 'IMAGE_END|headerOnlyStable\n'; else printf 'IMAGE_END|identityChanged\n'; fi
        return
    fi
    while IFS='|' read -r ckb_type ckb_kind ckb_off ckb_len ckb_extra; do
        case "$ckb_type" in SECTION|LINKEDIT) ;; *) continue;; esac
        [ "$ckb_len" -gt 0 ] || continue
        if [ "$ckb_off" -lt "$ckb_hlen" ] || [ $((ckb_off+ckb_len)) -gt "$ckb_size" ]; then printf 'RANGE_SKIP|%s|%s|%s|invalidRange\n' "$ckb_kind" "$ckb_off" "$ckb_len"; continue; fi
        ckb_overlap=$(printf '%s\n' "$ckb_layout_text" | awk -F'|' -v o="$ckb_off" -v n="$ckb_len" '$1=="CRYPT" && $4!=0 && o<$2+$3 && o+n>$2 {v=1} END{print v+0}')
        if [ "$ckb_overlap" != 0 ]; then printf 'RANGE_SKIP|%s|%s|%s|encrypted\n' "$ckb_kind" "$ckb_off" "$ckb_len"; continue; fi
        ckb_remaining=$ckb_len; ckb_cursor=$ckb_off
        while [ "$ckb_remaining" -gt 0 ]; do
            ckb_chunk=$ckb_remaining; [ "$ckb_chunk" -le 1048576 ] || ckb_chunk=1048576
            if ! ckb_range "$ckb_file" "$ckb_kind" "$ckb_cursor" "$ckb_chunk"; then
                printf 'RANGE_REMAINDER|%s|%s|%s|incomplete\n' "$ckb_kind" "$ckb_cursor" "$ckb_remaining"; break
            fi
            ckb_cursor=$((ckb_cursor+ckb_chunk)); ckb_remaining=$((ckb_remaining-ckb_chunk))
        done
    done <<< "$ckb_layout_text"
    ckb_after=$(ckb_identity "$ckb_file")
    printf 'IDENTITY_AFTER|%s\n' "$ckb_after"
    if [ "$ckb_before" = "$ckb_after" ]; then printf 'IMAGE_END|identityStable\n'; else printf 'IMAGE_END|identityChanged\n'; fi
}
ckb_containers() {
    local ckb_info ckb_rows ckb_role ckb_path ckb_resolved ckb_id ckb_hash_value ckb_n=0 ckb_status ckb_row
    ckb_info=$(timeout 8 uicache -i "$CKB_BUNDLE" 2>/dev/null)
    if [ $? -ne 0 ]; then printf 'CONTAINERS_END|metadataUnavailable|0\n'; return; fi
    ckb_rows=$(printf '%s\n' "$ckb_info" | awk '
    /^Container Path: / {s=substr($0,17); if(s ~ /^\//)print "container|" s;else bad=1}
    /^Data Container Path: / {s=substr($0,22); if(s ~ /^\//)print "home|" s;else bad=1}
    /^Group Container: / {s=$0;sub(/^Group Container: /,"",s);if(index(s," -> /")){sub(/^.* -> /,"",s);print "group|" s}else bad=1}
    /^App Plugin Container: / {s=$0;sub(/^App Plugin Container: /,"",s);if(index(s," -> /")){sub(/^.* -> /,"",s);print "plugin|" s}else bad=1}
    END{if(bad)exit 33}')
    if [ $? -ne 0 ]; then printf 'CONTAINERS_END|metadataMalformed|0\n'; return; fi
    while IFS='|' read -r ckb_role ckb_path; do
        [ -n "$ckb_role" ] || continue
        ckb_n=$((ckb_n+1)); [ "$ckb_n" -le 128 ] || { printf 'CONTAINERS_END|entryLimit|128\n'; return; }
        ckb_hash_value=$(ckb_hash "$ckb_path")
        ckb_resolved=$(rootfs "$ckb_path" 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$ckb_resolved" ]; then ckb_status=pathUnavailable; ckb_id=
        elif [ -L "$ckb_resolved" ]; then ckb_status=symlink; ckb_id=
        elif [ ! -d "$ckb_resolved" ]; then ckb_status=notDirectory; ckb_id=
        else ckb_id=$(ckb_identity "$ckb_resolved"); if [ $? -eq 0 ]; then ckb_status=statAvailable; else ckb_status=statUnavailable; fi
        fi
        printf 'CONTAINER|%s|%s|%s|%s\n' "$ckb_role" "$ckb_hash_value" "$ckb_status" "$ckb_id"
    done <<< "$ckb_rows"
    printf 'CONTAINERS_END|complete|%s\n' "$ckb_n"
}
ckb_alog() {
    local ckb_info ckb_source ckb_root ckb_home ckb_before ckb_after ckb_path ckb_relative ckb_kind ckb_family ckb_stats ckb_depth ckb_items=0 ckb_samples=0 ckb_time=$SECONDS ckb_status=complete ckb_base ckb_find_status=missing ckb_mode ckb_filetype
    printf 'ALOG_BEGIN|%s\n' "$CKB_ALIAS"
    ckb_info=$(timeout 8 uicache -i "$CKB_BUNDLE" 2>/dev/null)
    [ $? -eq 0 ] || { printf 'ALOG_END|metadataUnavailable|0|0\n'; return; }
    ckb_source=$(printf '%s\n' "$ckb_info" | awk '/^Data Container Path: /{n++;s=substr($0,22)}END{if(n==1&&s ~ /^\//)print s;else exit 31}')
    [ $? -eq 0 ] && [ -n "$ckb_source" ] || { printf 'ALOG_END|noHome|0|0\n'; return; }
    ckb_root=$(rootfs "$ckb_source") || { printf 'ALOG_END|pathUnavailable|0|0\n'; return; }
    ckb_home=$(realpath -- "$ckb_root" 2>/dev/null) || { printf 'ALOG_END|homeUnresolved|0|0\n'; return; }
    ckb_root="$ckb_home/Library/alog"
    if [ -L "$ckb_root" ] || [ ! -d "$ckb_root" ]; then printf 'ALOG_END|absentOrSymlink|0|0\n'; return; fi
    ckb_root=$(realpath -- "$ckb_root" 2>/dev/null) || { printf 'ALOG_END|rootUnresolved|0|0\n'; return; }
    case "$ckb_root" in "$ckb_home"/*) ;; *) printf 'ALOG_END|outsideHome|0|0\n'; return;; esac
    ckb_before=$(ckb_identity "$ckb_root") || { printf 'ALOG_END|statUnavailable|0|0\n'; return; }
    printf 'ALOG_IDENTITY_BEFORE|%s\n' "$ckb_before"
    # GNU find -P does not follow child symlinks. NUL framing prevents names from
    # becoming commands or forged records. No original filename is emitted.
    while IFS= read -r -d '' ckb_path; do
        case "$ckb_path" in CKB_FIND_STATUS=*) ckb_find_status=${ckb_path#CKB_FIND_STATUS=}; break;; '') continue;; esac
        if [ "$ckb_items" -ge 256 ]; then ckb_status=entryLimit; break; fi
        if [ $((SECONDS-ckb_time)) -ge 10 ] || ! ckb_check_budget; then ckb_status=timeBudget; break; fi
        ckb_items=$((ckb_items+1)); ckb_relative=${ckb_path#"$ckb_root/"}
        ckb_depth=$(printf '%s' "$ckb_relative" | awk -F/ '{print NF}')
        ckb_base=${ckb_relative##*/}; ckb_kind=other
        case "$ckb_relative" in ready/*) ckb_kind=ready;; default/ready/*) ckb_kind=defaultReady;; prepare/*|*/prepare/*) ckb_kind=prepare;; AWELive/ready/*|Timor/ready/*|IM/ready/*|Knowledge/ready/*|MainFrame/ready/*|Commerce/ready/*|CJPay/ready/*|MetaSec/ready/*) ckb_kind=knownModuleReady;; esac
        ckb_family=other
        if [[ "$ckb_base" =~ ^BDALog_[0-9]{8}_[0-9]{6}\.alog\.iOS\.[0-9]+$ ]]; then ckb_family=BDALog; fi
        if [[ "$ckb_base" =~ ^(AWELive|Timor|IM|Knowledge|MainFrame|Commerce|CJPay|MetaSec)_BDALog_[0-9]{8}_[0-9]{6}\.alog\.iOS\.[0-9]+$ ]]; then ckb_family=moduleBDALog; fi
        ckb_stats=$(stat -c '%f|%s|%b|%h|%Y|%Z' -- "$ckb_path" 2>/dev/null)
        if [ $? -ne 0 ]; then printf 'ALOG_ITEM|%s|%s|%s|%s|statFailed\n' "$ckb_items" "$ckb_depth" "$ckb_kind" "$ckb_family"; ckb_status=statPartial; continue; fi
        ckb_mode=${ckb_stats%%|*}; ckb_filetype=$((16#$ckb_mode & 61440))
        if [ "$ckb_filetype" -eq 32768 ] && [ "$ckb_samples" -lt 64 ]; then
            ckb_samples=$((ckb_samples+1))
            printf 'ALOG_ITEM|%s|%s|%s|%s|%s\n' "$ckb_items" "$ckb_depth" "$ckb_kind" "$ckb_family" "$ckb_stats"
        else
            printf 'ALOG_SHAPE|%s|%s|%s|%s|%s\n' "$ckb_items" "$ckb_depth" "$ckb_kind" "$ckb_family" "$ckb_filetype"
        fi
    done < <(timeout 10 find -P "$ckb_root" -mindepth 1 -maxdepth 3 -print0 2>/dev/null; printf 'CKB_FIND_STATUS=%s\0' "$?")
    printf 'ALOG_ENUMERATION|%s\n' "$ckb_find_status"
    if [ "$ckb_status" = complete ] && [ "$ckb_find_status" != 0 ]; then ckb_status=enumerationIncomplete; fi
    ckb_after=$(ckb_identity "$ckb_root")
    printf 'ALOG_IDENTITY_AFTER|%s\n' "$ckb_after"
    [ "$ckb_before" = "$ckb_after" ] || ckb_status=identityChanged
    printf 'ALOG_END|%s|%s|%s\n' "$ckb_status" "$ckb_items" "$ckb_samples"
}
ckb_members=$(timeout 20 uicache -l 2>/dev/null)
[ $? -eq 0 ] || { printf 'FATAL|membershipUnavailable\n'; exit 40; }
ckb_valid_members=$(printf '%s\n' "$ckb_members" | awk 'BEGIN{FS=" : "} NF==2&&$1 ~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/&&$2 ~ /^\// {print $1 "|" $2;next} {bad=1} END{if(bad)exit 41}')
[ $? -eq 0 ] && [ -n "$ckb_valid_members" ] || { printf 'FATAL|membershipMalformed\n'; exit 41; }
while IFS='|' read -r CKB_BUNDLE ckb_source; do
    if [ "$CKB_APP_COUNT" -ge 512 ] || ! ckb_check_budget; then printf 'MEMBERSHIP_TRUNCATED\n'; break; fi
    CKB_APP_COUNT=$((CKB_APP_COUNT+1)); CKB_ALIAS=$(printf 'a%04d' "$CKB_APP_COUNT")
    ckb_baseline "$CKB_BUNDLE"
    printf 'APP_BEGIN|%s|%s|%s\n' "$CKB_ALIAS" "$(ckb_b64 "$CKB_BUNDLE")" "$(ckb_hash "$ckb_source")"
    ckb_app=$(rootfs "$ckb_source")
    if [ $? -ne 0 ] || [ ! -d "$ckb_app" ]; then printf 'APP_END|bundleUnavailable\n'; continue; fi
    ckb_app=$(realpath -- "$ckb_app" 2>/dev/null)
    [ -n "$ckb_app" ] || { printf 'APP_END|bundleUnresolved\n'; continue; }
    ckb_app_before=$(ckb_identity "$ckb_app")
    ckb_version=$(ckb_plist_key "$ckb_app/Info.plist" CFBundleShortVersionString); ckb_vcode=$?
    ckb_build=$(ckb_plist_key "$ckb_app/Info.plist" CFBundleVersion); ckb_bcode=$?
    printf 'APP_VERSION|%s|%s|%s|%s\n' "$ckb_vcode" "$(ckb_b64 "$ckb_version")" "$ckb_bcode" "$(ckb_b64 "$ckb_build")"
    ckb_state=versionUnavailable
    if [ "$CKB_OLD_KNOWN" = 0 ]; then ckb_state=newRegistration
    elif [ "$ckb_vcode" = 0 ] && [ "$ckb_bcode" = 0 ]; then
        if [ "$ckb_version" = "$CKB_OLD_VERSION" ] && [ "$ckb_build" = "$CKB_OLD_BUILD" ] && [ "$(ckb_hash "$ckb_source")" = "$CKB_OLD_PATH" ]; then ckb_state=sameRegistrationVersion; else ckb_state=installationChanged; fi
    fi
    printf 'INSTALLATION|%s\n' "$ckb_state"
    ckb_containers
    ckb_exec=$(ckb_plist_key "$ckb_app/Info.plist" CFBundleExecutable); ckb_ecode=$?
    if [ "$ckb_ecode" = 0 ]; then ckb_esource=currentPlist
    elif [ -n "$CKB_OLD_EXEC" ]; then ckb_exec=$CKB_OLD_EXEC; ckb_esource=baselineCandidate
    else ckb_exec=; ckb_esource=unavailable
    fi
    printf 'EXECUTABLE_SOURCE|%s|%s\n' "$ckb_esource" "$ckb_ecode"
    if [[ "$ckb_exec" =~ ^[A-Za-z0-9_.+-]+$ ]]; then ckb_image "$ckb_app" PRIMARY "$ckb_exec"
    else printf 'PRIMARY_UNAVAILABLE|executableNameUnavailableOrUnsupported\n'
    fi
    for ckb_sdk in $CKB_SDKS; do
        if [ -L "$ckb_app/Frameworks/$ckb_sdk.framework" ]; then printf 'FRAMEWORK_CHECK|%s|symlink\n' "$ckb_sdk"
        elif [ -d "$ckb_app/Frameworks/$ckb_sdk.framework" ]; then printf 'FRAMEWORK_CHECK|%s|present\n' "$ckb_sdk"; ckb_image "$ckb_app" "$ckb_sdk"
        elif [ -r "$ckb_app" ] && [ -x "$ckb_app" ]; then printf 'FRAMEWORK_CHECK|%s|absent\n' "$ckb_sdk"
        else printf 'FRAMEWORK_CHECK|%s|inaccessible\n' "$ckb_sdk"
        fi
    done
    if [ "$CKB_ALOG" = 1 ]; then ckb_alog; fi
    ckb_app_after=$(ckb_identity "$ckb_app")
    if [ -n "$ckb_app_before" ] && [ "$ckb_app_before" = "$ckb_app_after" ]; then printf 'APP_END|identityStable\n'; else printf 'APP_END|identityChanged\n'; fi
done <<< "$ckb_valid_members"
printf '%s_END|%s|%s|%s\n' "$CKB_TAG" "$CKB_APP_COUNT" "$CKB_IMAGES" "$CKB_TOTAL"
CK_ALLAPP_TECH_136_SCRIPT
