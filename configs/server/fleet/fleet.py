#!/usr/bin/env python3
"""A small command line over Ansible's SSH fleet tasks; no remote API service."""
import argparse,base64,json,os,pathlib,re,shlex,subprocess,sys,tempfile,urllib.request
ROOT=pathlib.Path(__file__).resolve().parent
CONFIG=pathlib.Path(os.environ.get('EQUA_FLEET_CONFIG',str(pathlib.Path.home()/'.config/equa-fleet'))).expanduser()
STATE=pathlib.Path.home()/'.local/share/equa-fleet'

def run(args,**kw):return subprocess.run([str(x) for x in args],check=True,**kw)
def private_json(path,data):
 path.parent.mkdir(parents=True,exist_ok=True);path.parent.chmod(0o700)
 fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
 with os.fdopen(fd,'w') as f:json.dump(data,f,indent=2);f.write('\n')
 path.chmod(0o600)
def valid_user(user):
 if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}',user):raise ValueError('Invalid Linux SSH username')
 return user

def init(user,key,keys_url):
 valid_user(user);validate_url(keys_url)
 inventory=CONFIG/'inventory.json';settings=CONFIG/'settings.json'
 if inventory.exists() or settings.exists():raise ValueError('Fleet config already exists; use fleet configure, or edit the private inventory. Nothing overwritten.')
 machines=json.loads((ROOT.parent/'logging/fleet.json').read_text())['machines']
 hosts={name:{'ansible_host':ip,'ansible_user':user,'ansible_port':22,'ansible_ssh_private_key_file':str(pathlib.Path(key).expanduser()),'ansible_python_interpreter':'/usr/bin/python3'} for name,ip in machines.items()}
 private_json(inventory,{'all':{'children':{'fleet':{'hosts':hosts}}}})
 private_json(settings,{'keys_url':keys_url})
 print('Created private fleet inventory: '+str(inventory))
 print('Run fleet configure to set each VPS login, then fleet enroll all for first-time SSH access.')

def load():
 try:
  inventory=json.loads((CONFIG/'inventory.json').read_text());settings=json.loads((CONFIG/'settings.json').read_text())
 except FileNotFoundError:raise ValueError('Run fleet init first.') from None
 hosts=inventory['all']['children']['fleet']['hosts']
 for name,h in hosts.items():
  if not re.fullmatch(r'[A-Za-z0-9_.-]+',name):raise ValueError('Invalid inventory name')
  valid_user(h['ansible_user'])
  if not re.fullmatch(r'[A-Za-z0-9_.:-]+',h['ansible_host']) or h['ansible_host'].startswith('-'):raise ValueError('Invalid SSH host')
  if not 1<=int(h.get('ansible_port',22))<=65535:raise ValueError('Invalid SSH port')
 return inventory,settings,hosts

def ask(label,default):
 if not sys.stdin.isatty():raise ValueError('This command requires a terminal.')
 return input(f'{label} [{default}]: ').strip() or default

def configure():
 inventory,settings,hosts=load()
 for name,h in hosts.items():
  h['ansible_user']=valid_user(ask(name+' Linux SSH user',h['ansible_user']))
  h['ansible_port']=int(ask(name+' SSH port',h.get('ansible_port',22)))
  if not 1<=h['ansible_port']<=65535:raise ValueError('Port must be 1..65535')
  h['ansible_ssh_private_key_file']=str(pathlib.Path(ask(name+' controller private key path',h['ansible_ssh_private_key_file'])).expanduser())
 settings['keys_url']=ask('Public SSH keys HTTPS URL',settings['keys_url']);validate_url(settings['keys_url'])
 private_json(CONFIG/'inventory.json',inventory);private_json(CONFIG/'settings.json',settings)
 print('Saved. Private key contents and passwords are never written to the inventory.')

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

def enroll(name):
 inventory,settings,hosts=load()
 selected=hosts if name=='all' else {name:hosts[name]} if name in hosts else None
 if not selected:raise ValueError('Unknown host: '+name)
 for alias,h in selected.items():
  user=ask(alias+' Linux SSH login',h['ansible_user']);valid_user(user)
  if user!=h['ansible_user']:
   h['ansible_user']=user;private_json(CONFIG/'inventory.json',inventory)
  key=pathlib.Path(h['ansible_ssh_private_key_file']).expanduser();pub=pathlib.Path(str(key)+'.pub')
  if not key.exists() or not pub.exists():raise ValueError(f'Create the controller key first: ssh-keygen -t ed25519 -f {shlex.quote(str(key))}')
  validate_keys(pub.read_text())
  print(f'{alias}: verify the SSH host fingerprint, then enter that VPS login password if requested. Neither is bypassed or saved.')
  run(['ssh-copy-id','-i',pub,'-p',str(h.get('ansible_port',22)),'-o','StrictHostKeyChecking=ask',user+'@'+h['ansible_host']])
  print(alias+': controller public key enrolled; private key stayed on this controller.')

def binary(name):
 p=STATE/'venv/bin'/name
 if not p.exists():raise ValueError('Install the dotfiles server/fleet module first (Ansible controller dependencies).')
 return p

def env():
 return dict(os.environ,ANSIBLE_CONFIG=str(ROOT/'ansible.cfg'),ANSIBLE_COLLECTIONS_PATH=str(STATE/'collections'),ANSIBLE_HOST_KEY_CHECKING='True')

def playbook(action,args):
 _,settings,hosts=load()
 file=ROOT/'playbooks'/(action+'.yml')
 if not file.is_file():
  file=CONFIG/'playbooks'/(action+'.yml')
 if not re.fullmatch(r'[a-zA-Z0-9_-]+',action) or not file.is_file():raise ValueError('Unknown task. Add a trusted playbook under ~/.config/equa-fleet/playbooks/.')
 cmd=[binary('ansible-playbook'),'-i',CONFIG/'inventory.json',file]
 if args.limit:cmd+=['--limit',args.limit]
 if args.check:cmd+=['--check']
 if args.plan:cmd+=['--list-hosts']
 if args.ask_become_pass:cmd+=['--ask-become-pass']
 data={}
 if action=='keys' and not args.plan:
  data['fleet_public_keys']=fetch_keys(settings['keys_url'])
  if args.key_user:data['fleet_key_user']=valid_user(args.key_user)
  print('Downloaded and validated public SSH keys. Existing unrelated keys will be preserved.',flush=True)
 if action=='alloy-update' and args.version:data['fleet_alloy_version']=args.version
 # JSON file keeps payloads out of shell interpolation and process command lines.
 with tempfile.TemporaryDirectory(prefix='equa-fleet-') as tmp:
  if data:
   f=pathlib.Path(tmp)/'vars.json';private_json(f,data);cmd+=['--extra-vars','@'+str(f)]
  print('Task: '+action+' | targets: '+(args.limit or 'all fleet hosts')+(' | CHECK MODE' if args.check else ''),flush=True)
  run(cmd,env=env())

def main():
 p=argparse.ArgumentParser(description='Manage VPS machines over SSH from one controller; no public management API.')
 sub=p.add_subparsers(dest='command',required=True)
 q=sub.add_parser('init');q.add_argument('--user',default='equa');q.add_argument('--key',default='~/.ssh/id_ed25519');q.add_argument('--keys-url',default='https://github.com/equa-tory.keys')
 sub.add_parser('configure');sub.add_parser('list')
 q=sub.add_parser('enroll');q.add_argument('host',help='Inventory name or all; interactive first-time SSH setup')
 for command in ['status','keys','alloy-update','run']:
  q=sub.add_parser(command)
  if command=='run':q.add_argument('task')
  q.add_argument('--limit',help='Ansible inventory host/group pattern, e.g. hip-fin')
  q.add_argument('--check',action='store_true',help='Preview changes without applying them')
  q.add_argument('--plan',action='store_true',help='List matching hosts without connecting')
  q.add_argument('-K','--ask-become-pass',action='store_true',help='Prompt for sudo password; not saved')
  if command=='keys':q.add_argument('--key-user',help='Target Linux account; defaults to each SSH login')
  else:q.set_defaults(key_user=None)
  if command=='alloy-update':q.add_argument('--version',help='Optional exact APT version')
  else:q.set_defaults(version=None)
 args=p.parse_args()
 if args.command=='init':init(args.user,args.key,args.keys_url)
 elif args.command=='configure':configure()
 elif args.command=='enroll':enroll(args.host)
 elif args.command=='list':
  for name,h in load()[2].items():print(f'{name:12} {h["ansible_user"]}@{h["ansible_host"]}:{h.get("ansible_port",22)}')
 else:playbook(args.task if args.command=='run' else args.command,args)
if __name__=='__main__':
 try:main()
 except (ValueError,KeyError,OSError,subprocess.CalledProcessError,KeyboardInterrupt) as e:raise SystemExit(str(e) or 'Cancelled')
