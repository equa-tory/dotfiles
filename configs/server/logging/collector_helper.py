#!/usr/bin/env python3
"""Heartbeat, persistent account baseline and atomic NVIDIA textfile collection."""
import argparse,csv,json,os,pathlib,subprocess,tempfile,time
def atomic(path,text):
 path=pathlib.Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 fd,tmp=tempfile.mkstemp(dir=path.parent,prefix='.'+path.name)
 try:
  with os.fdopen(fd,'w') as f:f.write(text);f.flush();os.fsync(f.fileno())
  os.chmod(tmp,0o644);os.replace(tmp,path)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)
def emit(message,tag):
 subprocess.run(['logger','-t',tag,'--',message],check=True)
def accounts(passwd,state,uid_min=1000):
 current={}
 for line in pathlib.Path(passwd).read_text().splitlines():
  fields=line.split(':')
  if len(fields)>=4:current[fields[0]]=int(fields[2])
 p=pathlib.Path(state)
 if p.exists():
  old=json.loads(p.read_text())
  for name,uid in current.items():
   if name not in old:emit('new_local_account username='+name+' uid='+str(uid)+' account_type='+('service' if uid<uid_min or uid==65534 else 'user'),'fleet-accounts')
 atomic(p,json.dumps(current,sort_keys=True))
def gpu(path):
 now=time.time();lines=['fleet_gpu_collection_timestamp_seconds '+str(now)]
 try:
  result=subprocess.run(['nvidia-smi','--query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu','--format=csv,noheader,nounits'],capture_output=True,text=True,timeout=15,check=True)
  rows=list(csv.reader(result.stdout.splitlines()))
  if not rows:raise ValueError('No GPUs')
  for row in rows:
   idx=int(row[0]);values=[float(x) for x in row[1:]]
   for name,value in zip(['utilization_percent','memory_used_bytes','memory_total_bytes','temperature_celsius'],[values[0],values[1]*1048576,values[2]*1048576,values[3]]):
    lines.append('fleet_gpu_'+name+'{gpu="'+str(idx)+'"} '+str(value))
  lines.append('fleet_gpu_collection_success 1')
 except (OSError,ValueError,subprocess.SubprocessError):
  lines.append('fleet_gpu_collection_success 0')
 atomic(path,'\n'.join(lines)+'\n')
def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['heartbeat','accounts','gpu']);p.add_argument('--state',default='/var/lib/fleet-monitoring/accounts.json');p.add_argument('--passwd',default='/etc/passwd');p.add_argument('--output',default='/var/lib/fleet-monitoring/textfile/gpu.prom');a=p.parse_args()
 if a.action=='heartbeat':emit('fleet_heartbeat','fleet-heartbeat')
 elif a.action=='accounts':accounts(a.passwd,a.state)
 else:gpu(a.output)
if __name__=='__main__':main()
