from common import *
from agent import render
import secrets,socket
TEMPLATES=ROOT/'grafana-loki'
def install():
 if not shutil.which('docker'):raise RuntimeError('Install Docker Engine and the Compose plugin first.')
 run(['docker','compose','version'],stdout=subprocess.DEVNULL)
 run(['docker','info'],stdout=subprocess.DEVNULL)
 folder=pathlib.Path(ask('Central stack directory',str(pathlib.Path.home()/'.local/share/grafana-loki'))).expanduser().resolve()
 if folder.is_relative_to(ROOT.parents[2]):raise ValueError('Runtime files and passwords must be outside the dotfiles repo.')
 existing={}
 if (folder/'.env').exists():
  for line in (folder/'.env').read_text().splitlines():
   if '=' in line:existing.update([line.split('=',1)])
 # Refuse to take over an unrelated stack or reset its database through another Compose project.
 project=folder.name.lower()
 for name in ['grafana','loki','alloy']:
  inspect=subprocess.run(['docker','inspect',name],text=True,capture_output=True)
  if inspect.returncode==0:
   obj=json.loads(inspect.stdout)[0]
   working=obj['Config'].get('Labels',{}).get('com.docker.compose.project.working_dir')
   if not working or pathlib.Path(working).resolve()!=folder:raise RuntimeError(f'Container {name} belongs to another stack at {working}. Choose its existing directory to update it, or keep this module only on a separate central host.')
 bind=ask('Grafana listen IP (loopback is safest)',existing.get('GRAFANA_BIND_IP','127.0.0.1'))
 ipaddress.IPv4Address(bind)
 gp=port(ask('Grafana port',existing.get('GRAFANA_PORT','3003')))
 lp=port(ask('Local Loki port',existing.get('LOKI_PORT','3200')))
 if gp==lp:raise ValueError('Grafana and Loki must use different ports.')
 collector=yes('Collect this host journal and Docker logs too? (root + Docker socket access)',True)
 host=validate_host(ask('Central host log label',socket.gethostname())) if collector else 'hub'
 docker=collector and pathlib.Path('/var/run/docker.sock').exists() and yes('Collect application Docker logs?',True)
 if collector and subprocess.run(['systemctl','is-active','--quiet','alloy']).returncode==0:raise RuntimeError('Native Alloy is already active on this host. Disable the optional Compose collector to avoid collecting the same logs twice.')
 for ip,p,name in [(bind,gp,'grafana'),('127.0.0.1',lp,'loki')]+([('127.0.0.1',12345,'alloy')] if collector else []):
  with socket.socket() as sock:
   try:sock.bind((ip,p))
   except OSError:
    inspect=subprocess.run(['docker','inspect',name],text=True,capture_output=True)
    if inspect.returncode:raise RuntimeError(f'Port {ip}:{p} is already occupied.')
    obj=json.loads(inspect.stdout)[0]
    if p!=12345 and not any(int(v['HostPort'])==p for vs in (obj['NetworkSettings'].get('Ports') or {}).values() if vs for v in vs):raise RuntimeError(f'Port {p} is not owned by the expected container.')
 password=existing.get('GRAFANA_PASSWORD')
 if password:print('Keeping existing Grafana admin secret. Existing database users/passwords are preserved.')
 else:password=ask('Grafana admin password (blank generates one)',secret=True) or secrets.token_hex(24)
 if not re.fullmatch(r'[A-Za-z0-9_.!@%+=:-]{12,}',password):raise ValueError('Use at least 12 characters, without spaces, quotes, dollar signs, or backslashes.')
 uid='loki'
 ds=folder/'grafana/provisioning/datasources/loki.yaml'
 if ds.exists():
  m=re.search(r'^\s+uid:\s*(\S+)',ds.read_text(),re.M)
  if m:uid=m.group(1)
  else:raise RuntimeError('The existing datasource has no explicit UID. Add its current UID from Grafana first to preserve existing dashboards.')
 days=int(ask('Loki retention in days','30'))
 if not 1<=days<=3650:raise ValueError('Retention must be 1..3650 days.')
 # Generate and validate in a staging directory before changing the active stack.
 folder.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='.logging-candidate-',dir=folder.parent) as tmp:
  stage=pathlib.Path(tmp)
  for name in ['grafana','loki']:
   for p in (TEMPLATES/name).rglob('*'):
    if p.is_file():
     target=stage/p.relative_to(TEMPLATES);target.parent.mkdir(parents=True,exist_ok=True)
     target.write_text(p.read_text().replace('__LOKI_UID__',uid))
  cfg=stage/'loki/config.yaml';cfg.write_text(re.sub(r'retention_period: \S+',f'retention_period: {days*24}h',cfg.read_text()))
  shutil.copy2(TEMPLATES/'docker-compose.yml',stage/'docker-compose.yml')
  env=stage/'.env'
  env.write_text(f'GRAFANA_PASSWORD={password}\nGRAFANA_BIND_IP={bind}\nGRAFANA_PORT={gp}\nLOKI_PORT={lp}\nCOMPOSE_PROFILES={"collector" if collector else ""}\n');env.chmod(0o600)
  if collector:
   (stage/'alloy').mkdir()
   config=render(host,FLEET['endpoint'],'unused',docker)
   config=config[:config.index('loki.write "home"')]+f'loki.write "home" {{\n  endpoint {{ url = "http://127.0.0.1:{lp}/loki/api/v1/push" }}\n}}\n'
   (stage/'alloy/config.alloy').write_text(config)
  run(['docker','compose','config','--quiet'],cwd=stage)
  if collector:run(['docker','run','--rm','--network','none','-v',str(stage/'alloy/config.alloy')+':/etc/alloy/config.alloy:ro','grafana/alloy:v1.21.3','validate','/etc/alloy/config.alloy'])
  run(['docker','run','--rm','--network','none','-v',str(stage/'loki/config.yaml')+':/etc/loki/config.yaml:ro','grafana/loki:3.6.2','-config.file=/etc/loki/config.yaml','-verify-config=true'])
  saved=folder/'backups'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
  if folder.exists():
   saved.mkdir(parents=True);saved.chmod(0o700)
   for name in ['docker-compose.yml','.env','grafana','loki','alloy']:
    p=folder/name
    if p.is_dir():shutil.copytree(p,saved/name)
    elif p.exists():shutil.copy2(p,saved/name)
  folder.mkdir(parents=True,exist_ok=True)
  for p in stage.rglob('*'):
   if p.is_file():
    target=folder/p.relative_to(stage);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
  try:run(['docker','compose','up','-d'],cwd=folder)
  except Exception:
   print('Stack start failed. Config backups, if this was an existing stack, are at '+str(saved))
   raise
 env=folder/'.env'
 print(f'Central stack ready at {folder}; Grafana http://{bind}:{gp}/d/fleet-logs. Admin secret is in {env} (0600).')
 print('Only install Alloy on other VPS machines. This module does not publish Loki or modify FRP.')
if __name__=='__main__':main(install)
