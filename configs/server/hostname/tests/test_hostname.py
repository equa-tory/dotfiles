import importlib.util,pathlib,unittest
p=pathlib.Path(__file__).resolve().parents[1]/'hostname.py'
s=importlib.util.spec_from_file_location('change_hostname',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class HostnameTests(unittest.TestCase):
 def test_complete_names_and_fqdn(self):
  self.assertEqual(m.validate('HIP-Fin'),'hip-fin');self.assertEqual(m.validate('my-box.example.net'),'my-box.example.net')
 def test_reject_bad_names(self):
  for name in ('root@foo','-bad','bad-','a..b','a b','31.76.226.149','localhost','a'*65,'bad\nname'):
   with self.subTest(name=name),self.assertRaises(ValueError):m.validate(name)
 def test_keeps_old_alias_and_other_records(self):
  old='127.0.0.1 localhost\n127.0.1.1 vm1355492 other # VPS\n10.0.0.8 database\n::1 localhost ip6-localhost\n'
  new=m.update_hosts(old,'vm1355492','hip-fin')
  self.assertIn('127.0.1.1\thip-fin vm1355492 other  # VPS',new)
  self.assertIn('10.0.0.8 database\n',new);self.assertIn('::1 localhost ip6-localhost\n',new)
 def test_adds_record_without_overwriting_unrelated_alias(self):
  old='127.0.0.1 localhost\n127.0.1.1 unrelated\n'
  new=m.update_hosts(old,'old-vm','hip-fin.example.net')
  self.assertTrue(new.startswith(old));self.assertIn('hip-fin.example.net hip-fin old-vm',new)
 def test_repeat_is_idempotent(self):
  a=m.update_hosts('127.0.1.1 old-vm\n','old-vm','hip-fin')
  self.assertEqual(m.update_hosts(a,'hip-fin','hip-fin'),a)
 def test_rejects_conflicting_mapping(self):
  with self.assertRaises(ValueError):m.update_hosts('10.0.0.8 hip-fin\n','old-vm','hip-fin')
if __name__=='__main__':unittest.main()
