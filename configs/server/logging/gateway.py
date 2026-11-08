from common import *
import secrets
START='# BEGIN equa Loki gateway'
END='# END equa Loki gateway'

def site(value):
 if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.-]*(?::[0-9]+)?',value):raise ValueError('Use a DNS name, optionally followed by :port.')
 if ':' in value:port(value.rsplit(':',1)[1])
 return value

def render(address,upstream,ips,users,auth_directive='basicauth'):
 site(address)
 u=urllib.parse.urlsplit('http://'+upstream)
 if u.hostname not in ('localhost','127.0.0.1','::1') or u.path or not u.port:raise ValueError('Loki upstream must be a loopback host:port.')
 ips=list(dict.fromkeys(['127.0.0.1','::1']+[str(ipaddress.ip_network(ip,strict=False)) for ip in ips]))
 if not users:raise ValueError('At least one agent credential is required.')
 for name,hashed in users.items():
  if not re.fullmatch(r'[A-Za-z0-9_.-]+',name) or not re.fullmatch(r'\$2[aby]\$\d\d\$[./A-Za-z0-9]+',hashed):raise ValueError('Invalid Caddy username or bcrypt hash')
 credentials='\n'.join('        '+name+' '+hashed for name,hashed in sorted(users.items()))
 return f'''# Managed by dotfiles server/loki-caddy. Passwords are stored separately.
{address} {{
  @push path /loki/api/v1/push
  handle @push {{
    route {{
      @outside not remote_ip {' '.join(ips)}
      respond @outside "Source IP is not allowed" 403
      @wrong_method not method POST
      respond @wrong_method 405
      {auth_directive} {{
{credentials}
      }}
      reverse_proxy {upstream}
    }}
  }}
  handle {{
    respond 404
  }}
}}
'''

def install():
 if not shutil.which('caddy'):raise RuntimeError('Install Caddy first. This module preserves the existing Caddy sites.')
 address=site(ask('Loki HTTPS site','equatory.ddns.net:3443'))
 upstream=ask('Existing local Loki backend','127.0.0.1:3100')
 ips=ask('Allowed VPS source IPs (space-separated)',' '.join(FLEET['machines'].values())).split()
 config_path='/etc/equa-logging/gateway.json'
 state=json.loads(read_root(config_path)) if exists_root(config_path) else {'users':{}}
 users=state.get('users',{})
 directory=pathlib.Path(ask('Private directory for generated agent credentials',str(pathlib.Path.home()/'.local/share/equa-logging/credentials'))).expanduser().resolve()
 if directory.is_relative_to(ROOT.parents[2]):raise ValueError('Store credentials outside the dotfiles repository.')
 directory.mkdir(parents=True,exist_ok=True);directory.chmod(0o700)
 for name in FLEET['machines']:
  if name in users:
   print(name+': existing password retained');continue
  password=secrets.token_urlsafe(36)
  hashed=run(['caddy','hash-password','--plaintext',password],capture_output=True).stdout.strip()
  users[name]=hashed
  data={'host':name,'endpoint':'https://'+address+'/loki/api/v1/push','username':name,'password':password}
  target=directory/(name+'.json')
  with open(target,'x',opener=lambda p,f:os.open(p,f,0o600)) as out:json.dump(data,out,indent=2)
 version=run(['caddy','version'],capture_output=True).stdout
 match=re.search(r'v?(\d+)\.(\d+)',version)
 auth='basic_auth' if match and tuple(map(int,match.groups()))>=(2,8) else 'basicauth'
 generated=render(address,upstream,ips,users,auth)
 mainfile='/etc/caddy/Caddyfile';include='/etc/caddy/equa-logging.caddy'
 current=read_root(mainfile)
 if re.search(r'^\s*'+re.escape(address)+r'\s*\{',current,re.M):raise RuntimeError('This site already exists directly in the Caddyfile. Move it to the managed include before running this installer; other sites will not be overwritten.')
 line='import '+include
 proposed=current if line in current.splitlines() else current.rstrip()+'\n\n'+START+'\n'+line+'\n'+END+'\n'
 old={p:backup(p) for p in [mainfile,include,config_path]}
 try:
  write_root(include,generated,save=False)
  write_root(mainfile,proposed,save=False)
  sudo(['caddy','validate','--config',mainfile])
  sudo(['systemctl','reload','caddy'])
  write_root(config_path,json.dumps({'site':address,'upstream':upstream,'ips':ips,'users':users},indent=2),mode='0600',save=False)
 except Exception:
  for p,b in old.items():
   if b:sudo(['cp','-a',b,p])
   else:sudo(['rm','-f',p])
  raise
 print('Caddy gateway configured. Allow inbound TCP '+str(urllib.parse.urlsplit('https://'+address).port or 443)+' in your existing firewall if needed.')
 print('Agent credentials: '+str(directory)+' (private files; not committed). No FRP settings were changed.')
 print('Only allowlisted IPs WITH a valid password can POST logs. Query and admin paths return 404.')
if __name__=='__main__':main(install)
