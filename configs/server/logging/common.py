import datetime,getpass,ipaddress,json,os,pathlib,re,shutil,subprocess,tempfile,urllib.parse
ROOT=pathlib.Path(__file__).resolve().parent
FLEET=json.loads((ROOT/'fleet.json').read_text())
def ask(label,default=None,secret=False):
 suffix=f' [{default}]' if default is not None else ''
 if not os.isatty(0):raise RuntimeError('This installer needs a terminal for its prompts.')
 value=(getpass.getpass if secret else input)(label+suffix+': ').strip()
 return value or default or ''
def yes(label,default=False):return ask(label+' (yes/no)','yes' if default else 'no').lower() in ('y','yes')
def run(args,**kw):return subprocess.run([str(a) for a in args],check=True,text=True,**kw)
def sudo(args,**kw):return run(([] if os.geteuid()==0 else ['sudo'])+list(args),**kw)
def read_root(path):return sudo(['cat',path],capture_output=True).stdout
def exists_root(path):return subprocess.run(([] if os.geteuid()==0 else ['sudo'])+['test','-e',str(path)]).returncode==0
def backup(path):
 if exists_root(path):
  dest='/var/backups/equa-logging/'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')+str(path)
  sudo(['mkdir','-p',str(pathlib.Path(dest).parent)])
  sudo(['chmod','0700','/var/backups/equa-logging'])
  sudo(['cp','-a',str(path),dest])
  return dest
 return None
def write_root(path,text,mode='0644',group='root',save=True):
 if save:backup(path)
 sudo(['install','-d','-m','0755',str(pathlib.Path(path).parent)])
 with tempfile.TemporaryDirectory() as tmp:
  source=pathlib.Path(tmp)/'content';source.write_text(text);source.chmod(0o600)
  sudo(['install','-o','root','-g',group,'-m',mode,source,path])
def validate_host(name):
 if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}',name):raise ValueError('Use a short hostname containing letters, numbers, dots, dashes, or underscores.')
 return name
def endpoint(value):
 u=urllib.parse.urlsplit(value)
 if u.scheme!='https' or not u.hostname or u.username or u.password or u.path!='/loki/api/v1/push' or u.query or u.fragment:raise ValueError('Use an HTTPS URL ending in /loki/api/v1/push, without embedded credentials.')
 return value
def port(value):
 n=int(value)
 if not 1<=n<=65535:raise ValueError('Port must be 1..65535')
 return n
def main(fn):
 try:fn()
 except (RuntimeError,ValueError,subprocess.CalledProcessError,KeyboardInterrupt,EOFError) as e:raise SystemExit(str(e) or 'Cancelled')
