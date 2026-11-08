"""Run on a controller: verify merging in a temporary file, never in ~/.ssh."""
import json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
STATE=pathlib.Path.home()/'.local/share/equa-fleet'
env=dict(os.environ,ANSIBLE_CONFIG=str(ROOT/'ansible.cfg'),ANSIBLE_COLLECTIONS_PATH=str(STATE/'collections'))
with tempfile.TemporaryDirectory(prefix='fleet-key-test-') as tmp:
 root=pathlib.Path(tmp)
 for name in ('existing','new'):
  subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)],check=True)
 existing=(root/'existing.pub').read_text();new=(root/'new.pub').read_text()
 target=root/'authorized_keys';target.write_text(existing);target.chmod(0o600)
 play=[dict(name='Test additive key synchronization',hosts='all',connection='local',gather_facts=False,tasks=[{'name':'Merge fixture key','ansible.posix.authorized_key':dict(user=os.environ['USER'],path=str(target),key=new,exclusive=False,manage_dir=False),'register':'merged'}])]
 p=root/'test.json';p.write_text(json.dumps(play))
 cmd=[str(STATE/'venv/bin/ansible-playbook'),'-i','localhost,',str(p)]
 subprocess.run(cmd+['--check'],check=True,env=env,stdout=subprocess.DEVNULL)
 assert target.read_text()==existing,'Check mode changed the key file'
 subprocess.run(cmd,check=True,env=env,stdout=subprocess.DEVNULL)
 content=target.read_text();assert existing.split()[1] in content and new.split()[1] in content,'Existing key was lost'
 subprocess.run(cmd,check=True,env=env,stdout=subprocess.DEVNULL)
 assert target.read_text()==content,'Repeated sync duplicated or changed keys'
 print('Key integration passed: check mode makes no changes; existing keys survive; repeat sync is idempotent.')
