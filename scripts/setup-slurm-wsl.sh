#!/usr/bin/env bash
# One-time host setup for the single-node Slurm sandbox (Phase H) on Ubuntu 24.04 / WSL2.
# Needs sudo and changes the host: read it before running. Run it as your normal user:
#     ./scripts/setup-slurm-wsl.sh
# It installs munge, slurmctld, slurmd, slurmdbd, MariaDB (accounting storage), make and
# Apptainer, writes /etc/slurm from slurm/ and creates two accounts and one QoS.
# Safe to run again after editing a file in slurm/.
#
# To stop it all later (these services start at boot and use memory):
#     sudo systemctl disable --now slurmd slurmctld slurmdbd mariadb munge
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not with sudo." >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$(hostname -s)"
JOB_USER="$(id -un)"

SLURM_V=23.11.4-1.2ubuntu5
APPTAINER_V=1.5.5
APPTAINER_SHA256=25095d3711504b3e8657dbb2e172ef8db9db43c4503d940c9c36b105db8dce77

# 1. Pinned packages from the Ubuntu archive.
sudo apt-get update
sudo apt-get install -y \
  munge=0.5.15-4ubuntu0.1 \
  "slurm-wlm=$SLURM_V" "slurmctld=$SLURM_V" "slurmd=$SLURM_V" "slurmdbd=$SLURM_V" \
  "slurm-client=$SLURM_V" "slurm-wlm-basic-plugins=$SLURM_V" "slurm-wlm-mysql-plugin=$SLURM_V" \
  mariadb-server=1:10.11.14-0ubuntu0.24.04.1 \
  make=4.3-4.1build2

# 2. Apptainer from the upstream release, checksum-verified.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
deb="apptainer_${APPTAINER_V}_amd64.deb"
curl -fsSL -o "$tmp/$deb" \
  "https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_V}/$deb"
echo "$APPTAINER_SHA256  $tmp/$deb" | sha256sum -c -
chmod 755 "$tmp" # let apt's sandbox user read the file
sudo apt-get install -y "$tmp/$deb"

# 3. munge (the package creates a key on install).
sudo systemctl enable --now munge
munge -n | unmunge >/dev/null && echo "munge OK"

# 4. Accounting database.
sudo systemctl enable --now mariadb
sudo mariadb <<'SQL'
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED VIA unix_socket;
GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost';
SQL

# 5. Config files.
sudo install -d -m 755 /etc/slurm
for f in slurm.conf gres.conf cgroup.conf; do
  sed "s/__HOST__/$HOST/g" "$REPO/slurm/$f" | sudo tee "/etc/slurm/$f" >/dev/null
  sudo chmod 644 "/etc/slurm/$f"
done
sudo install -m 600 -o slurm -g slurm "$REPO/slurm/slurmdbd.conf" /etc/slurm/slurmdbd.conf
sudo install -d -o slurm -g slurm /var/lib/slurm /var/lib/slurm/slurmctld /var/log/slurm
sudo install -d /var/lib/slurm/slurmd

# 6. slurmdbd first, then register the cluster, then controller and node daemon.
sudo systemctl enable slurmdbd slurmctld slurmd
sudo systemctl restart slurmdbd
for _ in $(seq 30); do sudo sacctmgr -n show cluster >/dev/null 2>&1 && break; sleep 2; done
sudo sacctmgr -n show cluster | grep -qw labsandbox || sudo sacctmgr -i add cluster labsandbox

# Record how this Slurm build treats three ways of declaring the GPU. Uses a temporary
# copy of the config; /etc/slurm is not changed by the probe.
sudo systemctl stop slurmd
mkdir -p "$REPO/results/slurm/gres" "$tmp/probe"
cp /etc/slurm/slurm.conf /etc/slurm/cgroup.conf "$tmp/probe/"
probe() { # result-file-name gres.conf-line
  echo "$2" >"$tmp/probe/gres.conf"
  {
    echo "# gres.conf: $2"
    echo '$ slurmd -D -G -v'
    rc=0
    sudo slurmd -D -G -v -f "$tmp/probe/slurm.conf" 2>&1 || rc=$?
    echo "exit=$rc"
  } | tee "$REPO/results/slurm/gres/$1.txt"
}
probe autodetect_nvml "AutoDetect=nvml"
probe count_only "NodeName=$HOST Name=gpu Count=1"
probe file_dxg "NodeName=$HOST Name=gpu File=/dev/dxg"

sudo systemctl restart slurmctld slurmd
sleep 5
# A node drained by an earlier bad GPU declaration stays drained until resumed.
sudo scontrol update NodeName="$HOST" State=RESUME || true
sleep 3

# 7. Two accounts with unequal fair-share, one QoS. sacctmgr exits non-zero when an object
#    already exists ("Nothing new added"), so failures are tolerated here and the result is
#    printed below for you to check. One Linux user belongs to both accounts.
sudo sacctmgr -i add account research Fairshare=70 Description=sandbox Organization=lab || true
sudo sacctmgr -i add account teaching Fairshare=30 Description=sandbox Organization=lab || true
sudo sacctmgr -i add qos high || true
sudo sacctmgr -i modify qos high set Priority=100
sudo sacctmgr -i add user "$JOB_USER" Account=research,teaching DefaultAccount=research || true
sudo sacctmgr -i modify user "$JOB_USER" set QOS=normal,high || true

echo "---- result ----"
systemctl is-active munge mariadb slurmdbd slurmctld slurmd || true
sacctmgr show assoc format=cluster,account,user,fairshare,qos
sacctmgr show qos format=name,priority
sinfo -o "%P %a %l %D %t %G"
scontrol show node "$HOST" | grep -E 'State=|Gres|CfgTRES|Reason' || true
echo "If a service is not active: sudo journalctl -u slurmd -u slurmctld -u slurmdbd -n 50 --no-pager"
