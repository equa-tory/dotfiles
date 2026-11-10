import contextlib,io,json,pathlib,sys,tempfile,unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
import collector_helper as helper
import monitoring
class MonitoringTests(unittest.TestCase):
 def test_accounts_baseline_and_changes(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp)/'passwd';state=pathlib.Path(tmp)/'state.json'
   p.write_text('root:x:0:0::/root:/bin/bash\n')
   with patch.object(helper,'emit') as log:
    helper.accounts(p,state);log.assert_not_called()
    p.write_text(p.read_text()+'newuser:x:1005:1005::/home/new:/bin/bash\nsvc:x:123:123::/:/bin/false\n')
    helper.accounts(p,state)
    self.assertEqual(log.call_count,2)
    self.assertIn('account_type=user',log.call_args_list[0].args[0])
    self.assertIn('account_type=service',log.call_args_list[1].args[0])
    helper.accounts(p,state);self.assertEqual(log.call_count,2)
    self.assertNotIn(':x:',state.read_text())
 def test_gpu_failure_replaces_old_values(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp)/'gpu.prom';p.write_text('fleet_gpu_utilization_percent 99\n')
   with patch.object(helper.subprocess,'run',side_effect=OSError('failed')):helper.gpu(p)
   self.assertIn('fleet_gpu_collection_success 0',p.read_text())
   self.assertNotIn('utilization_percent',p.read_text())
 def test_missing_hosts_are_explicit(self):
  rules=monitoring.rules('test-loki')['groups'][0]['rules']
  hosts=set(monitoring.inventory()['machines'])
  heartbeat=[r for r in rules if r['uid'].startswith('fleet-heartbeat-')]
  self.assertEqual({r['labels']['host'] for r in heartbeat},hosts)
  self.assertTrue(all(r['execErrState']=='Error' for r in rules))
  self.assertEqual(len({r['uid'] for r in rules}),len(rules))
  self.assertIn('unless on(host)',next(r for r in rules if r['uid']=='fleet-metrics-stopped')['data'][0]['model']['expr'])
 def test_navigation_and_expected_options(self):
  with tempfile.TemporaryDirectory() as tmp:
   monitoring.provision(tmp,'unchanged-loki')
   folder=pathlib.Path(tmp)/'grafana/provisioning/dashboards/json'
   for f in folder.glob('*.json'):
    d=json.loads(f.read_text())
    self.assertEqual([x['title'] for x in d['links'][:6]],[x[0] for x in monitoring.NAV])
    self.assertTrue(all(x['keepTime'] and x['includeVars'] for x in d['links'][:6]))
    self.assertIn('hip-japan',d['templating']['list'][0]['query'])
   d=json.loads((folder/'logs.json').read_text());query=d['panels'][0]['targets'][0]['expr']
   self.assertIn('contains (urldecode "${text:percentencode}")',query)
   self.assertNotIn('|~ "${text',query)
 def test_removed_host_deletes_its_heartbeat_rule(self):
  with tempfile.TemporaryDirectory() as tmp:
   cfg={'machines':{'first':{},'second':{}}}
   monitoring.provision(tmp,'test-loki',cfg)
   monitoring.provision(tmp,'test-loki',{'machines':{'first':{}}})
   data=json.loads((pathlib.Path(tmp)/'grafana/provisioning/alerting/fleet.yaml').read_text())
   self.assertEqual(data['deleteRules'],[{'orgId':1,'uid':'fleet-heartbeat-second'}])
 def test_metrics_endpoint_does_not_allow_external_plaintext(self):
  for endpoint in ['http://external.example/api/v1/write','https://user:pass@example/api/v1/write','https://example/api/v1/write?bad=true']:
   with self.assertRaises(ValueError):monitoring.metrics('test',endpoint)
 def test_all_hosts_loki_selectors_require_a_nonempty_host(self):
  with tempfile.TemporaryDirectory() as tmp:
   monitoring.provision(tmp,'test-loki')
   for file in (pathlib.Path(tmp)/'grafana/provisioning/dashboards/json').glob('*.json'):
    dashboard=json.loads(file.read_text())
    host=dashboard['templating']['list'][0]
    self.assertEqual(host['allValue'],'.+')
    for variable in dashboard['templating']['list']:
     if variable.get('type')=='query' and '$host' in variable.get('query',''):
      self.assertIn('host!=""',variable['query'])
    for panel in dashboard['panels']:
     for target in panel.get('targets',[]):
      ds=target.get('datasource',panel.get('datasource',{}))
      if ds.get('uid')=='test-loki' and '$host' in target['expr']:
       self.assertIn('host!=""',target['expr'])
 def test_reinstallation_replaces_metrics_once(self):
  logs='loki.write "home" {}\n'
  one=logs+monitoring.metrics('test-host','https://logs.example.org/api/v1/write','test-host',['eth0'])
  two=monitoring.strip_metrics(one)+monitoring.metrics('test-host','https://logs.example.org/api/v1/write','test-host',['ens3'])
  self.assertEqual(two.count('prometheus.scrape "fleet"'),1)
  self.assertIn('ens3',two);self.assertNotIn('eth0',two)
if __name__=='__main__':unittest.main()
