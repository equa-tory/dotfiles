import importlib.util,pathlib,tempfile,unittest,subprocess,json
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('fleet',ROOT/'fleet.py');fleet=importlib.util.module_from_spec(spec);spec.loader.exec_module(fleet)
class FleetTests(unittest.TestCase):
 def test_inventory_has_separate_users_and_no_secrets(self):
  old=fleet.CONFIG
  with tempfile.TemporaryDirectory() as tmp:
   try:
    fleet.CONFIG=pathlib.Path(tmp)
    fleet.init('equa','~/.ssh/example','https://github.com/equa-tory.keys')
    hosts=fleet.load()[2]
    self.assertEqual(len(hosts),5)
    self.assertEqual(hosts['hip-fin']['ansible_host'],'193.32.179.127')
    self.assertNotIn('ansible_password',str(hosts))
    self.assertEqual((fleet.CONFIG/'inventory.json').stat().st_mode & 0o777,0o600)
    with self.assertRaises(ValueError):fleet.init('root','~/.ssh/example','https://github.com/equa-tory.keys')
   finally:fleet.CONFIG=old
 def test_validate_download_before_touching_hosts(self):
  with tempfile.TemporaryDirectory() as tmp:
   key=pathlib.Path(tmp)/'key'
   subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
   public=pathlib.Path(str(key)+'.pub').read_text()
   self.assertEqual(fleet.validate_keys(public+public).count('ssh-ed25519'),1)
   for bad in ['', '<html>error</html>', 'ssh-ed25519 Zm9v', public+'garbage']:
    with self.assertRaises(ValueError):fleet.validate_keys(bad)
 def test_reject_unverified_key_source_and_shell_fields(self):
  for url in ['http://github.com/equa-tory.keys','https://u:p@github.com/user.keys']:
   with self.assertRaises(ValueError):fleet.validate_url(url)
  for user in ['root; rm','-bad','foo@bar']:
   with self.assertRaises(ValueError):fleet.valid_user(user)
if __name__=='__main__':unittest.main()
