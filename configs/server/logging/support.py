"""Host support units. Called by installers after configuration validation."""
import json,os,pathlib,shutil,subprocess,time
ROOT=pathlib.Path(__file__).resolve().parent
def run(args):subprocess.run(args,check=True)
def backup(paths):
 root=pathlib.Path('/var/backups/equa-logging')/('monitoring-'+str(time.time_ns()));root.mkdir(parents=True,mode=0o700);root.parent.chmod(0o700)
 for path in paths:
  p=pathlib.Path(path)
  if p.exists():
   dest=root/str(p).lstrip('/');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
 return root
def units(gpu=False):
 files={'/usr/local/libexec/fleet-collector':(ROOT/'collector_helper.py').read_text()}
 for action in ['heartbeat','accounts']+(['gpu'] if gpu else []):
  files['/etc/systemd/system/fleet-'+action+'.service']='[Unit]\nDescription=Fleet '+action+' collector\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /usr/local/libexec/fleet-collector '+action+'\n'
  files['/etc/systemd/system/fleet-'+action+'.timer']='[Unit]\nDescription=Fleet '+action+' schedule\n[Timer]\nOnBootSec=15s\nOnUnitActiveSec='+('30s' if action=='gpu' else '60s')+'\nAccuracySec=1s\n[Install]\nWantedBy=timers.target\n'
 return files
def install_support(gpu=False):
 files=units(gpu);backup(files)
 for name,text in files.items():
  p=pathlib.Path(name);p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);p.chmod(0o755 if name.endswith('fleet-collector') else 0o644)
 for name in ['/var/lib/fleet-monitoring','/var/lib/fleet-monitoring/textfile']:pathlib.Path(name).mkdir(parents=True,exist_ok=True,mode=0o755)
 if not gpu and pathlib.Path('/etc/systemd/system/fleet-gpu.timer').exists():
  run(['systemctl','disable','--now','fleet-gpu.timer']);run(['systemctl','stop','fleet-gpu.service'])
  pathlib.Path('/var/lib/fleet-monitoring/textfile/gpu.prom').unlink(missing_ok=True)
 run(['systemctl','daemon-reload'])
 for action in ['heartbeat','accounts']+(['gpu'] if gpu else []):
  run(['systemctl','start','fleet-'+action+'.service']);run(['systemctl','enable','--now','fleet-'+action+'.timer'])
