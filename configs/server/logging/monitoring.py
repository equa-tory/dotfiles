"""Reusable fleet monitoring renderers. No runtime credentials belong here."""
import json,pathlib,re,urllib.parse,math,hashlib
ROOT=pathlib.Path(__file__).resolve().parent
DEFAULTS={'cpu_percent':90,'outgoing_mbps':100,'outgoing_pps':10000,'disk_used_percent':70,'disk_fill_hours':24}
def inventory():
 p=ROOT/'monitoring.json'
 return validate_config(json.loads(p.read_text()))
def validate_config(config):
 machines=config.get('machines')
 if not isinstance(machines,dict) or not machines:raise ValueError('Configure at least one expected machine')
 for host,settings in machines.items():
  if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,62}',host):raise ValueError('Invalid expected host: '+host)
  if not isinstance(settings,dict):raise ValueError('Host thresholds must be an object')
  for key,value in settings.items():
   if key not in DEFAULTS:raise ValueError('Unknown threshold: '+key)
   if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or value<=0:raise ValueError('Threshold must be a positive finite number: '+key)
   if key in ('cpu_percent','disk_used_percent') and value>100:raise ValueError('Percentage threshold cannot exceed 100')
 if not isinstance(config.get('gpu_hosts',[]),list) or any(h not in machines for h in config.get('gpu_hosts',[])):raise ValueError('GPU hosts must be expected machines')
 return config
def heartbeat_uid(host):
 value='fleet-heartbeat-'+host
 return value if len(value)<=40 else 'fleet-heartbeat-'+hashlib.sha256(host.encode()).hexdigest()[:24]
def metrics(host,url,user='',interfaces=None,container=False):
 if not re.fullmatch(r'[A-Za-z0-9_.-]+',host):raise ValueError('Invalid host')
 u=urllib.parse.urlsplit(url)
 if not u.hostname or u.username or u.password or u.query or u.fragment or u.path!="/api/v1/write" or (u.scheme!="https" and not (u.scheme=="http" and u.hostname in ("127.0.0.1","localhost","::1"))):raise ValueError("Use an HTTPS metrics URL or a local loopback receiver, ending in /api/v1/write")
 interfaces=interfaces or ['eth.*','ens.*','enp.*','eno.*']
 pattern='^(?:'+'|'.join(interfaces)+')$'
 auth=('    basic_auth {\n      username = '+json.dumps(user)+'\n      password_file = "/etc/alloy/loki.password"\n    }\n') if user else ''
 prefix='/host' if container else ''
 return '''
// BEGIN fleet metrics
prometheus.exporter.unix "fleet" {
  set_collectors = ["cpu", "meminfo", "filesystem", "netdev", "textfile", "uname", "time"]
  procfs_path = "'''+prefix+'''/proc"
  sysfs_path = "'''+prefix+'''/sys"
  rootfs_path = "'''+(prefix or '/')+'''"
  filesystem {
    fs_types_exclude = "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|pstore|ramfs|rpc_pipefs|securityfs|squashfs|sysfs|tmpfs|tracefs)$"
    mount_points_exclude = "^/(dev|proc|sys|run|var/lib/docker|var/lib/containers|snap)(/|$)"
  }
  netdev {
    device_include = '''+json.dumps(pattern)+'''
  }
  textfile {
    directory = "/var/lib/fleet-monitoring/textfile"
  }
}
discovery.relabel "fleet_metrics" {
  targets = prometheus.exporter.unix.fleet.targets
  rule {
    target_label = "host"
    replacement = '''+json.dumps(host)+'''
  }
  rule {
    target_label = "job"
    replacement = "fleet-host"
  }
}
prometheus.scrape "fleet" {
  targets = discovery.relabel.fleet_metrics.output
  scrape_interval = "30s"
  forward_to = [prometheus.remote_write.fleet.receiver]
}
prometheus.remote_write "fleet" {
  endpoint {
    url = '''+json.dumps(url)+'''
'''+auth+'''  }
}
// END fleet metrics
'''
def strip_metrics(s):return re.sub(r'\n// BEGIN fleet metrics.*?// END fleet metrics\n','\n',s,flags=re.S)
def cpu():return '100 * (1 - avg by(host) (rate(node_cpu_seconds_total{mode="idle"}[5m])))'
def ram():return '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'
def traffic(direction='transmit',packets=False,window='5m'):
 return 'sum by(host) (rate(node_network_'+direction+('_packets_total' if packets else '_bytes_total')+'['+window+']))'+('' if packets else ' * 8 / 1e6')
def missing(metric):
 return 'fleet_expected_host unless on(host) (max by(host) (timestamp('+metric+')) > time() - 300)'
def rules(loki_uid,base_url='',config=None):
 defs=[
 ('fleet-high-cpu','High CPU',cpu()+' > on(host) fleet_threshold_cpu_percent','15m','prometheus','Five-minute CPU average above the machine threshold.'),
 ('fleet-high-bandwidth','High outgoing bandwidth',traffic()+' > on(host) fleet_threshold_outgoing_mbps','15m','prometheus','Suspicious outgoing traffic indicator; does not prove DDoS and does not block traffic.'),
 ('fleet-high-packets','High outgoing packet rate',traffic(packets=True,window='1m')+' > on(host) fleet_threshold_outgoing_pps','5m','prometheus','Suspicious outgoing packet rate; investigate workload and destinations.'),
 ('fleet-disk-prediction','Disk filling quickly','(100 * (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) > on(host) group_left() fleet_threshold_disk_used_percent) and (node_filesystem_readonly == 0) and (deriv(node_filesystem_avail_bytes[6h]) < 0) and (node_filesystem_avail_bytes / -deriv(node_filesystem_avail_bytes[6h]) < on(host) group_left() (fleet_threshold_disk_fill_hours * 3600)) and (count_over_time(node_filesystem_avail_bytes[6h]) >= 660) and (time() - min_over_time(timestamp(node_filesystem_avail_bytes)[6h:1m]) >= 21000)','15m','prometheus','Writable filesystem is over 70% used and forecast to fill within 24h, with nearly six hours of history.'),
 ('fleet-ssh-login','Successful SSH login','sum by(host) (count_over_time({source="journal",service_name=~"ssh.*"} |~ "Accepted (publickey|password) for " [5m]))','0s',loki_uid,'Successful SSH authentication during the last five minutes. Events are grouped by machine.'),
 ('fleet-new-account','New local account','sum by(host) (count_over_time({service_name=~"fleet-accounts(.service)?"} |= "new_local_account " [5m]))','0s',loki_uid,'Persistent watcher observed a new /etc/passwd username. See Security for individual events.'),
 ('fleet-metrics-stopped','Metrics stopped',missing('node_time_seconds'),'0s','prometheus','Expected machine has no fresh host measurement in five minutes.'),
 ]
 # Heartbeat is queried from Loki and joined to the expected-host vector by Grafana expressions.
 result=[]
 for uid,title,expr,hold,ds,description in defs:
  data=[{'refId':'A','queryType':'instant' if ds==loki_uid else '', 'relativeTimeRange':{'from':600,'to':0},'datasourceUid':ds,'model':{'queryType':'instant','refId':'A','expr':expr,'instant':True,'range':False,'intervalMs':1000,'maxDataPoints':43200}}]
  data.append({'refId':'C','relativeTimeRange':{'from':0,'to':0},'datasourceUid':'__expr__','model':{'refId':'C','type':'threshold','expression':'A','conditions':[{'evaluator':{'type':'gt','params':[0]},'operator':{'type':'and'},'query':{'params':['C']},'reducer':{'type':'last','params':[]},'type':'query'}]}})
  result.append({'uid':uid,'title':title,'condition':'C','data':data,'for':hold,'noDataState':'OK','execErrState':'Error','annotations':{'__panelId__':'1','summary':title+' on {{ $labels.host }}','description':description,'runbook_url':base_url+'/d/fleet-security' if ds==loki_uid else base_url+'/d/fleet-usage','__dashboardUid__':'fleet-security' if ds==loki_uid else 'fleet-usage'},'labels':{'service':'host','severity':'warning'},'isPaused':False})
 # An individual Loki absent_over_time expression per explicit host ensures absence never drops a machine.
 for host in (config or inventory())['machines']:
  uid=heartbeat_uid(host)
  expr='absent_over_time({host='+json.dumps(host)+',service_name=~"fleet-heartbeat(.service)?"} |= "fleet_heartbeat" [5m])'
  r=json.loads(json.dumps(result[4]));r.update(uid=uid,title='Logs stopped: '+host);r['data'][0]['model']['expr']=expr;r['labels']['host']=host;r['annotations'].update(__dashboardUid__='fleet-logs',summary='Logs stopped on '+host,description='No journal heartbeat received from this expected host in five minutes.',runbook_url=base_url+'/d/fleet-logs');result.append(r)
 return {'apiVersion':1,'groups':[{'orgId':1,'name':'fleet-monitoring','folder':'Fleet monitoring','interval':'1m','rules':result}]}
NAV=[('Overview','fleet-overview'),('Usage','fleet-usage'),('Problems','fleet-problems'),('Services','fleet-services'),('Security','fleet-security'),('All logs','fleet-logs')]
def variable(name,query=None,values=None):
 d={'name':name,'label':name.capitalize(),'type':'query' if query else 'custom','query':query or values,'hide':0,'multi':True,'includeAll':True,'allValue':'.+' if name=='host' else '.*','current':{'text':'All','value':'$__all'},'options':[]}
 if query:d.update(datasource={'type':'loki','uid':'__LOKI_UID__'},refresh=1)
 return d
def panel(title,expr,kind='timeseries',unit=None,ds='prometheus',description=''):
 d={'title':title,'type':kind,'description':description,'datasource':{'type':'loki' if ds=='__LOKI_UID__' else 'prometheus','uid':ds},'targets':[{'refId':'A','expr':expr,'legendFormat':'{{host}} {{mountpoint}} {{gpu}}','range':True,'queryType':'range'}],'fieldConfig':{'defaults':{'noValue':'Unavailable','unit':unit or 'short'},'overrides':[]},'options':{}}
 if kind=='logs':d['options']={'showTime':True,'showLabels':False,'wrapLogMessage':True,'sortOrder':'Descending','enableLogDetails':True}
 return d
def dashboard(uid,title,panels,loki_uid):
 variables=[variable('host','label_values({host=~".+"}, host)')]
 d={'uid':uid,'title':title,'schemaVersion':39,'version':1,'editable':False,'tags':['fleet'],'timezone':'browser','refresh':'30s','time':{'from':'now-1h','to':'now'},'templating':{'list':variables},'links':[{'title':n,'url':'/d/'+u,'type':'link','includeVars':True,'keepTime':True} for n,u in NAV],'panels':[],'annotations':{'list':[]}}
 for i,p in enumerate(panels):
  p.update(id=i+1,gridPos={'x':0 if p['type'] in ('logs','text','alertlist','table') else (i%2)*12,'y':i*8,'w':24 if p['type'] in ('logs','text','alertlist','table') else 12,'h':8})
  d['panels'].append(p)
 return json.loads(json.dumps(d).replace('__LOKI_UID__',loki_uid))
def dashboards(loki_uid,config=None):
 sel='{host=~"$host"}'
 fs='node_filesystem_readonly{host=~"$host"} == 0'
 gpu=' and on(host) (fleet_gpu_collection_success == 1) and on(host) (fleet_gpu_collection_timestamp_seconds > time()-120)'
 usage=[panel('CPU utilization',cpu()+' and on(host) node_time_seconds{host=~"$host"}',unit='percent'),panel('RAM utilization',ram()+' and on(host) node_time_seconds{host=~"$host"}',unit='percent')]
 for direction,label in [('receive','Incoming'),('transmit','Outgoing')]:
  usage += [panel(label+' traffic',traffic(direction)+' and on(host) node_time_seconds{host=~"$host"}',unit='Mbits'),panel(label+' packets/second',traffic(direction,True,'1m')+' and on(host) node_time_seconds{host=~"$host"}',unit='pps'),panel(label+' transferred in selected period','sum by(host)(increase(node_network_'+direction+'_bytes_total{host=~"$host"}[$__range]))',unit='bytes')]
 usage += [panel('Filesystem available','node_filesystem_avail_bytes{host=~"$host"} and '+fs,unit='bytes'),panel('Filesystem used','(node_filesystem_size_bytes{host=~"$host"} - node_filesystem_avail_bytes) and '+fs,unit='bytes'),panel('GPU utilization','fleet_gpu_utilization_percent{host=~"$host"}'+gpu,unit='percent'),panel('VRAM used','fleet_gpu_memory_used_bytes{host=~"$host"}'+gpu,unit='bytes'),panel('VRAM total','fleet_gpu_memory_total_bytes{host=~"$host"}'+gpu,unit='bytes'),panel('GPU temperature','fleet_gpu_temperature_celsius{host=~"$host"}'+gpu,unit='celsius')]
 status=panel('GPU support and collection','(fleet_gpu_collection_success{host=~"$host"} and on(host) (fleet_gpu_collection_timestamp_seconds > time()-120) and on(host) (max by(host)(timestamp(node_time_seconds)) > time()-300)) or on(host) (((fleet_expected_host{host=~"$host"} unless on(host) fleet_expected_gpu) * -1) and on(host) (max by(host)(timestamp(node_time_seconds)) > time()-300)) or on(host) (fleet_expected_host{host=~"$host"} * (0/0))','stat')
 status['targets'][0].update(instant=True,range=False)
 status['fieldConfig']['defaults']['mappings']=[{'type':'value','options':{'-1':{'text':'No supported GPU','color':'gray'},'0':{'text':'Unavailable','color':'red'},'1':{'text':'Available','color':'green'}}}]
 usage.append(status)
 usage.append({'type':'text','title':'GPU availability','options':{'mode':'markdown','content':'GPU panels display readings only on hosts with a working supported NVIDIA collector. Other machines: **No supported GPU**. Failed or stale collection shows Unavailable. Metrics history starts at deployment; disk forecasts require six hours of history.'}})
 alerts={'type':'alertlist','title':'Active alerts','options':{'stateFilter':{'firing':True,'pending':True,'error':True,'noData':True},'maxItems':100,'sortOrder':1,'viewMode':'list','groupMode':'default'}}
 problems=[alerts, panel('Errors, exceptions and crashes',sel+' |~ "(?i)exception|traceback|panic|segfault|core dumped|fatal|failed|failure|error"','logs',ds='__LOKI_UID__',description='Text patterns are a search aid, not a complete exception detector.')]
 security=[]
 for title,expr in [('Successful SSH logins','{host=~"$host",source="journal",service_name=~"ssh.*"} |~ "Accepted (publickey|password) for "'),('Failed SSH attempts','{host=~"$host",service_name=~"ssh.*"} |~ "(?i)failed (password|publickey|keyboard-interactive)|invalid user|authentication failure|maximum authentication attempts"'),('Sudo',sel+' |~ "(?i)sudo|; USER=.*; COMMAND=|pam_unix\\\\(sudo"'),('New accounts','{host=~"$host",service_name=~"fleet-accounts(.service)?"} |= "new_local_account "'),('Fail2ban',sel+' |~ "(?i)fail2ban|\\\\bBan |\\\\bUnban "')]:security.append(panel(title,expr,'logs',ds='__LOKI_UID__'))
 services=[panel('Service logs','{host=~"$host",service_name=~"$service"}','logs',ds='__LOKI_UID__'),panel('Messages/second','sum by(host,service_name)(rate({host=~"$host",service_name=~"$service"}[1m]))',ds='__LOKI_UID__'),panel('Errors/second','sum by(host,service_name)(rate({host=~"$host",service_name=~"$service"} |~ "(?i)error|failed|fatal|exception" [1m]))',ds='__LOKI_UID__')]
 logs=[panel('All logs','{host=~"$host",service_name=~"$service",source=~"$source"} |~ "${preset:raw}" |= "${text}"','logs',ds='__LOKI_UID__')]
 over=[alerts]
 # Explicit repeated rows do not disappear when a host stops reporting.
 for host in (config or inventory())['machines']:
  over.append({'type':'row','title':host,'collapsed':False})
  fresh=' and on(host) (node_time_seconds{host="'+host+'"} > time()-300)'
  for title,expr,unit in [('Collection health','max by(host)(node_time_seconds{host="'+host+'"} > time()-300)',None),('CPU',cpu()+fresh,'percent'),('RAM',ram()+fresh,'percent'),('Disk used','100 * (1 - node_filesystem_avail_bytes{host="'+host+'"} / node_filesystem_size_bytes) and (node_filesystem_readonly == 0)'+fresh,'percent'),('Outgoing',traffic()+fresh,'Mbits')]:over.append(panel(host+' · '+title,expr,'stat',unit))
 result={}
 for uid,title,panels in [('fleet-overview','Fleet Overview',over),('fleet-usage','Fleet Usage',usage),('fleet-problems','Fleet Problems',problems),('fleet-services','Fleet Services',services),('fleet-security','Fleet Security',security),('fleet-logs','Fleet Logs',logs)]:
  d=dashboard(uid,title,panels,loki_uid)
  if uid in ('fleet-services','fleet-logs'):d['templating']['list'].append(variable('service','label_values({host=~"$host",host!=""}, service_name)'))
  if uid=='fleet-logs':
   d['templating']['list'] += [variable('source','label_values({host=~"$host",host!=""}, source)'),{'name':'text','label':'Contains literal text','type':'textbox','query':'','current':{'text':'','value':''}},{'name':'preset','label':'Search preset','type':'custom','query':'All : .*,Errors : (?i)error|failed|fatal,Exceptions : (?i)exception|traceback|panic|segfault,SSH : (?i)sshd|ssh|Accepted publickey|Accepted password,Sudo : (?i)sudo,Package updates : (?i)apt|dpkg|upgrade|pacman|installed,Journal : .*,Docker : .*','current':{'text':'All','value':'.*'},'options':[]}]
   d['links'].append({'title':'Clear filters','url':'/d/fleet-logs?${host:queryparam}&var-service=%24__all&var-source=%24__all&var-text=&var-preset=.*','keepTime':True})
  result[uid]=json.loads(json.dumps(d).replace('__LOKI_UID__',loki_uid))
 return result
# Keep expected-host configuration in Prometheus rules, independent of agent availability.
def provision(folder,loki_uid,config=None):
 folder=pathlib.Path(folder);cfg=validate_config(config or inventory())
 p=folder/'prometheus';p.mkdir(parents=True,exist_ok=True)
 recordings=[]
 for host in cfg.get('gpu_hosts',[]):recordings.append({'record':'fleet_expected_gpu','expr':'vector(1)','labels':{'host':host}})
 for host,settings in cfg['machines'].items():
  recordings.append({'record':'fleet_expected_host','expr':'vector(1)','labels':{'host':host}})
  for key,default in DEFAULTS.items():
   recordings.append({'record':'fleet_threshold_'+key,'expr':'vector('+str(settings.get(key,default))+')','labels':{'host':host}})
 (p/'fleet.yml').write_text(json.dumps({'groups':[{'name':'fleet-configuration','interval':'30s','rules':recordings}]},indent=2))
 (p/'prometheus.yml').write_text('global:\n  scrape_interval: 30s\n  evaluation_interval: 1m\nrule_files: ["/etc/prometheus/fleet.yml"]\nscrape_configs: []\n')
 path=folder/'grafana/provisioning'
 (path/'datasources').mkdir(parents=True,exist_ok=True)
 (path/'datasources/prometheus.yaml').write_text('apiVersion: 1\ndatasources:\n  - name: Prometheus\n    uid: prometheus\n    type: prometheus\n    access: proxy\n    url: http://prometheus:9090\n    editable: false\n')
 (path/'alerting').mkdir(exist_ok=True)
 alert_file=path/'alerting/fleet.yaml'
 previous=json.loads(alert_file.read_text()) if alert_file.exists() else {}
 rendered=rules(loki_uid,config=cfg)
 previous_uids={r['uid'] for g in previous.get('groups',[]) for r in g.get('rules',[])}
 current_uids={r['uid'] for g in rendered['groups'] for r in g['rules']}
 rendered['deleteRules']=[{'orgId':1,'uid':uid} for uid in sorted(previous_uids-current_uids)]
 alert_file.write_text(json.dumps(rendered,indent=2))
 (path/'dashboards/json').mkdir(parents=True,exist_ok=True)
 for uid,d in dashboards(loki_uid,config=cfg).items():
  # Expected hosts remain selectable even when their log labels disappear.
  d['templating']['list'][0]=variable('host',values=','.join(cfg['machines']))
  if uid=='fleet-logs':
   d['panels'][0]['targets'][0]['expr']='{host=~"$host",service_name=~"$service",source=~"$source"} ${preset:raw} | label_format __fleet_literal_match=`{{ contains (urldecode "${text:percentencode}") (__line__) }}` | __fleet_literal_match="true" | drop __fleet_literal_match'
   v=d['templating']['list'][-1]
   presets=[('All','|~ ".*"'),('Errors','|~ "(?i)error|failed|fatal"'),('Exceptions','|~ "(?i)exception|traceback|panic|segfault"'),('SSH','|~ "(?i)sshd|ssh|Accepted publickey|Accepted password"'),('Sudo','|~ "(?i)sudo|; USER=.*; COMMAND="'),('Package updates','|~ "(?i)apt|dpkg|upgrade|pacman|installed"'),('Journal','| source="journal"'),('Docker','| source="docker"')]
   v.update(query=','.join(k+' : '+val for k,val in presets),current={'text':'All','value':presets[0][1]},options=[{'text':k,'value':val,'selected':k=='All'} for k,val in presets])
   d['links'][-1]['url']='/d/fleet-logs?${host:queryparam}&var-service=%24__all&var-source=%24__all&var-text=&var-preset='+__import__('urllib.parse',fromlist=['quote']).quote(presets[0][1])
  if uid=='fleet-overview':
   y=0;panels=[d['panels'][0]];panels[0]['gridPos']={'x':0,'y':0,'w':24,'h':5};y=5
   for host in cfg['machines']:
    row=next(x for x in d['panels'] if x['type']=='row' and x['title']==host);row['gridPos']={'x':0,'y':y,'w':24,'h':1};panels.append(row);y+=1
    stats=[x for x in d['panels'] if x['type']=='stat' and x['title'].startswith(host+' · ')]
    for stat in stats:
     stat['targets'][0]['expr']='('+stat['targets'][0]['expr']+') or on(host) (fleet_expected_host{host='+json.dumps(host)+'} * (0/0))'
    for i,x in enumerate(stats):
     x['gridPos']={'x':i*4,'y':y,'w':4,'h':5}
     if i==0:
      x['datasource']={'type':'datasource','uid':'-- Mixed --'}
      x['targets'][0]['datasource']={'type':'prometheus','uid':'prometheus'}
      x['targets'][0]['expr']='(max by(host)(timestamp(node_time_seconds{host='+json.dumps(host)+'}) > bool time()-300)) or on(host) (fleet_expected_host{host='+json.dumps(host)+'} * (0/0))'
      x['targets'][0]['legendFormat']='Metrics'
      x['targets'][0].update(instant=True,range=False)
      x['targets'].append({'refId':'B','datasource':{'type':'loki','uid':loki_uid},'expr':'sum(count_over_time({host='+json.dumps(host)+',source="journal",service_name=~"fleet-heartbeat(.service)?"} |= "fleet_heartbeat" [5m])) > bool 0 or vector(0)','queryType':'instant','legendFormat':'Logs'})
      x['fieldConfig']['defaults']['mappings']=[{'type':'value','options':{'1':{'text':'Fresh','color':'green'},'0':{'text':'Unavailable','color':'red'}}}]
     panels.append(x)
    a={'type':'alertlist','title':host+' · Alerts','options':{'alertInstanceLabelFilter':'{host='+json.dumps(host)+'}','stateFilter':{'firing':True,'pending':True,'error':True,'noData':True},'maxItems':20,'viewMode':'list','groupMode':'default'},'gridPos':{'x':20,'y':y,'w':4,'h':5}}
    panels.append(a);y+=5
   d['panels']=panels
   for i,x in enumerate(panels):x['id']=i+1
  for item in d['panels']:
   for target in item.get('targets',[]):
    datasource=target.get('datasource',item.get('datasource',{}))
    if datasource.get('uid')==loki_uid:
     target['expr']=target['expr'].replace('host=~"$host"','host=~"$host",host!=""')
  name={'fleet-logs':'logs','fleet-security':'security'}.get(uid,uid)
  (path/'dashboards/json'/(name+'.json')).write_text(json.dumps(d,indent=2))

if __name__=='__main__':
 import argparse
 p=argparse.ArgumentParser(description='Render fleet dashboards and alerts from a separate machine/threshold configuration.')
 p.add_argument('--runtime',required=True);p.add_argument('--loki-uid',required=True);p.add_argument('--config',required=True)
 args=p.parse_args();provision(args.runtime,args.loki_uid,json.loads(pathlib.Path(args.config).read_text()))
