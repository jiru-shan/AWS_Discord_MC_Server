const { Route53Client, ChangeResourceRecordSetsCommand } = require("@aws-sdk/client-route-53");
const publicIp = require('public-ip');

async function changeDnsRecord(hostedZoneId, recordName, recordType, ttl = 30) {
  const client = new Route53Client({ region: "us-east-1" }); // Replace with your desired region
  const newIpAddress = await publicIp.publicIpv4();


  const params = {
    HostedZoneId: hostedZoneId,
    ChangeBatch: {
      Changes: [
        {
          Action: "UPSERT", // Use "UPSERT" to either create or update the record
          ResourceRecordSet: {
            Name: recordName,
            Type: recordType,
            TTL: ttl,
            ResourceRecords: [
              { Value: newIpAddress },
            ],
          },
        },
      ],
    },
  };

  try {
    const command = new ChangeResourceRecordSetsCommand(params);
    const data = await client.send(command);
    console.log("DNS record changed successfully:", data);
  } catch (err) {
    console.error("Error changing DNS record:", err);
  }
}

const recordName = "minecraft.example.com";
const recordType = "A";
const hostedZoneId = "REDACTED";

changeDnsRecord(hostedZoneId, recordName, recordType);
