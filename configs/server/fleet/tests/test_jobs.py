import importlib.util,pathlib,tempfile,unittest,argparse,subprocess,os
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('fleet',ROOT/'fleet.py');fleet=importlib.util.module_from_spec(spec);spec.loader.exec_module(fleet)
class JobTests(unittest.TestCase):
 def fixture(self,root,name,body,filename='run.sh'):
  p=pathlib.Path(root)/'jobs'/name/filename;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(body);return p
 def test_drop_in_job_and_metadata_are_discovered(self):
  with tempfile.TemporaryDirectory() as tmp,patch.object(fleet,'ROOT',pathlib.Path(tmp)):
   self.fixture(tmp,'maintenance/hello','#!/bin/bash\n# description: Hello servers\n# sudo: true\n# serial: 2\necho hello\n')
   job=fleet.discover_jobs()['maintenance/hello']
   self.assertEqual(job['runner'],'remote');self.assertTrue(job['sudo']);self.assertEqual(job['serial'],2)
 def test_ambiguous_entry_or_alias_fails(self):
  with tempfile.TemporaryDirectory() as tmp,patch.object(fleet,'ROOT',pathlib.Path(tmp)):
   self.fixture(tmp,'a','echo hi');self.fixture(tmp,'a','[]','run.yml')
   with self.assertRaises(ValueError):fleet.discover_jobs()
  with tempfile.TemporaryDirectory() as tmp,patch.object(fleet,'ROOT',pathlib.Path(tmp)):
   self.fixture(tmp,'a','# aliases: sync\necho hi')
   with self.assertRaises(ValueError):fleet.discover_jobs()
 def test_dynamic_command_options_need_no_registry(self):
  with tempfile.TemporaryDirectory() as tmp,patch.object(fleet,'ROOT',pathlib.Path(tmp)):
   self.fixture(tmp,'new-job','# options: package=package_name\necho hi')
   with patch.object(fleet.sys,'argv',['fleet','new-job','--package','curl','--plan']),patch.object(fleet,'execute_job') as execute:
    fleet.main();job,args=execute.call_args.args
    self.assertEqual(job['name'],'new-job');self.assertEqual(fleet.job_variables(args,job),{'package_name':'curl'})
 def test_controller_plan_never_executes_script(self):
  with tempfile.TemporaryDirectory() as tmp,patch.object(fleet,'ROOT',pathlib.Path(tmp)):
   self.fixture(tmp,'local','print("would mutate")','run.py');job=fleet.discover_jobs()['local']
   args=argparse.Namespace(limit=None,plan=True,check=False,variables=[],ask_become_pass=False)
   with patch.object(fleet,'load',return_value=({}, {}, {'host':{}})),patch.object(fleet,'run') as execute,patch.object(fleet,'run_ansible') as plan:
    fleet.execute_job(job,args);execute.assert_not_called();plan.assert_called_once()
 def test_sync_hooks_are_generic(self):
  args=argparse.Namespace(plan=False,enroll_only=False,host='all')
  job={'name':'custom-hook','description':'anything','on-sync':True}
  with patch.object(fleet,'discover_jobs',return_value={'custom-hook':job}),patch.object(fleet,'enroll',return_value=(['host'],[])),patch.object(fleet,'execute_job') as execute:
   fleet.sync(args);self.assertEqual(execute.call_args.args[0],job)
 @unittest.skipUnless((ROOT/"install.sh").exists(),"Installer test runs from the dotfiles source checkout")
 def test_reinstall_keeps_custom_jobs_unless_explicitly_replaced(self):
  body=(ROOT/'install.sh').read_text().split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
  with tempfile.TemporaryDirectory() as tmp:
   target=pathlib.Path(tmp)/'fleet';entry=target/'jobs/uptime/run.sh';entry.parent.mkdir(parents=True);entry.write_text('# user customization\necho own\n')
   servers=target/'servers.txt';servers.write_text('root@server.example.com\n')
   cmd=[fleet.sys.executable,'-c',body,str(ROOT),str(target)]
   clean_env={k:v for k,v in os.environ.items() if k!='FLEET_REPLACE_JOBS'}
   subprocess.run(cmd,check=True,env=clean_env)
   self.assertIn('user customization',entry.read_text());self.assertEqual(servers.read_text(),'root@server.example.com\n')
   subprocess.run(cmd,check=True,env=dict(clean_env,FLEET_REPLACE_JOBS='1'))
   self.assertEqual(entry.read_text(),(ROOT/'jobs/uptime/run.sh').read_text())
 def test_reserved_engine_variables_cannot_be_overridden(self):
  args=argparse.Namespace(variables=['fleet_job_script=/tmp/other'])
  with self.assertRaises(ValueError):fleet.job_variables(args,{'options':{}})
if __name__=='__main__':unittest.main()
