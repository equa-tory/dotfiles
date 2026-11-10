"""Separate forwarding-only SSH transport for metrics; never touches FRP."""
from common import *
import pwd,secrets,socket,time
def forwarding_account(user,public_key,listen_port):
 if os.geteuid()!=0:raise RuntimeError('Forwarding account setup requires root')
 if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,30}',user):raise ValueError('Invalid dedicated SSH account')
 listen_port=port(listen_port)
 if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]+)?',public_key):raise ValueError('Supply one Ed25519 public key')
 try:
  account=pwd.getpwnam(user)
  if account.pw_shell not in ('/usr/sbin/nologin','/sbin/nologin','/bin/false'):raise ValueError('Use a dedicated forwarding-only account, not an existing login user.')
 except KeyError:
  run(['useradd','--create-home','--shell','/usr/sbin/nologin',user]);account=pwd.getpwnam(user)
 # A locked account is rejected by some sshd configurations even for keys.
 # Assign an unknown random password hash; SSH password login stays explicitly disabled.
 hashed=run(['openssl','passwd','-6','-stdin'],input=secrets.token_urlsafe(48),capture_output=True).stdout.strip()
 run(['usermod','-p',hashed,user])
 directory=pathlib.Path(account.pw_dir)/'.ssh';directory.mkdir(exist_ok=True,mode=0o700)
 key=directory/'authorized_keys';saved_key=backup(key)
 key.write_text('restrict,port-forwarding,permitlisten="127.0.0.1:'+str(listen_port)+'" '+public_key+'\n');key.chmod(0o600)
 for path in (directory,key):os.chown(path,account.pw_uid,account.pw_gid)
 config='/etc/ssh/sshd_config.d/60-fleet-metrics.conf';saved=backup(config)
 text=f'Match User {user}\n    AllowTcpForwarding remote\n    PermitListen 127.0.0.1:{listen_port}\n    PermitOpen none\n    GatewayPorts no\n    MaxSessions 0\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\nMatch all\n'
 try:
  write_root(config,text,save=False);run(['/usr/sbin/sshd','-t'])
  service='ssh' if subprocess.run(['systemctl','is-active','--quiet','ssh']).returncode==0 else 'sshd'
  run(['systemctl','reload',service])
 except Exception:
  if saved_key:shutil.copy2(saved_key,key)
  else:key.unlink(missing_ok=True)
  if saved:shutil.copy2(saved,config)
  else:pathlib.Path(config).unlink(missing_ok=True)
  raise
 write_root('/etc/equa-logging/metrics-forwarding.json',json.dumps(dict(user=user,public_key=public_key,port=listen_port),indent=2),mode='0600')
def install_gateway():
 state_path='/etc/equa-logging/metrics-forwarding.json'
 state=json.loads(read_root(state_path)) if exists_root(state_path) else {}
 user=ask('Dedicated forwarding-only SSH account',state.get('user','fleet-metrics'))
 listen_port=port(ask('Gateway loopback listening port',state.get('port',19090)))
 public_key=ask('Home metrics tunnel Ed25519 PUBLIC key',state.get('public_key'))
 with tempfile.TemporaryDirectory() as tmp:
  for name in ['common.py','tunnel.py','fleet.json']:shutil.copy2(ROOT/name,pathlib.Path(tmp)/name)
  sudo(['python3','-B','-c','import sys;sys.path.insert(0,sys.argv[1]);import tunnel;tunnel.forwarding_account(sys.argv[2],sys.argv[3],int(sys.argv[4]))',tmp,user,public_key,str(listen_port)])
def home_unit(local_user,gateway,ssh_user,key,ssh_port,listen_port,local_port):
 if not re.fullmatch(r'[a-z_][a-z0-9_-]*',local_user) or not re.fullmatch(r'[a-z_][a-z0-9_-]*',ssh_user):raise ValueError('Invalid user')
 if not re.fullmatch(r'[a-zA-Z0-9.:-]+',gateway):raise ValueError('Invalid SSH gateway')
 key=pathlib.Path(key).expanduser().resolve()
 if any(c in str(key) for c in '\n\r"'):raise ValueError('Invalid key path')
 return f'''[Unit]
Description=Private metrics reverse tunnel to logging gateway
After=network-online.target
Wants=network-online.target
[Service]
User={local_user}
ExecStart=/usr/bin/ssh -F /dev/null -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes -i "{str(key).replace('%','%%')}" -p {port(ssh_port)} -R 127.0.0.1:{port(listen_port)}:127.0.0.1:{port(local_port)} {ssh_user}@{gateway}
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
'''
def install_home(local_port=9090):
 state_path='/etc/equa-logging/metrics-tunnel.json'
 state=json.loads(read_root(state_path)) if exists_root(state_path) else {}
 local_user=ask('Local user running the tunnel',state.get('local_user',getpass.getuser()))
 account=pwd.getpwnam(local_user)
 gateway=ask('Gateway SSH hostname or address',state.get('gateway'))
 ssh_user=ask('Gateway forwarding-only account',state.get('ssh_user','fleet-metrics'))
 ssh_port=port(ask('Gateway SSH port',state.get('ssh_port',22)))
 listen_port=port(ask('Gateway metrics loopback port',state.get('listen_port',19090)))
 key=pathlib.Path(ask('Dedicated metrics private key path',state.get('key',account.pw_dir+'/.ssh/fleet_metrics_ed25519'))).expanduser()
 if os.geteuid()!=0 and local_user!=getpass.getuser():raise ValueError('Run as the tunnel user or root to create its key.')
 if not key.exists():
  parent_existed=key.parent.exists()
  key.parent.mkdir(parents=True,exist_ok=True)
  run(['ssh-keygen','-q','-t','ed25519','-N','','-C','fleet-metrics-forward-only','-f',key])
  if os.geteuid()==0:
   for path in [key,key.with_suffix('.pub')]+([] if parent_existed else [key.parent]):os.chown(path,account.pw_uid,account.pw_gid)
  print('Install this PUBLIC key using the gateway logging module:\n'+key.with_suffix('.pub').read_text())
 unit=home_unit(local_user,gateway,ssh_user,key,ssh_port,listen_port,local_port)
 print('The gateway must already trust this key and its SSH host key must be verified in the tunnel user known_hosts.')
 write_root('/etc/systemd/system/fleet-metrics-tunnel.service',unit)
 sudo(['systemctl','daemon-reload']);sudo(['systemctl','enable','fleet-metrics-tunnel']);sudo(['systemctl','restart','fleet-metrics-tunnel'])
 time.sleep(2);sudo(['systemctl','is-active','--quiet','fleet-metrics-tunnel'])
 write_root(state_path,json.dumps(dict(local_user=local_user,gateway=gateway,ssh_user=ssh_user,ssh_port=ssh_port,listen_port=listen_port,key=str(key),local_port=local_port),indent=2),mode='0600')
