const { spawn } = require('child_process');
const { WebhookClient } = require('discord.js');

const webhookClient = new WebhookClient({ url: 'https://discord.com/api/webhooks/REDACTED/REDACTED' });

const child = spawn("sudo", [    // process is the actual server process spawned with spawn()
    "java",
    "-Xmx2700m",
    "-Xms2700m",
    "-XX:+AlwaysPreTouch",
    "-jar",
    "/opt/minecraft/server/server.jar",
    "nogui"]
);

child.stdout.on('data', (data) => {
  console.log(`Child stdout: ${data}`);
  if(data.includes("seconds, pausing"))
  {
     console.log('stopping');
     child.stdin.write('/stop\r');
  }
  else if(data.includes("RCON Listener stopped"))
  {
     console.log('stopped');
     webhookClient.send({content:'Server stopped due to inactivity.', username: 'JAC Minecraft', avatarUrl: 'https://cdn.discordapp.com/avatars/REDACTED/REDACTED.webp?size=128'})
     .then(() => process.exit());
  }
  else if(data.includes("Starting Minecraft server"))
  {
     console.log('server started');
     webhookClient.send({content:'Server started.', username: 'JAC Minecraft'})
     .then(() => console.log('Webhook sent'));
  }
});

