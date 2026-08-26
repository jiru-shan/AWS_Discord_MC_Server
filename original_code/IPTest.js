const publicIp = require('public-ip');

(async () => {
    try {
        const ipv4 = await publicIp.publicIpv4();
        console.log('Your public IPv4 address:', ipv4);
    } catch (error) {
        console.error('Error getting public IP:', error);
    }
})();

