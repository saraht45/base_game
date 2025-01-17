#!/bin/bash

# <UDF name="subdomain" label="Subdomain to contain game and game-login" example="Example: game.my-domain.com"/>
# SUBDOMAIN=
# <UDF name="userpassword" label="Deployment User Password" example="Password for various accounts and infrastructure." />
# USERPASSWORD=
# <UDF name="game_git_url" label="The Game's Git URL" default="https://github.com/ChatTheatre/base_game" example="Game Git URL to clone for your game." optional="false" />
# GAME_GIT_URL=
# <UDF name="game_git_branch" label="The Game's Git Branch" default="master" example="Game branch, tag or commit to clone for your game." optional="false" />
# GAME_GIT_BRANCH=
# <UDF name="skotos_git_url" label="Skotos Git URL" default="https://github.com/ChatTheatre/SkotOS" example="SkotOS Git URL to clone for your game." optional="false" />
# SKOTOS_GIT_URL=
# <UDF name="skotos_git_branch" label="Skotos Git Branch" default="master" example="SkotOS branch, tag or commit to clone for your game." optional="false" />
# SKOTOS_GIT_BRANCH=

set -e
set -x

# Output stdout and stderr to ~root files
exec > >(tee -a /root/game_standup.log) 2> >(tee -a /root/game_standup.log /root/game_standup.err >&2)

# e.g. clone_or_update "$SKOTOS_GIT_URL" "$SKOTOS_GIT_BRANCH" "/var/skotos"
function clone_or_update {
  if [ -d "$3" ]
  then
    pushd "$3"
    git fetch # Needed for "git checkout" if the branch has been added recently
    git checkout "$2"
    git pull
    popd
  else
    git clone "$1" "$3"
    pushd "$3"
    git checkout "$2"
    popd
  fi
  chgrp -R skotos "$3"
  chown -R skotos "$3"
  chmod -R g+w "$3"
}

# Parameters to pass to the SkotOS stackscript
export HOSTNAME="game"
export FQDN_CLIENT=game."$SUBDOMAIN"
export FQDN_LOGIN=game-login."$SUBDOMAIN"
export FQDN_JITSI=meet."$SUBDOMAIN"
export DGD_GIT_URL=https://github.com/ChatTheatre/dgd
export DGD_GIT_BRANCH=master
export THINAUTH_GIT_URL=https://github.com/ChatTheatre/thin-auth
export THINAUTH_GIT_BRANCH=master
export TUNNEL_GIT_URL=https://github.com/ChatTheatre/websocket-to-tcp-tunnel
export TUNNEL_GIT_BRANCH=master

if [ -z "$SKIP_INNER" ]
then
    # If we have the Github URL and the branch, we can download the stackscript directly.
    SKOTOS_STACKSCRIPT_URL=`echo $SKOTOS_GIT_URL | sed -E "s/https:\/\/github.com\/([0-9a-zA-Z]+)\/([0-9a-zA-Z]+).*/https:\/\/raw.githubusercontent.com\/\1\/\2\/$SKOTOS_GIT_BRANCH\/deploy_scripts\/stackscript\/linode_stackscript.sh/"`

    echo "Running SkotOS StackScript based on raw URL $SKOTOS_STACKSCRIPT_URL..."
    # Set up the node using the normal SkotOS Linode stackscript
    curl $SKOTOS_STACKSCRIPT_URL > ~root/skotos_stackscript.sh
    . ~root/skotos_stackscript.sh
fi

clone_or_update "$GAME_GIT_URL" "$GAME_GIT_BRANCH" /var/game

# Reset the logfile
rm -f /var/log/dgd/server.out

touch /var/log/start_game_server.sh
chown skotos /var/log/start_game_server.sh

# Replace Crontab with just the pieces we need - specifically, do NOT start the old SkotOS DGD server any more.
if grep /var/game/deploy_scripts/stackscript/start_game_server.sh ~skotos/crontab.txt
then
  echo "Crontab has the appropriate entry already..."
else
  cat >>~skotos/crontab.txt <<EndOfMessage
* * * * *  /var/game/deploy_scripts/stackscript/start_game_server.sh >>/var/log/start_game_server.sh
EndOfMessage
fi

# In case we're re-running, don't keep statedump files around and keep DGD server from restarting until we're ready.
touch /var/game/no_restart.txt
/var/game/deploy_scripts/stackscript/stop_game_server.sh
rm -f /var/game/skotos.database*

cd /var/game && bundle install

cat >~skotos/dgd_pre_setup.sh <<EndOfMessage
#!/bin/bash

set -e
set -x

cd /var/game
bundle exec dgd-manifest install
EndOfMessage
chmod +x ~skotos/dgd_pre_setup.sh
sudo -u skotos -g skotos ~skotos/dgd_pre_setup.sh

# We modify files in /var/game/.root after dgd-manifest has created the initial app directory.
# But we also copy those files into /var/game/root (note: no dot) so that if the user later
# rebuilds with dgd-manifest, the modified files will be kept.

# Instance file
sudo -u skotos -g skotos cat >/var/game/.root/usr/System/data/instance <<EndOfMessage
portbase 11000
hostname $FQDN_CLIENT
login_hostname $FQDN_LOGIN
bootmods DevSys Theatre Jonkichi Tool Generic SMTP ChatTheatre
textport 443
real_textport 11443
webport 11803
real_webport 11080
url_protocol https
access chattheatre
memory_high 128
memory_max 256
statedump_offset 600
freemote +emote
EndOfMessage
sudo -u skotos -g skotos mkdir -p /var/game/root/usr/System/data/
sudo -u skotos -g skotos cp /var/game/.root/usr/System/data/instance /var/game/root/usr/System/data/

sudo -u skotos -g skotos cat >/var/game/root/usr/ChatTheatre/data/www/profiles.js <<EndOfMessage
"use strict";
// orchil/profiles.js
var profiles = {
        "portal_chattheatre":{
                "method":   "websocket",
                "protocol": "wss",
                "web_protocol": "https",
                "server":   "$FQDN_CLIENT",
                "port":      11810,
                "woe_port":  11812,
                "http_port": 11803,
                "path":     "/chattheatre",
                "extra":    "",
                "reports":   false,
                "chars":    true,
        }
};
EndOfMessage
sudo -u skotos -g skotos cp /var/game/root/usr/ChatTheatre/data/www/profiles.js /var/game/.root/usr/ChatTheatre/data/www/

sudo -u skotos -g skotos cat >~skotos/dgd_final_setup.sh <<EndOfMessage
crontab ~/crontab.txt
rm -f /var/game/no_restart.txt  # Just in case
EndOfMessage
chmod +x ~skotos/dgd_final_setup.sh
sudo -u skotos -g skotos ~skotos/dgd_final_setup.sh
rm ~skotos/dgd_final_setup.sh

# Get set up for a fresh DGD restart from cron - let it happen again.
rm -f /var/game/skotos.database /var/game/skotos.database.old /var/game/no_restart.txt

touch ~/game_stackscript_finished_successfully.txt
