import importlib.util,pathlib,tempfile,unittest,subprocess,json,argparse
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('fleet',ROOT/'fleet.py');fleet=importlib.util.module_from_spec(spec);spec.loader.exec_module(fleet)
class FleetTests(unittest.TestCase):
 def test_parse_simple_named_ipv6_ports_and_keys(self):
  h=fleet.parse_servers('root@31.76.226.149\nhip-fin root@193.32.179.127:2222 key=/tmp/other\nv6 user@[2001:db8::1]:2200 # hi\n',{})
  self.assertEqual(h['31-76-226-149']['ansible_user'],'root')
  self.assertEqual(h['hip-fin']['ansible_port'],2222)
  self.assertEqual(h['hip-fin']['ansible_ssh_private_key_file'],'/tmp/other')
  self.assertEqual(h['v6']['ansible_host'],'2001:db8::1')
 def test_bad_lines_fail_before_action(self):
  for text in ['root;whoami@host','root@-host','root@31.76.226.999','a root@host\na root@other','a root@host\nb root@host','root@host:99999','root@host password=secret']:
   with self.subTest(text=text),self.assertRaises(ValueError):fleet.parse_servers(text,{})
 def test_file_edits_immediately_drive_inventory(self):
  with tempfile.TemporaryDirectory() as tmp,patch.object(fleet,'CONFIG',pathlib.Path(tmp)):
   fleet.init('equa','~/.ssh/example','https://github.com/equa-tory.keys')
   p=fleet.CONFIG/'servers.txt';p.write_text('nuxt root@31.76.226.149\n')
   self.assertEqual(fleet.load()[2]['nuxt']['ansible_host'],'31.76.226.149')
   p.write_text('nuxt root@31.76.226.150\nother user@server.example.com\n')
   self.assertEqual(fleet.load()[2]['nuxt']['ansible_host'],'31.76.226.150')
   self.assertEqual(len(fleet.load()[2]),2)
   self.assertEqual((fleet.CONFIG/'.state/inventory.json').stat().st_mode & 0o777,0o600)
   with self.assertRaises(ValueError):fleet.init('root','~/.ssh/example','https://github.com/equa-tory.keys')
 def test_migrate_preserves_accounts_ports_and_keys(self):
  with tempfile.TemporaryDirectory() as tmp,patch.object(fleet,'CONFIG',pathlib.Path(tmp)/'new'):
   old=pathlib.Path(tmp)/'old.json';old.write_text(json.dumps({'all':{'children':{'fleet':{'hosts':{'fin':{'ansible_user':'root','ansible_host':'193.32.179.127','ansible_port':2222,'ansible_ssh_private_key_file':'/tmp/custom'}}}}}}))
   fleet.init('equa','~/.ssh/example','https://github.com/equa-tory.keys',old)
   self.assertEqual(fleet.load()[2]['fin']['ansible_ssh_private_key_file'],'/tmp/custom')
   self.assertEqual(fleet.load()[2]['fin']['ansible_port'],2222)
 def test_repeated_enrollment_skips_password_and_copy(self):
  h={'fin':{'ansible_user':'root','ansible_host':'193.32.179.127','ansible_port':22,'ansible_ssh_private_key_file':'/tmp/key'}}
  with patch.object(fleet,'load',return_value=({}, {}, h)),patch.object(fleet,'ensure_key',return_value=(pathlib.Path('/tmp/key'),pathlib.Path('/tmp/key.pub'))),patch.object(fleet.subprocess,'run',return_value=subprocess.CompletedProcess([],0)),patch.object(fleet,'run') as remote:
   ready,failed=fleet.enroll('all')
   self.assertEqual(ready,['fin']);self.assertEqual(failed,[]);remote.assert_not_called()
 def test_plan_does_not_connect(self):
  h={'fin':{'ansible_user':'root','ansible_host':'193.32.179.127','ansible_port':22}}
  with patch.object(fleet,'load',return_value=({}, {}, h)),patch.object(fleet.subprocess,'run') as remote:
   fleet.enroll('all',True);remote.assert_not_called()
 def test_validate_download_before_touching_hosts(self):
  with tempfile.TemporaryDirectory() as tmp:
   key=pathlib.Path(tmp)/'key';subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
   public=pathlib.Path(str(key)+'.pub').read_text()
   self.assertEqual(fleet.validate_keys(public+public).count('ssh-ed25519'),1)
   for bad in ['', '<html>error</html>', 'ssh-ed25519 Zm9v', public+'garbage']:
    with self.assertRaises(ValueError):fleet.validate_keys(bad)
if __name__=='__main__':unittest.main()
