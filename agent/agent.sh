#!/bin/bash
# OpenClaw Monitor Agent
set -e
SERVER="" TOKEN="" NAME="" ROLE="worker" INTERVAL=30 DEFAULT_PROV=""

while getopts "s:t:n:r:i:d:" opt; do
  case $opt in s)SERVER="$OPTARG";;t)TOKEN="$OPTARG";;n)NAME="$OPTARG";;r)ROLE="$OPTARG";;i)INTERVAL="$OPTARG";;d)DEFAULT_PROV="$OPTARG";;esac
done
[ -z "$SERVER" ] || [ -z "$TOKEN" ] && echo "Usage: $0 -s SERVER_URL -t TOKEN [-n name] [-r role]" && exit 1

NODE_ID=$(hostname | md5sum 2>/dev/null | cut -c1-12 || md5 -qs "$(hostname)" | cut -c1-12)
NAME="${NAME:-$(hostname)}"
OC_CONFIG=""
for p in "$HOME/.openclaw/openclaw.json" "/root/.openclaw/openclaw.json"; do
  [ -f "$p" ] && OC_CONFIG="$p" && break
done
OC_VERSION=$(openclaw --version 2>/dev/null | head -1 || echo "unknown")

echo "OC Monitor Agent: node=$NODE_ID name=$NAME server=$SERVER"

while true; do
  python3 - "$OC_CONFIG" "$NODE_ID" "$NAME" "$OC_VERSION" "$ROLE" "$DEFAULT_PROV" << 'PYEOF' > /tmp/.oc-agent-payload.json
import json,subprocess,os,platform,time,sys,glob

def run(cmd):
    try: return subprocess.check_output(cmd,shell=True,stderr=subprocess.DEVNULL).decode().strip()
    except: return ''

cfg,nid,name,ver,role = sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5]
default_prov = sys.argv[6] if len(sys.argv)>6 else ''
mac = sys.platform=='darwin'

# Host IP - try multiple interfaces on macOS
if mac:
    host = run("ifconfig | grep 'inet ' | grep -v 127 | head -1 | awk '{print $2}'")
else:
    host = run("hostname -I | awk '{print $1}'")
if not host: host = 'unknown'

# Providers
providers = []
if cfg and os.path.exists(cfg):
    try:
        c = json.load(open(cfg))
        m = c.get('models',{})
        # Extract default from config or -d param
        dp = default_prov or m.get('default','')
        default_name = dp.split('/')[0] if '/' in dp else dp
        for n,p in m.get('providers',{}).items():
            if not isinstance(p,dict): continue
            base = p.get('baseUrl','')
            key = p.get('apiKey','')
            api_type = p.get('api','')
            for mod in p.get('models',[]):
                providers.append({'name':n,'model':mod.get('id',''),'api':api_type,'default':n==default_name,
                                  '_base':base,'_key':key})
        providers.sort(key=lambda x: (not x.get('default',False), x['name']))
    except: pass

# Health check each provider
import urllib.request,urllib.error
def check_provider(p):
    base,key,api = p.get('_base',''),p.get('_key',''),p.get('api','')
    if not base or not key: return {'ok':False,'ms':0,'err':'no config'}
    try:
        t0 = time.time()
        if 'anthropic' in api:
            url = base.rstrip('/')+'/v1/messages'
            data = json.dumps({"model":p['model'],"max_tokens":1,"messages":[{"role":"user","content":"hi"}]}).encode()
            req = urllib.request.Request(url,data,{'Content-Type':'application/json','x-api-key':key,'anthropic-version':'2023-06-01'})
        else:
            url = base.rstrip('/')+'/chat/completions'
            data = json.dumps({"model":p['model'],"max_tokens":1,"messages":[{"role":"user","content":"hi"}]}).encode()
            req = urllib.request.Request(url,data,{'Content-Type':'application/json','Authorization':'Bearer '+key})
        resp = urllib.request.urlopen(req,timeout=10)
        ms = int((time.time()-t0)*1000)
        return {'ok':True,'ms':ms,'err':''}
    except urllib.error.HTTPError as e:
        ms = int((time.time()-t0)*1000)
        code = e.code
        if code == 429: return {'ok':False,'ms':ms,'err':'限额'}
        if code in (402,): return {'ok':False,'ms':ms,'err':'余额不足'}
        return {'ok':True,'ms':ms,'err':''}  # 400/401/403/422 means API is reachable
    except Exception as e:
        return {'ok':False,'ms':0,'err':'timeout'}

for p in providers:
    r = check_provider(p)
    p['status'] = 'ok' if r['ok'] else 'err'
    p['ms'] = r['ms']
    p['err'] = r['err']
    del p['_base'], p['_key']

# CPU
if mac:
    raw = run("ps -A -o %cpu | tail -n +2")
    try: cpu = round(sum(float(x) for x in raw.split() if x) / os.cpu_count(), 1)
    except: cpu = 0
else:
    cpu = float(run("top -bn1 | grep 'Cpu' | awk '{print 100-$8}'") or 0)

# Memory
if mac:
    try:
        vm = run('vm_stat')
        d = {}
        for l in vm.split('\n')[1:]:
            if ':' not in l: continue
            k,v = l.split(':',1)
            d[k.strip()] = int(v.strip().rstrip('.'))
        used = d.get('Pages active',0) + d.get('Pages wired down',0)
        total = used + d.get('Pages free',0) + d.get('Pages inactive',0) + d.get('Pages speculative',0)
        mem = round(used/total*100,1) if total else 0
    except: mem = 0
else:
    mem = float(run("free | awk '/Mem/{printf \"%.1f\",$3/$2*100}'") or 0)

# Disk
disk = float(run("df / | awk 'NR==2{gsub(/%/,\"\",$5);print $5}'") or 0)

# Swap
if mac:
    try:
        sw = run('sysctl vm.swapusage')
        used_sw = float(sw.split('used = ')[1].split('M')[0])
        total_sw = float(sw.split('total = ')[1].split('M')[0])
        swap = round(used_sw/total_sw*100,1) if total_sw > 0 else 0
    except: swap = 0
else:
    swap = float(run("free | awk '/Swap/{if($2>0)printf \"%.1f\",$3/$2*100;else print 0}'") or 0)

# Uptime
if mac:
    try:
        b = run('sysctl -n kern.boottime')
        uptime = int(time.time()) - int(b.split('sec = ')[1].split(',')[0])
    except: uptime = 0
else:
    try: uptime = int(float(open('/proc/uptime').read().split()[0]))
    except: uptime = 0

# Gateway/daemon - check by process name
gw = bool(run('pgrep -f "openclaw"'))
daemon = gw  # if openclaw is running, both are likely up

# Sessions - search for session files
sessions = 0
oc_dir = os.path.expanduser('~/.openclaw')
for sf in [os.path.join(oc_dir,'sessions.json'), os.path.join(oc_dir,'data','sessions.json')]:
    if os.path.exists(sf):
        try: sessions = len(json.load(open(sf))); break
        except: pass
# Fallback: count session dirs
if sessions == 0:
    sess_dir = os.path.join(oc_dir,'sessions')
    if os.path.isdir(sess_dir):
        sessions = len([d for d in os.listdir(sess_dir) if os.path.isdir(os.path.join(sess_dir,d))])

# Token usage from session jsonl files
tok_today=tok_week=tok_month=0
now_ts = time.time()
day_ago = now_ts - 86400
week_ago = now_ts - 7*86400
month_ago = now_ts - 30*86400
sess_dirs = glob.glob(os.path.join(oc_dir,'agents','*','sessions'))
for sd in sess_dirs:
    for jf in glob.glob(os.path.join(sd,'*.jsonl')):
        try:
            mtime = os.path.getmtime(jf)
            if mtime < month_ago: continue
            with open(jf) as f:
                for line in f:
                    if '"usage"' not in line: continue
                    try:
                        d = json.loads(line)
                        u = d.get('message',{}).get('usage',{})
                        if not u: continue
                        ts = d.get('timestamp',0)
                        if isinstance(ts,str):
                            from datetime import datetime
                            ts = datetime.fromisoformat(ts.replace('Z','+00:00')).timestamp()
                        total = u.get('input',0) + u.get('output',0) + u.get('cacheRead',0) + u.get('cacheWrite',0)
                        if ts > day_ago: tok_today += total
                        if ts > week_ago: tok_week += total
                        if ts > month_ago: tok_month += total
                    except: pass
        except: pass

print(json.dumps({
    'id':nid,'name':name,'host':host,
    'os':platform.system()+' '+platform.release()+' '+platform.machine(),
    'oc_version':ver,'role':role,'providers':providers,
    'cpu':cpu,'mem':mem,'disk':disk,'swap':swap,
    'sessions':sessions,'gw_ok':gw,'daemon_ok':daemon,'uptime':uptime,
    'tok_today':tok_today,'tok_week':tok_week,'tok_month':tok_month
}))
PYEOF

  if [ -s /tmp/.oc-agent-payload.json ]; then
    curl -sS -X POST "$SERVER/api/heartbeat" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d @/tmp/.oc-agent-payload.json -m 10 >/dev/null 2>&1 \
      && echo "[$(date +%H:%M:%S)] heartbeat ok" \
      || echo "[$(date +%H:%M:%S)] heartbeat failed"
  fi
  sleep "$INTERVAL"
done
