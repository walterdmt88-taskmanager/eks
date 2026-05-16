#!/usr/bin/env bash
set -e
REGION="eu-central-1"
DATE=$(date +%Y%m%d-%H%M%S)

echo "=== Pre-deletion EBS Snapshot — $DATE ==="

# Get all PVC-backed EBS volumes in the cluster
VOLUMES=$(aws ec2 describe-volumes \
  --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=default" \
  --region "$REGION" \
  --query 'Volumes[].{VolumeId:VolumeId,PVC:Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]}' \
  --output json)

echo "$VOLUMES" | python3 -c "
import sys, json, subprocess
vols = json.load(sys.stdin)
for v in vols:
    vol_id = v['VolumeId']
    pvc    = v['PVC']
    desc   = f'pre-delete-{pvc}-${DATE}'
    print(f'Snapshotting {vol_id} ({pvc})...')
    result = subprocess.run([
        'aws', 'ec2', 'create-snapshot',
        '--volume-id', vol_id,
        '--description', desc,
        '--region', '$REGION',
        '--tag-specifications',
        f'ResourceType=snapshot,Tags=[{{Key=Name,Value={desc}}},{{Key=Owner,Value=chau_tv}},{{Key=Project,Value=taskmanager}}]',
        '--query', 'SnapshotId', '--output', 'text'
    ], capture_output=True, text=True)
    print(f'  → {result.stdout.strip()}')
"

echo ""
echo "Snapshots created. Safe to run: eksctl delete cluster -f eks/cluster.yaml"
