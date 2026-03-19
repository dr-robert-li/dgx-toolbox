ip=$(hostname -I | awk '{print $1}')
pwd=$(journalctl -u code-server@${USER} -n 20 --no-pager | grep -i password | tail -1 | awk -F': ' '{print $2}')
echo "Connect to: http://$ip:8080   (password: $pwd)"
