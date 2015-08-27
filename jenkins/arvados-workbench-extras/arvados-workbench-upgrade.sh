#!/bin/bash

set -e

if [ -e /etc/redhat-release ]; then
    WWW_OWNER=nginx:nginx
else
    # Assume we're on a Debian-based system for now.
    WWW_OWNER=www-data:www-data
fi

NGINX_SERVICE=${NGINX_SERVICE:-$(service --status-all 2>/dev/null \
    | grep -Eo '\bnginx[^[:space:]]*' || true)}
if [ -z "$NGINX_SERVICE" ]; then
    cat >&2 <<EOF
Error: nginx service not found. Aborting.
Set NGINX_SERVICE to the name of the service hosting the Rails server.
EOF
    exit 1
elif [ "$NGINX_SERVICE" != "$(echo "$NGINX_SERVICE" | head -n 1)" ]; then
    cat >&2 <<EOF
Error: multiple nginx services found. Aborting.
Set NGINX_SERVICE to the name of the service hosting the Rails server.
EOF
    exit 1
fi

RELEASE_PATH=/var/www/arvados-workbench/current
SHARED_PATH=/var/www/arvados-workbench/shared
CONFIG_PATH=/etc/arvados/workbench/

echo "Assumption: $NGINX_SERVICE is configured to serve your workbench URL from "
echo "            /var/www/arvados-workbench/current"
echo "Assumption: configuration files are in /etc/arvados/workbench/"
echo "Assumption: $NGINX_SERVICE and passenger run as $WWW_OWNER"
echo

echo "Copying files from $CONFIG_PATH"
cp -f $CONFIG_PATH/application.yml $RELEASE_PATH/config/application.yml
cp -f $RELEASE_PATH/config/environments/production.rb.example $RELEASE_PATH/config/environments/production.rb
echo "Done."

# Before we do anything else, make sure some directories and files are in place
if [[ ! -e $SHARED_PATH/log ]]; then mkdir -p $SHARED_PATH/log; fi
if [[ ! -e $RELEASE_PATH/tmp ]]; then mkdir -p $RELEASE_PATH/tmp; fi
if [[ ! -e $RELEASE_PATH/log ]]; then ln -s $SHARED_PATH/log $RELEASE_PATH/log; fi
if [[ ! -e $SHARED_PATH/log/production.log ]]; then touch $SHARED_PATH/log/production.log; fi

echo "Running bundle install"
(cd $RELEASE_PATH && RAILS_ENV=production bundle install --path $SHARED_PATH/vendor_bundle)
echo "Done."

# We do not need to precompile assets, they are already part of the package.

echo "Ensuring directory and file permissions"
chown "$WWW_OWNER" $RELEASE_PATH/config/environment.rb
chown "$WWW_OWNER" $RELEASE_PATH/config.ru
chown "$WWW_OWNER" $RELEASE_PATH/config/database.yml
chown "$WWW_OWNER" $RELEASE_PATH/Gemfile.lock
chown -R "$WWW_OWNER" $RELEASE_PATH/tmp
chown -R "$WWW_OWNER" $SHARED_PATH/log
chown "$WWW_OWNER" $RELEASE_PATH/db/schema.rb
chmod 644 $SHARED_PATH/log/*
echo "Done."

echo "Running sanity check"
(cd $RELEASE_PATH && RAILS_ENV=production bundle exec rake config:check)
SANITY_CHECK_EXIT_CODE=$?
echo "Done."

if [[ "$SANITY_CHECK_EXIT_CODE" != "0" ]]; then
  echo "Sanity check failed, aborting. Please roll back to the previous version of the package."
  exit $SANITY_CHECK_EXIT_CODE
fi

# We do not need to run db:migrate because Workbench is stateless

echo "Restarting nginx"
service "$NGINX_SERVICE" restart
echo "Done."

