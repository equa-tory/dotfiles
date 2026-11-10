"""Generate Prometheus rule fixtures using the exact provisioned alert expressions."""
import json,pathlib,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
import monitoring
def generate(folder):
 folder=pathlib.Path(folder);folder.mkdir(parents=True,exist_ok=True)
 selected=[r for r in monitoring.rules('loki')['groups'][0]['rules'] if r['uid'] in ['fleet-high-cpu','fleet-high-bandwidth','fleet-high-packets','fleet-disk-prediction','fleet-metrics-stopped']]
 rules=[{'alert':r['uid'],'expr':r['data'][0]['model']['expr'],'for':r['for']} for r in selected]
 (folder/'rules.yml').write_text(json.dumps({'groups':[{'name':'fixture','interval':'1m','rules':rules}]}))
 def series(name,values):return {'series':name,'values':values}
 thresholds=[series('fleet_threshold_cpu_percent{host="test"}','90+0x60'),series('fleet_threshold_outgoing_mbps{host="test"}','100+0x120'),series('fleet_threshold_outgoing_pps{host="test"}','10000+0x120')]
 def alert(uid,when,labels=None):return {'eval_time':when,'alertname':uid,'exp_alerts':[] if labels is None else [{'exp_labels':labels,'exp_annotations':{}}]}
 tests=[
 {'name':'CPU must remain above threshold for fifteen minutes','interval':'1m','input_series':thresholds+[series('node_cpu_seconds_total{host="test",mode="idle"}','0+3x60')],'alert_rule_test':[alert('fleet-high-cpu','14m'),alert('fleet-high-cpu','20m',{'host':'test'})]},
 {'name':'High bytes and packets are sustained independently','interval':'30s','input_series':thresholds+[series('node_network_transmit_bytes_total{host="test",device="eth0"}','0+450000000x120'),series('node_network_transmit_packets_total{host="test",device="eth0"}','0+350000x120')],'alert_rule_test':[alert('fleet-high-bandwidth','14m'),alert('fleet-high-bandwidth','20m',{'host':'test'}),alert('fleet-high-packets','4m'),alert('fleet-high-packets','8m',{'host':'test'})]},
 {'name':'Counter reset must not create a traffic spike','interval':'30s','input_series':thresholds+[series('node_network_transmit_bytes_total{host="test",device="eth0"}','0+6000000x20 0+6000000x80'),series('node_network_transmit_packets_total{host="test",device="eth0"}','0+30x20 0+30x80')],'alert_rule_test':[alert('fleet-high-bandwidth','30m'),alert('fleet-high-packets','30m')]},
 ]
 disk=[series('node_filesystem_size_bytes{host="test",mountpoint="/"}','1000+0x840'),series('node_filesystem_readonly{host="test",mountpoint="/"}','0+0x840'),series('fleet_threshold_disk_used_percent{host="test"}','70+0x840'),series('fleet_threshold_disk_fill_hours{host="test"}','24+0x840')]
 tests += [
 {'name':'Disk forecast requires history and a sustained downward trend','interval':'30s','input_series':disk+[series('node_filesystem_avail_bytes{host="test",mountpoint="/"}','150-0.0666666667x840')],'alert_rule_test':[alert('fleet-disk-prediction','1h'),alert('fleet-disk-prediction','6h30m',{'host':'test','mountpoint':'/'})]},
 {'name':'Flat low disk free space does not predict filling','interval':'30s','input_series':disk+[series('node_filesystem_avail_bytes{host="test",mountpoint="/"}','150+0x840')],'alert_rule_test':[alert('fleet-disk-prediction','6h30m')]},
 {'name':'One absent host is detected while the other remains healthy','interval':'1m','input_series':[series('fleet_expected_host{host="test"}','1+0x15'),series('fleet_expected_host{host="other"}','1+0x15'),series('node_time_seconds{host="test"}','0+60x15'),series('node_time_seconds{host="other"}','0+60x2')],'alert_rule_test':[alert('fleet-metrics-stopped','2m'),alert('fleet-metrics-stopped','9m',{'host':'other'})]},
 ]
 (folder/'tests.yml').write_text(json.dumps({'rule_files':['rules.yml'],'evaluation_interval':'1m','tests':tests},indent=2))
if __name__=='__main__':generate(sys.argv[1])
