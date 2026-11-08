#!/usr/bin/env python3
# description: Fetch validated GitHub public keys and merge them into authorized_keys
# aliases: keys
# options: key-user=fleet_key_user
# on-sync: true
# check: true
import json,os,pathlib,sys,argparse
sys.path.insert(0,os.environ['FLEET_HOME'])
import fleet
context=json.loads(pathlib.Path(os.environ['FLEET_JOB_CONTEXT']).read_text())
args=argparse.Namespace(**context['args'])
variables=context['variables']
if 'fleet_key_user' in variables:fleet.valid_user(variables['fleet_key_user'])
if not args.plan:
    variables['fleet_public_keys']=fleet.fetch_keys(context['settings']['keys_url'])
    print('Downloaded and validated public keys. Existing unrelated SSH keys are preserved.',flush=True)
fleet.run_ansible(pathlib.Path(__file__).with_name('tasks.yml'),args,variables)
