#!/usr/bin/env python3
"""A small command line over Ansible's SSH fleet tasks; no remote API service."""
import argparse,base64,fnmatch,ipaddress,json,os,pathlib,re,shlex,subprocess,sys,tempfile,urllib.request
ROOT=pathlib.Path(__file__).resolve().parent
INSTALLED=(ROOT/'.fleet-installation').exists()
CONFIG=pathlib.Path(os.environ.get('EQUA_FLEET_CONFIG',str(ROOT if INSTALLED else pathlib.Path.home()/'.config/equa-fleet'))).expanduser()
STATE=ROOT if INSTALLED else pathlib.Path.home()/'.local/share/equa-fleet'

def run(args,**kw):return subprocess.run([str(x) for x in args],check=True,**kw)
def private_json(path,data):
 path.parent.mkdir(parents=True,exist_ok=True);path.parent.chmod(0o700)
 fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
 with os.fdopen(fd,'w') as f:json.dump(data,f,indent=2);f.write('\n')
 path.chmod(0o600)
def valid_user(user):
 if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}',user):raise ValueError('Invalid Linux SSH username')
 return user

def parse_servers(text,settings):
 hosts={};targets=set()
 for lineno,line in enumerate(text.splitlines(),1):
  try:
   parts=shlex.split(line,comments=True)
   if not parts:continue
   alias=parts.pop(0) if '@' not in parts[0] else None
   if not parts:raise ValueError('missing user@host')
   target=parts.pop(0)
   if target.count('@')!=1:raise ValueError('expected user@host')
   user,address=target.split('@',1);valid_user(user)
   if address.startswith('['):
    match=re.fullmatch(r'\[([^]]+)\](?::([0-9]+))?',address)
    if not match:raise ValueError('IPv6 must use [address]:port syntax')
    host=match.group(1);ipaddress.IPv6Address(host);port=int(match.group(2) or 22)
   else:
    match=re.fullmatch(r'([A-Za-z0-9][A-Za-z0-9_.-]*)(?::([0-9]+))?',address)
    if not match:raise ValueError('invalid host or port')
    host=match.group(1);port=int(match.group(2) or 22)
    if re.fullmatch(r'[0-9.]+',host):ipaddress.IPv4Address(host)
   if not 1<=port<=65535:raise ValueError('port must be 1..65535')
   alias=alias or host.replace('.','-').replace(':','-')
   if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*',alias):raise ValueError('invalid optional name')
   key=settings.get('ssh_key','~/.ssh/id_ed25519')
   if parts:
    if len(parts)!=1 or not parts[0].startswith('key='):raise ValueError('only an optional key=/path is supported after user@host')
    key=parts[0][4:]
   if not key or key.startswith('-'):raise ValueError('invalid private key path')
   if alias in hosts or (user,host,port) in targets:raise ValueError('duplicate name or server')
   targets.add((user,host,port))
   hosts[alias]={'ansible_host':host,'ansible_user':user,'ansible_port':port,'ansible_ssh_private_key_file':str(pathlib.Path(key).expanduser()),'ansible_python_interpreter':'/usr/bin/python3'}
  except ValueError as e:raise ValueError(f'servers.txt line {lineno}: {e}') from None
 return hosts

def init(user,key,keys_url,import_inventory=None):
 valid_user(user);validate_url(keys_url)
 if (CONFIG/'servers.txt').exists() or (CONFIG/'settings.json').exists():raise ValueError('Fleet settings already exist; edit servers.txt. Nothing overwritten.')
 settings={'keys_url':keys_url,'ssh_key':str(pathlib.Path(key).expanduser())}
 lines=['# One server per line: [optional-name] user@host[:port] [key=/private/key/path]', '# Edit this file, then run ./fleet sync. Blank lines and # comments are allowed.']
 if import_inventory:
  old=json.loads(pathlib.Path(import_inventory).expanduser().read_text())['all']['children']['fleet']['hosts']
  for name,h in old.items():
   host=h['ansible_host'];port=int(h.get('ansible_port',22))
   target=h['ansible_user']+'@'+('['+host+']' if ':' in host else host)+((':'+str(port)) if port!=22 else '')
   entry=name+' '+target
   if h.get('ansible_ssh_private_key_file',settings['ssh_key'])!=settings['ssh_key']:entry+=' '+shlex.quote('key='+h['ansible_ssh_private_key_file'])
   lines.append(entry)
 else:lines+=['# '+user+'@203.0.113.10','# example '+user+'@server.example.com:2222']
 text='\n'.join(lines)+'\n';parse_servers(text,settings)
 private_json(CONFIG/'settings.json',settings)
 (CONFIG/'servers.txt').write_text(text);(CONFIG/'servers.txt').chmod(0o600)
 load()
 print('Edit '+str(CONFIG/'servers.txt')+', then run fleet sync.')

def load():
 try:
  settings=json.loads((CONFIG/'settings.json').read_text())
  text=(CONFIG/'servers.txt').read_text()
 except FileNotFoundError:raise ValueError('Run fleet init first (or reinstall the server/fleet module to migrate old settings).') from None
 validate_url(settings['keys_url'])
 hosts=parse_servers(text,settings)
 inventory={'all':{'children':{'fleet':{'hosts':hosts}}}}
 private_json(CONFIG/'.state/inventory.json',inventory)
 return inventory,settings,hosts

def ask(label,default):
 if not sys.stdin.isatty():raise ValueError('This command requires a terminal.')
 return input(f'{label} [{default}]: ').strip() or default

def configure():
 _,settings,_=load()
 settings['ssh_key']=str(pathlib.Path(ask('Controller SSH private key path',settings.get('ssh_key','~/.ssh/id_ed25519'))).expanduser())
 settings['keys_url']=ask('Public SSH keys HTTPS URL',settings['keys_url']);validate_url(settings['keys_url'])
 private_json(CONFIG/'settings.json',settings)
 print('Saved defaults. Edit '+str(CONFIG/'servers.txt')+' for Linux users, addresses, ports, and optional per-host keys.')

def validate_url(url):
 from urllib.parse import urlsplit
 u=urlsplit(url)
 if u.scheme!='https' or not u.hostname or u.username or u.password:raise ValueError('Key source must be HTTPS without embedded credentials')

def validate_keys(body):
 keys=[]
 for line in body.splitlines():
  line=line.strip()
  if not line or line.startswith('#'):continue
  fields=line.split()
  if len(fields)<2 or not re.fullmatch(r'ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com',fields[0]):raise ValueError('Key source contains an unexpected line; no keys applied.')
  try:base64.b64decode(fields[1],validate=True)
  except Exception:raise ValueError('Invalid public-key encoding; no keys applied.') from None
  with tempfile.NamedTemporaryFile(mode='w',suffix='.pub') as f:
   f.write(line+'\n');f.flush()
   p=subprocess.run(['ssh-keygen','-l','-f',f.name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   if p.returncode:raise ValueError('Invalid public key; no keys applied.')
  if ' '.join(fields[:2]) not in {' '.join(k.split()[:2]) for k in keys}:keys.append(line)
 if not keys:raise ValueError('No public keys were found; no keys applied.')
 return '\n'.join(keys)+'\n'

def fetch_keys(url):
 validate_url(url)
 with urllib.request.urlopen(url,timeout=30) as response:
  validate_url(response.geturl());body=response.read(1024*1024+1)
 if len(body)>1024*1024:raise ValueError('Key source is unexpectedly large')
 return validate_keys(body.decode('utf-8'))

def selected_hosts(hosts,pattern):
 if not pattern or pattern=='all':return hosts
 selected={name:h for name,h in hosts.items() if any(fnmatch.fnmatchcase(name,part) for part in pattern.split(','))}
 if not selected:raise ValueError('No servers match '+pattern)
 return selected

def ensure_key(key):
 key=pathlib.Path(key).expanduser();pub=pathlib.Path(str(key)+'.pub')
 if not key.exists():
  if not sys.stdin.isatty():raise ValueError('No controller key: run fleet sync in a terminal to create one.')
  key.parent.mkdir(parents=True,exist_ok=True);key.parent.chmod(0o700)
  run(['ssh-keygen','-t','ed25519','-f',key,'-C','fleet controller'])
 if not pub.exists():
  result=run(['ssh-keygen','-y','-f',key],capture_output=True,text=True)
  pub.write_text(result.stdout);pub.chmod(0o644)
 validate_keys(pub.read_text())
 return key,pub

def enroll(name,plan=False):
 _,_,hosts=load();selected=selected_hosts(hosts,name)
 if not selected:raise ValueError('Add servers to '+str(CONFIG/'servers.txt')+' first.')
 ready=[];failed=[]
 for alias,h in selected.items():
  dest=h['ansible_user']+'@'+h['ansible_host'];port=str(h['ansible_port'])
  if plan:
   print(f'{alias}: check SSH access and enroll controller key for {dest}:{port} if needed.');continue
  try:
   key,pub=ensure_key(h['ansible_ssh_private_key_file'])
   args=['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','ConnectTimeout=8','-i',key,'-p',port,dest,'true']
   probe=subprocess.run([str(x) for x in args],capture_output=True,text=True)
   if probe.returncode:
    if not sys.stdin.isatty():
     print(alias+': needs initial SSH setup; run fleet sync in a terminal. '+probe.stderr.strip(),file=sys.stderr);failed.append(alias);continue
    print(f'{alias}: enrolling {dest}. Verify its host fingerprint and enter its existing login password if requested.',flush=True)
    run(['ssh-copy-id','-i',pub,'-p',port,'-o','StrictHostKeyChecking=ask',dest])
    run(args)
   print(alias+': SSH ready.',flush=True);ready.append(alias)
  except (ValueError,OSError,subprocess.CalledProcessError) as e:
   print(alias+': '+str(e),file=sys.stderr);failed.append(alias)
 return ready,failed

def sync(args):
 hooks=[j for j in discover_jobs().values() if j['on-sync']]
 if args.plan:
  enroll(args.host,True)
  for job in hooks:print('After enrollment: '+job['name']+' — '+job['description'])
  return
 ready,failed=enroll(args.host)
 if ready and not args.enroll_only:
  task_args=argparse.Namespace(limit=','.join(ready),check=False,plan=False,ask_become_pass=False,variables=[])
  for job in hooks:execute_job(job,task_args)
 if failed:raise ValueError('Some servers need attention: '+', '.join(failed)+'. Fix their entries/access and rerun fleet sync; ready servers are safe to repeat.')

def binary(name):
 p=STATE/'venv/bin'/name
 if not p.exists():raise ValueError('Install the dotfiles server/fleet module first (Ansible controller dependencies).')
 return p

def env():
 return dict(os.environ,ANSIBLE_CONFIG=str(ROOT/'ansible.cfg'),ANSIBLE_COLLECTIONS_PATH=str(STATE/'collections'),ANSIBLE_HOST_KEY_CHECKING='True')

def discover_jobs():
 jobs={}
 base=ROOT/'jobs'
 for folder in sorted({p.parent for pattern in ('run.sh','run.py','run.yml') for p in base.rglob(pattern)}):
  entries=[p for p in (folder/'run.sh',folder/'run.py',folder/'run.yml') if p.is_file()]
  if len(entries)!=1:raise ValueError('Use exactly one run.sh, run.py, or run.yml in '+str(folder))
  entry=entries[0];name=folder.relative_to(base).as_posix()
  if not all(re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_-]*',x) for x in name.split('/')):raise ValueError('Invalid job directory name: '+name)
  meta={}
  for line in entry.read_text().splitlines()[:30]:
   if not line.strip():continue
   if not line.startswith('#'):break
   match=re.match(r'# ([a-z-]+):\s*(.*)',line)
   if match:meta[match.group(1)]=match.group(2).strip()
  job={'name':name,'entry':entry,'description':meta.get('description',name),'runner':meta.get('runner',{'sh':'remote','py':'controller','yml':'ansible'}[entry.suffix[1:]]),'aliases':meta.get('aliases','').split(),'options':{}}
  for key,default in [('sudo',False),('changes',True),('on-sync',False),('check',False)]:
   value=meta.get(key,str(default).lower())
   if value not in ('true','false'):raise ValueError(name+': '+key+' must be true or false')
   job[key]=value=='true'
  job['serial']=int(meta.get('serial','1'))
  if not 1<=job['serial']<=100:raise ValueError(name+': serial must be 1..100')
  if job['runner'] not in ('remote','controller','ansible'):raise ValueError('Unknown runner in '+name)
  if job['runner']=='controller' and job['sudo']:raise ValueError(name+': sudo applies to remote jobs only')
  if not entry.resolve().is_relative_to(base.resolve()):raise ValueError('Job entry must stay inside the jobs directory')
  for option in meta.get('options','').split():
   flag,variable=option.split('=',1)
   if not re.fullmatch(r'[a-z][a-z-]*',flag) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',variable):raise ValueError('Invalid job option in '+name)
   if flag in ('limit','check','plan','set','ask-become-pass','help'):raise ValueError('Reserved job option: '+flag)
   job['options'][flag]=variable
  jobs[name]=job
 # Existing custom playbooks remain runnable during migration.
 for entry in sorted((ROOT/'playbooks').glob('*.yml')):
  name=entry.stem
  if name in jobs or any(name in j['aliases'] for j in jobs.values()):continue
  jobs[name]={'name':name,'entry':entry,'description':'Legacy custom playbook','runner':'ansible','aliases':[],'options':{},'on-sync':False,'sudo':False,'changes':True,'serial':1,'check':False}
 used={'init','configure','list','enroll','sync','jobs','run'}
 for job in jobs.values():
  for name in [job['name'],*job['aliases']]:
   if not re.fullmatch(r'[A-Za-z0-9_/-]+',name) or name in used:raise ValueError('Duplicate or reserved job name: '+name)
   used.add(name)
 return jobs

def job_variables(args,job):
 values={}
 for item in getattr(args,'variables',[]) or []:
  if '=' not in item:raise ValueError('Use --set NAME=VALUE')
  name,value=item.split('=',1)
  if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',name) or name.startswith('fleet_job_'):raise ValueError('Invalid or reserved job variable: '+name)
  try:values[name]=json.loads(value)
  except json.JSONDecodeError:values[name]=value
 for flag,variable in job['options'].items():
  value=getattr(args,flag.replace('-','_'),None)
  if value is not None:values[variable]=value
 return values

def run_ansible(file,args,variables=None):
 _,_,hosts=load()
 if not hosts:raise ValueError('Add user@host entries to '+str(CONFIG/'servers.txt')+' first.')
 cmd=[binary('ansible-playbook'),'-i',CONFIG/'.state/inventory.json',file]
 if args.limit:cmd+=['--limit',args.limit]
 if args.check:cmd+=['--check']
 if args.plan:cmd+=['--list-hosts']
 if args.ask_become_pass:cmd+=['--ask-become-pass']
 with tempfile.TemporaryDirectory(prefix='equa-fleet-') as tmp:
  if variables:
   f=pathlib.Path(tmp)/'vars.json';private_json(f,variables);cmd+=['--extra-vars','@'+str(f)]
  run(cmd,env=env())

def execute_job(job,args):
 _,settings,hosts=load()
 if not hosts:raise ValueError('Add servers to servers.txt first.')
 values=job_variables(args,job)
 print('Job: '+job['name']+' | targets: '+(args.limit or 'all fleet hosts')+(' | CHECK MODE' if args.check else ''),flush=True)
 if job['runner']=='ansible':return run_ansible(job['entry'],args,values)
 if job['runner']=='remote':
  values.update(fleet_job_name=job['name'],fleet_job_script=str(job['entry']),fleet_job_sudo=job['sudo'],fleet_job_serial=job['serial'],fleet_job_changes=job['changes'],fleet_job_environment={'FLEET_JOB_NAME':job['name'],'FLEET_VARS_JSON':json.dumps(values)})
  return run_ansible(ROOT/'engine/remote-script.yml',args,values)
 if args.plan:
  print('Controller entry: '+str(job['entry'])+' (not executed in plan mode)')
  return run_ansible(ROOT/'engine/remote-script.yml',args,{'fleet_job_serial':1,'fleet_job_sudo':False})
 if args.check and not job['check']:
  print('Controller script skipped: this job does not declare # check: true.');return
 with tempfile.TemporaryDirectory(prefix='fleet-job-') as tmp:
  context=pathlib.Path(tmp)/'context.json'
  private_json(context,{'settings':settings,'args':vars(args),'variables':values,'inventory':str(CONFIG/'.state/inventory.json')})
  executable=binary('python') if job['entry'].suffix=='.py' else 'bash'
  run([executable,job['entry']],env=dict(env(),FLEET_HOME=str(ROOT),FLEET_JOB_DIR=str(job['entry'].parent),FLEET_JOB_CONTEXT=str(context)),cwd=job['entry'].parent)

def main():
 p=argparse.ArgumentParser(description='Manage VPS machines over SSH from one controller; no public management API.')
 sub=p.add_subparsers(dest='command',required=True)
 q=sub.add_parser('init');q.add_argument('--user',default='equa');q.add_argument('--key',default='~/.ssh/id_ed25519');q.add_argument('--keys-url',default='https://github.com/equa-tory.keys');q.add_argument('--import-inventory',help='Migrate an existing private Ansible JSON inventory once')
 sub.add_parser('configure');sub.add_parser('list')
 for command in ['enroll','sync']:
  q=sub.add_parser(command);q.add_argument('host',nargs='?',default='all',help='Optional name, glob, or comma-separated names; default all')
  q.add_argument('--plan',action='store_true',help='Show enrollment targets without connecting or changing SSH access')
  q.add_argument('--enroll-only',action='store_true',help='Only enroll the controller key; skip GitHub key synchronization')
 jobs=discover_jobs();lookup={}
 sub.add_parser('jobs',help='List jobs discovered from directories')
 def options(parser,job=None):
  parser.add_argument('--limit',help='Target name or Ansible inventory pattern')
  parser.add_argument('--check',action='store_true',help='Preview; remote shell scripts are skipped')
  parser.add_argument('--plan',action='store_true',help='List targets without connecting')
  parser.add_argument('-K','--ask-become-pass',action='store_true')
  parser.add_argument('--set',dest='variables',action='append',default=[],metavar='NAME=VALUE')
  if job:
   for flag in job['options']:parser.add_argument('--'+flag)
 for job in jobs.values():
  for name in [job['name'],*job['aliases']]:
   lookup[name]=job
   options(sub.add_parser(name,help=job['description']),job)
 q=sub.add_parser('run',help='Run a discovered job');q.add_argument('task');options(q)
 args=p.parse_args()
 if args.command=='init':init(args.user,args.key,args.keys_url,args.import_inventory)
 elif args.command=='configure':configure()
 elif args.command in ('enroll','sync'):
  if args.command=='enroll':args.enroll_only=True
  sync(args)
 elif args.command=='list':
  hosts=load()[2]
  if not hosts:print('No servers yet. Edit '+str(CONFIG/'servers.txt')+', then run fleet sync.')
  for name,h in hosts.items():print(f'{name:12} {h["ansible_user"]}@{h["ansible_host"]}:{h.get("ansible_port",22)}')
 elif args.command=='jobs':
  for job in jobs.values():print(f"{job['name']:24} {job['runner']:10} {job['description']}"+(' [on sync]' if job['on-sync'] else ''))
 else:
  name=args.task if args.command=='run' else args.command
  if name not in lookup:raise ValueError('Unknown job: '+name+'. Add jobs/<name>/run.sh or run.yml, then retry.')
  execute_job(lookup[name],args)
if __name__=='__main__':
 try:main()
 except (ValueError,KeyError,OSError,subprocess.CalledProcessError,KeyboardInterrupt) as e:raise SystemExit(str(e) or 'Cancelled')
