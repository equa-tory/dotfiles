from common import *
import base64,socket,time,urllib.request,urllib.error

def render(host,url,user,docker=False,include_monitoring=False):
 s=(ROOT/'agent.alloy.template').read_text()
 ds=(ROOT/'docker.alloy.template').read_text() if docker else ''
 if docker and not include_monitoring:
  ds=ds.replace('  targets = discovery.docker.containers.targets','''  targets = discovery.docker.containers.targets
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex = "/(grafana|loki|alloy)([-_].*)?"
    action = "drop"
  }''')
 return s.replace('// __DOCKER__',ds).replace('__HOST__',json.dumps(validate_host(host))).replace('__ENDPOINT__',json.dumps(endpoint(url))).replace('__USERNAME__',json.dumps(user))

def probe(url,user,password,host):
 data=json.dumps({'streams':[{'stream':{'host':host,'source':'installer','service_name':'alloy-setup'},'values':[[str(time.time_ns()),'Alloy installer authenticated HTTPS connectivity check']]}]}).encode()
 auth=base64.b64encode((user+':'+password).encode()).decode()
 req=urllib.request.Request(url,data=data,headers={'Authorization':'Basic '+auth,'Content-Type':'application/json'})
 try:
  with urllib.request.urlopen(req,timeout=20) as response:
   if response.status!=204:raise RuntimeError('Unexpected Loki response: '+str(response.status))
 except urllib.error.HTTPError as e:raise RuntimeError(f'Loki returned HTTP {e.code}; check credentials and the Caddy IP allowlist.') from None
 except urllib.error.URLError as e:raise RuntimeError('Cannot reach Loki over verified HTTPS: '+str(e.reason)) from None

def install_package():
 if shutil.which('alloy'):return
 if not shutil.which('apt-get'):raise RuntimeError('Automatic package installation supports Debian/Ubuntu. Install Alloy from Grafana first, then rerun this module.')
 if not yes('Install Alloy from the official Grafana APT repository?',True):raise RuntimeError('Alloy is required.')
 sudo(['apt-get','update']);sudo(['apt-get','install','-y','ca-certificates','curl','gpg'])
 with tempfile.TemporaryDirectory() as tmp:
  key=pathlib.Path(tmp)/'grafana.asc'
  run(['curl','--fail','--silent','--show-error','--location','https://apt.grafana.com/gpg-full.key','-o',key])
  sudo(['install','-d','-m','0755','/etc/apt/keyrings'])
  sudo(['install','-m','0644',key,'/etc/apt/keyrings/grafana.asc'])
 write_root('/etc/apt/sources.list.d/grafana.list','deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main\n')
 sudo(['apt-get','update']);sudo(['apt-get','install','-y','alloy'])

def install():
 if not shutil.which('systemctl'):raise RuntimeError('This module requires Linux with systemd.')
 with socket.socket() as listener:
  try:listener.bind(('127.0.0.1',12345))
  except OSError:
   if subprocess.run(['systemctl','is-active','--quiet','alloy']).returncode!=0:raise RuntimeError('Port 12345 is occupied by another service; resolve that conflict before installing Alloy.')
 print('Install only Alloy on a VPS. It sends logs to the central Loki through Caddy HTTPS; no FRP setup is needed.')
 for name,ip in FLEET['machines'].items():print(f'  {name:12} {ip}')
 existing=read_root('/etc/alloy/config.alloy') if exists_root('/etc/alloy/config.alloy') else ''
 match=re.search(r'host\s*=\s*"([^"]+)"',existing)
 host=validate_host(ask('Machine name',match.group(1) if match else socket.gethostname()))
 url=endpoint(ask('Loki push URL',FLEET['endpoint']))
 user=ask('Agent username',host)
 if not re.fullmatch(r'[a-zA-Z0-9_.-]+',user):raise ValueError('Invalid agent username')
 password=ask('Agent password (blank keeps the installed password)',secret=True)
 if not password and exists_root('/etc/alloy/loki.password'):password=read_root('/etc/alloy/loki.password').rstrip('\n')
 if not password:raise ValueError('Provision a matching Caddy user first; a password is required.')
 docker=pathlib.Path('/var/run/docker.sock').exists() and yes('Collect Docker container logs?',True)
 monitor=docker and yes('Include noisy Grafana/Loki/Alloy container logs?',False)
 config=render(host,url,user,docker,monitor)
 probe(url,user,password,host)
 print('HTTPS authentication and IP allowlist check passed.')
 install_package()
 for group in ('adm','systemd-journal')+ (('docker',) if docker else ()):
  if subprocess.run(['getent','group',group],stdout=subprocess.DEVNULL).returncode==0:sudo(['usermod','-aG',group,'alloy'])
 paths=['/etc/alloy/config.alloy','/etc/alloy/loki.password','/etc/systemd/system/alloy.service.d/equa-logging.conf']
 old={p:backup(p) for p in paths}
 was_active=subprocess.run(['systemctl','is-active','--quiet','alloy']).returncode==0
 try:
  write_root(paths[1],password,mode='0640',group='alloy',save=False)
  write_root(paths[0],config,mode='0640',group='alloy',save=False)
  sudo(['runuser','-u','alloy','--',shutil.which('alloy'),'validate',paths[0]])
  write_root(paths[2],'[Service]\nExecStart=\nExecStart='+shutil.which('alloy')+' run --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy /etc/alloy/config.alloy\n',save=False)
  sudo(['systemctl','daemon-reload']);sudo(['systemctl','enable','alloy']);sudo(['systemctl','restart','alloy'])
  time.sleep(2);sudo(['systemctl','is-active','--quiet','alloy'])
 except Exception:
  for path,saved in old.items():
   if saved:sudo(['cp','-a',saved,path])
   else:sudo(['rm','-f',path])
  sudo(['systemctl','daemon-reload'])
  sudo(['systemctl','restart' if was_active else 'stop','alloy'])
  raise
 print(f'Alloy installed as {host}. Open Grafana → Fleet Logs → Machine: {host}.')
 print('Credentials: /etc/alloy/loki.password (root:alloy 0640); Alloy UI: loopback only. Logs: sudo journalctl -u alloy -n 30')
if __name__=='__main__':main(install)
