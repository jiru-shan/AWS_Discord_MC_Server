rm -rf /opt/minecraft/backups/3/*
cp -a /opt/minecraft/backups/2/. /opt/minecraft/backups/3
rm -rf /opt/minecraft/backups/2/*
cp -a /opt/minecraft/backups/1/. /opt/minecraft/backups/2
rm -rf /opt/minecraft/backups/1/*
cp -a /opt/minecraft/server/. /opt/minecraft/backups/1
