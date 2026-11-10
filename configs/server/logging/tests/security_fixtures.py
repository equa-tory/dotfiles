"""Synthetic LogQL fixtures. Supply a private/disposable Loki URL; no real account changes."""
import argparse,json,pathlib,sys,time,urllib.parse,urllib.request,uuid
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
import monitoring
def check(url):
 host='fixture-security-'+uuid.uuid4().hex[:10]
 now=time.time_ns()
 streams=[
  {'stream':{'host':host,'source':'journal','service_name':'sshd.service'},'values':[[str(now),'Accepted publickey for fixture from 192.0.2.1 port 12345 ssh2 SYNTHETIC'],[str(now+1),'Accepted password for fixture from 192.0.2.2 port 23456 ssh2 SYNTHETIC'],[str(now+2),'Failed password for fixture from 192.0.2.3 port 34567 ssh2 SYNTHETIC']]},
  {'stream':{'host':host,'source':'journal','service_name':'fleet-accounts.service'},'values':[[str(now),'new_local_account username=fixture uid=1234 account_type=user SYNTHETIC'],[str(now+1),'Initial account baseline established SYNTHETIC']]},
 ]
 request=urllib.request.Request(url.rstrip('/')+'/loki/api/v1/push',data=json.dumps({'streams':streams}).encode(),headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(request,timeout=15) as response:assert response.status==204
 rules={r['uid']:r for r in monitoring.rules('fixture-loki')['groups'][0]['rules']}
 for uid,expected in [('fleet-ssh-login',2),('fleet-new-account',1)]:
  expression=rules[uid]['data'][0]['model']['expr'].replace('{','{host='+json.dumps(host)+',',1)
  endpoint=url.rstrip('/')+'/loki/api/v1/query?'+urllib.parse.urlencode({'query':expression})
  result=json.load(urllib.request.urlopen(endpoint,timeout=15))['data']['result']
  assert len(result)==1 and float(result[0]['value'][1])==expected,(uid,result)
  print(uid,'passed:',expected,'matching events; nonmatching events excluded')
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--loki-url',required=True);args=p.parse_args();check(args.loki_url)
