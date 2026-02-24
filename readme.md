# Mojaloop distribution system


## Prerequisites

Create the promox token
```bash
pveum user token add root@pam 'ml-iac3' --privsep 0
# pveum acl modify / -user root@pam -token 'root@pam!ml-iac3' -role Administrator
pveum acl modify / -token 'root@pam!ml-iac3' -role Administrator
```

┌──────────────┬──────────────────────────────────────┐
│ key          │ value                                │
╞══════════════╪══════════════════════════════════════╡
│ full-tokenid │ root@pam!ml-iac3                     │
├──────────────┼──────────────────────────────────────┤
│ info         │ {"privsep":"0"}                      │
├──────────────┼──────────────────────────────────────┤
│ value        │ 702f4dd6-7511-4442-ac26-5b1309b7c1a6 │

token to use: root@pam!ml-iac3=702f4dd6-7511-4442-ac26-5b1309b7c1a6 


##

```bash
mojaloop@ccu6:~$ eval "$(ssh-agent -s)"

mojaloop@ccu6:~$ ssh-add ssh_key_ml_iac3

mojaloop@ccu6:~$ git clone git@github.com:kiswend/ml-iac3.git

```




## DNS zone

```bash
# 1. Create the subdomain zone
doctl compute domain create sw5.pj1.moja-do.example.com

# 2. Add NS delegation in the parent zone
doctl compute domain records create moja-do.example.com --record-type NS --record-name sw5.pj1 --record-data ns1.digitalocean.com. --record-ttl 300
doctl compute domain records create moja-do.example.com --record-type NS --record-name sw5.pj1 --record-data ns2.digitalocean.com. --record-ttl 300
doctl compute domain records create moja-do.example.com --record-type NS --record-name sw5.pj1 --record-data ns3.digitalocean.com. --record-ttl 300


```