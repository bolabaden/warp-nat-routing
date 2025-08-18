systemctl stop warp.service
systemctl disable warp.service
rm -rvf /etc/systemd/system/warp.service
rm -rvf /etc/systemd/system/multi-user.target.wants/warp.service
docker network rm warp_network
docker network prune -f

# Stop and disable service
systemctl stop warp
systemctl disable warp

# Remove service files
rm /etc/systemd/system/warp.service
rm -rf /etc/systemd/system/warp.service.d

# Remove installed scripts and files
rm -f /usr/local/bin/warp-up.sh
rm -f /usr/local/bin/warp-down.sh
rm -rf /usr/local/share/warp-docker-nat

# Reload systemd
systemctl daemon-reload
systemctl reset-failed