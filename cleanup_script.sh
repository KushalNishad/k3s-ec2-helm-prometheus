
INSTANCE_ID=$(jq -r '.Instances[0].InstanceId' Resources/AWS/ec2_details.json)

echo "Instance Id: ${INSTANCE_ID}"

aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}

aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"

echo "Instance Id: ${INSTANCE_ID} Terminated"

SG_ID=$(jq -r '.GroupId' Resources/AWS/security_group_details.json)

echo "Security Group Id: ${SG_ID}"

aws ec2 delete-security-group --group-id ${SG_ID}

echo "Security Group Id: ${INSTANCE_ID} Terminated"