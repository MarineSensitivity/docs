_on AWS as EC2 instance using Docker_

### launch instance

name: **msens1**:

- Software Image (AMI)\
  Canonical, **Ubuntu**, 22.04 LTS, amd64 jammy image build on 2023-09-19
  ami-0fc5d935ebf8bc3bc
- Virtual server type (instance type)\
  **t2.xlarge** (4 vCPU, 16 GB memory)\
- Firewall (security group)\
  New security group
- Storage (volumes)\
  2 volume(s)
  - **20 GB**\
    `/` server software, disposable
  - **60 GB**\
    `/share` for all data, persistent and to be backed up

#### allocate IP address

* [Elastic IP addresses | EC2 | us-east-1](https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#Addresses:) for persistent IP address

- Allocated IPv4 address: `100.25.173.0`
- Associate Elastic IP address

### ssh to server

```bash
pem='/Users/bbest/My Drive/private/msens_key_pair.pem'
ssh -i $pem ubuntu@msens1.marinesensitivity.org
```

#### set hostname

* [Change the hostname of your Amazon Linux instance - Amazon Elastic Compute Cloud](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-hostname.html)


```bash
sudo vi /etc/cloud/cloud.cfg
# preserve_hostname: true
sudo hostnamectl set-hostname msens1.marinesensitivity.org
sudo reboot
```

#### mount volume

The extra volume (60 GB for `/share`) was added during EC2 launch instance wizard, but needs to be mounted before available for use.

* [Make an Amazon EBS volume available for use on Linux - Amazon Elastic Compute Cloud](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-using-volumes.html)

```bash
df -H
```

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        21G  2.3G   19G  11% /
tmpfs           8.4G     0  8.4G   0% /dev/shm
tmpfs           3.4G  898k  3.4G   1% /run
tmpfs           5.3M     0  5.3M   0% /run/lock
/dev/xvda15     110M  6.4M  104M   6% /boot/efi
tmpfs           1.7G  4.1k  1.7G   1% /run/user/1000
```

```bash
lsblk
```

```
NAME     MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0      7:0    0  24.6M  1 loop /snap/amazon-ssm-agent/7528
loop1      7:1    0  55.7M  1 loop /snap/core18/2790
loop2      7:2    0  63.5M  1 loop /snap/core20/2015
loop3      7:3    0 111.9M  1 loop /snap/lxd/24322
loop4      7:4    0  40.8M  1 loop /snap/snapd/20092
xvda     202:0    0    20G  0 disk 
├─xvda1  202:1    0  19.9G  0 part /
├─xvda14 202:14   0     4M  0 part 
└─xvda15 202:15   0   106M  0 part /boot/efi
xvdb     202:16   0    60G  0 disk
```

```bash
sudo file -s /dev/xvdb
# /dev/xvdb: data
```

So no file system on `/dev/xvdb` yet.

```bash
sudo mkfs -t xfs /dev/xvdb
sudo mkdir /share
sudo mount /dev/xvdb /share
```

```bash
sudo cp /etc/fstab /etc/fstab.orig
sudo blkid
# /dev/xvdb: UUID="bc766dfb-1c42-49cf-9320-2242a2d48a2e" BLOCK_SIZE="512" TYPE="xfs"
sudo vim /etc/fstab
# UUID=bc766dfb-1c42-49cf-9320-2242a2d48a2e  /share  xfs  defaults,nofail  0  2

df -h
sudo umount /share ; df -h
sudo mount -a      ; df -h
```

### install docker

Following:

* [Step-by-Step Guide to Install Docker on Ubuntu in AWS | by Srija Anaparthy | Medium](https://medium.com/@srijaanaparthy/step-by-step-guide-to-install-docker-on-ubuntu-in-aws-a39746e5a63d)

```bash
sudo apt-get update
#OLD: sudo apt-get install docker.io -y
```

NEW: [[Migrate to `docker compose`]]

```bash
sudo systemctl start docker
sudo docker run hello-world
sudo systemctl enable docker
docker --version
# Docker version 24.0.6, build ed223bc
sudo usermod -a -G docker $(whoami)
```

#### run docker compose

- /Users/bbest/My Drive/private/[`msens_server_env-password.txt`](https://drive.google.com/open?id=17B3djETDU8SVwGvJdZ3rp7TKtX8w0cfl&usp=drive_fs)

```bash
sudo chown -R ubuntu:ubuntu /share
mkdir -p /share/github/MarineSensitivity
cd /share/github/MarineSensitivity
# clone server repo
git clone https://github.com/MarineSensitivity/server.git
cd server

# add password, used as $PASSWORD in docker-compose.yml
echo 'PASSWORD=******' > .env

# launch docker instances
sudo docker-compose up -d
```

### Backup `/share` with snapshots

Per [Automate snapshot lifecycles - Amazon Elastic Compute Cloud](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/snapshot-ami-policy.html#create-snap-policy), created two policies:

- **bkup_msens-share_daily** every 24 hrs at 09:00 UTC, max of 7
- **bkup_msens-share_weekly** every Monday 09:00 UTC, max of 8

