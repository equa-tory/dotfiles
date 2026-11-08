#!/usr/bin/env python3
"""Prompted Linux hostname change; no network/SSH service restarts."""
import argparse,datetime,difflib,ipaddress,os,pathlib,re,shutil,subprocess,sys

def validate(name):
 name=name.strip().lower()
 if not name or len(name)>64 or name in ('localhost','localhost.localdomain'):raise ValueError('Use a hostname of 1–64 characters, such as hip-fin or hip-fin.example.net.')
 if any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',part) for part in name.split('.')):raise ValueError('Use DNS labels with letters, digits, and internal hyphens; no spaces or @ sign.')
 try:ipaddress.ip_address(name)
 except ValueError:return name
 raise ValueError('Enter a hostname, not an IP address.')

def update_hosts(text,old,new):
 new_names=list(dict.fromkeys([new,new.split('.')[0]]))
 old_names=[x for x in dict.fromkeys([old,old.split('.')[0]]) if x and x not in ('localhost','localhost.localdomain','(none)')]
 lines=text.splitlines(keepends=True);matches=[]
 for i,line in enumerate(lines):
  body,_,_=line.partition('#');parts=body.split()
  if len(parts)<2:continue
  try:address=ipaddress.ip_address(parts[0])
  except ValueError:continue
  if set(parts[1:]) & set(new_names) and not address.is_loopback:raise ValueError('The requested name already maps to '+parts[0]+' in /etc/hosts. Review that mapping first.')
  if parts[0]=='127.0.1.1' and set(parts[1:]) & set(old_names+new_names):matches.append(i)
 if matches:
  i=matches[0];body,mark,comment=lines[i].partition('#');parts=body.split()
  aliases=list(dict.fromkeys(new_names+parts[1:]))
  lines[i]='127.0.1.1\t'+' '.join(aliases)+('  #'+comment.rstrip('\n') if mark else '')+'\n'
  return ''.join(lines)
 suffix='' if not text or text.endswith('\n') else '\n'
 return text+suffix+'127.0.1.1\t'+' '.join(dict.fromkeys(new_names+old_names))+'\n'

def command(args):return subprocess.run(args,check=True,text=True,capture_output=True).stdout.strip()
def hostname(kind='static'):return command(['hostnamectl','--'+kind])
def cloud_present():return pathlib.Path('/etc/cloud/cloud.cfg').exists() or shutil.which('cloud-init') is not None

def references(old):
 if len(old)<3 or old=='localhost':return []
 result=[];pattern=re.compile(r'(?<![A-Za-z0-9_.-])'+re.escape(old)+r'(?![A-Za-z0-9_.-])')
 for directory in ('/etc/caddy','/etc/nginx','/etc/apache2','/etc/postfix'):
  base=pathlib.Path(directory)
  if not base.exists():continue
  for p in base.rglob('*'):
   try:
    if p.is_file() and p.stat().st_size<=1024*1024 and pattern.search(p.read_text(errors='ignore')):result.append(str(p))
   except OSError:continue
 return result

def apply(name,preserve_cloud):
 name=validate(name)
 old_static=hostname();old_transient=hostname('transient');old_pretty=hostname('pretty')
 old=old_static or old_transient
 hosts=pathlib.Path('/etc/hosts');before=hosts.read_text();after=update_hosts(before,old,name)
 affected=references(old)
 print(f'Hostname: {old} → {name}')
 print(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='/etc/hosts (current)',tofile='/etc/hosts (proposed)')),end='')
 if affected:
  print('These application configs mention the old hostname and will need review if their service name should change:')
  for path in affected[:15]:print('  '+path)
  if input('Continue with the hostname change? [y/N]: ').strip().lower() not in ('y','yes'):
   print('Cancelled');return
 backup=pathlib.Path('/var/backups/equa-hostname')/datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
 backup.mkdir(parents=True,mode=0o700);backup.parent.chmod(0o700)
 cloud=pathlib.Path('/etc/cloud/cloud.cfg.d/99-z-equa-hostname.cfg')
 paths=[hosts,pathlib.Path('/etc/hostname')]+([cloud] if preserve_cloud else [])
 saved={}
 for p in paths:
  if p.exists():
   target=backup/p.relative_to('/');target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target);saved[p]=target
  else:saved[p]=None
 try:
  hosts.write_text(after)
  if preserve_cloud:
   cloud.parent.mkdir(parents=True,exist_ok=True)
   cloud.write_text('# Managed by dotfiles server/hostname\npreserve_hostname: true\nmanage_etc_hosts: false\n');cloud.chmod(0o644)
  command(['hostnamectl','set-hostname',name])
  if hostname()!=name:raise RuntimeError('The requested static hostname was not applied.')
 except Exception:
  for kind,old_name in [('static',old_static),('transient',old_transient),('pretty',old_pretty)]:
   subprocess.run(['hostnamectl','--'+kind,'set-hostname',old_name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  for p,saved_file in saved.items():
   if saved_file:shutil.copy2(saved_file,p)
   elif p.exists():p.unlink()
  raise
 print('Applied '+name+'. Backups: '+str(backup))
 print('Your current SSH session can stay open. Reconnect later to refresh the prompt; no reboot is required.')

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--apply');parser.add_argument('--preserve-cloud',action='store_true');args=parser.parse_args()
 if not shutil.which('hostnamectl'):raise ValueError('This module requires a Linux host with hostnamectl/systemd.')
 if args.apply:
  if os.geteuid()!=0:raise ValueError('Applying a hostname requires root privileges.')
  apply(args.apply,args.preserve_cloud);return
 current=hostname()
 print('Current full hostname: '+(current or hostname('transient')))
 print('Enter the whole new name, such as hip-fin or hip-fin.example.net; no prefix is added.')
 print('This changes the computer name. Its IP and public DNS records stay as they are.')
 name=input('New full hostname (blank cancels): ').strip()
 if not name:print('Cancelled');return
 name=validate(name)
 if name==current:print('This hostname is already set.');return
 preserve=False
 if cloud_present():
  preserve=input('Prevent cloud-init from resetting the hostname and hosts file? [Y/n]: ').strip().lower() not in ('n','no')
 cmd=[sys.executable,str(pathlib.Path(__file__).resolve()),'--apply',name]
 if preserve:cmd.append('--preserve-cloud')
 if os.geteuid()!=0:cmd=['sudo',*cmd]
 subprocess.run(cmd,check=True)

if __name__=='__main__':
 try:main()
 except (ValueError,RuntimeError,OSError,subprocess.CalledProcessError,KeyboardInterrupt,EOFError) as e:raise SystemExit(str(e) or 'Cancelled')
