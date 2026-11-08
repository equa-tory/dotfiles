import pathlib,sys,unittest,tempfile,json
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from agent import render as agent,load_credential
from gateway import render as gateway
from common import endpoint,validate_host,FLEET
class ConfigTests(unittest.TestCase):
 def test_agent_without_docker(self):
  s=agent('hip-fin',FLEET['endpoint'],'hip-fin')
  self.assertNotIn('discovery.docker',s)
  self.assertIn('password_file = "/etc/alloy/loki.password"',s)
  self.assertNotIn('__HOST__',s)
  self.assertIn('host = "hip-fin"',s)
 def test_docker_noise_toggle(self):
  s=agent('hip-fin',FLEET['endpoint'],'hip-fin',True)
  self.assertIn('action = "drop"',s)
  self.assertNotIn('action = "drop"',agent('hip-fin',FLEET['endpoint'],'hip-fin',True,True))
 def test_reject_injection_and_plaintext(self):
  for value in ['bad"host','a\nblock {}','-bad']:
   with self.assertRaises(ValueError):validate_host(value)
  for value in ['http://example.com/loki/api/v1/push','https://u:p@example.com/loki/api/v1/push','https://example.com/loki/api/v1/query']:
   with self.assertRaises(ValueError):endpoint(value)
 def test_private_credential_import(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp)/'agent.json'
   data=dict(host='other-vps',endpoint='https://logs.example.org/loki/api/v1/push',username='other-vps',password='private-test-secret')
   p.write_text(json.dumps(data));p.chmod(0o600)
   self.assertEqual(load_credential(p),data)
   p.chmod(0o644)
   with self.assertRaises(ValueError):load_credential(p)
   p.chmod(0o600);p.write_text(json.dumps(dict(data,endpoint='http://logs.example.org/loki/api/v1/push')))
   with self.assertRaises(ValueError):load_credential(p)
 def test_gateway_requires_ip_and_password(self):
  hashed='$2a$14$'+'a'*53
  s=gateway('logs.example.com:3443','127.0.0.1:3100',list(FLEET['machines'].values()),{'hip-fin':hashed})
  self.assertLess(s.index('respond @outside'),s.index('basicauth'))
  self.assertIn('not method POST',s)
  self.assertIn('respond 404',s)
  self.assertIn('193.32.179.127/32',s)
  self.assertIn('hip-fin '+hashed,s)
  with self.assertRaises(ValueError):gateway('logs.example.com','0.0.0.0:3100',[],{'hip-fin':hashed})
  with self.assertRaises(ValueError):gateway('logs.example.com','127.0.0.1:3100',[],{})
if __name__=='__main__':unittest.main()
