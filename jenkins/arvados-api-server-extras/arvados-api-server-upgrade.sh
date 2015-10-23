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

RELEASE_PATH=/var/www/arvados-api/current
SHARED_PATH=/var/www/arvados-api/shared
CONFIG_PATH=/etc/arvados/api/

echo "Assumption: $NGINX_SERVICE is configured to serve your API server URL from"
echo "            /var/www/arvados-api/current"
echo "Assumption: configuration files are in /etc/arvados/api/"
echo "Assumption: $NGINX_SERVICE and passenger run as $WWW_OWNER"
echo

echo "Copying files from $CONFIG_PATH"
cp -f $CONFIG_PATH/database.yml $RELEASE_PATH/config/database.yml
cp -f $RELEASE_PATH/config/environments/production.rb.example $RELEASE_PATH/config/environments/production.rb
cp -f $CONFIG_PATH/application.yml $RELEASE_PATH/config/application.yml
if [ -e $CONFIG_PATH/omniauth.rb ]; then
    cp -f $CONFIG_PATH/omniauth.rb $RELEASE_PATH/config/initializers/omniauth.rb
fi
echo "Done."

# Before we do anything else, make sure some directories and files are in place
if [[ ! -e $SHARED_PATH/log ]]; then mkdir -p $SHARED_PATH/log; fi
if [[ ! -e $RELEASE_PATH/tmp ]]; then mkdir -p $RELEASE_PATH/tmp; fi
if [[ ! -e $RELEASE_PATH/log ]]; then ln -s $SHARED_PATH/log $RELEASE_PATH/log; fi
if [[ ! -e $SHARED_PATH/log/production.log ]]; then touch $SHARED_PATH/log/production.log; fi

cd "$RELEASE_PATH"
export RAILS_ENV=production

echo "Making sure bundle is installed"
set +e
which bundle > /dev/null
if [[ "$?" != "0" ]]; then
  gem install bundle
fi
set -e
echo "Done."

echo "Running bundle install"
bundle install --path $SHARED_PATH/vendor_bundle
echo "Done."

echo "Precompiling assets"
# precompile assets; thankfully this does not take long
bundle exec rake assets:precompile
echo "Done."

echo "Ensuring directory and file permissions"
# Ensure correct ownership of a few files
chown "$WWW_OWNER" $RELEASE_PATH/config/environment.rb
chown "$WWW_OWNER" $RELEASE_PATH/config.ru
chown "$WWW_OWNER" $RELEASE_PATH/config/database.yml
chown "$WWW_OWNER" $RELEASE_PATH/Gemfile.lock
chown -R "$WWW_OWNER" $RELEASE_PATH/tmp
chown -R "$WWW_OWNER" $SHARED_PATH/log
chown "$WWW_OWNER" $RELEASE_PATH/db/structure.sql
chmod 644 $SHARED_PATH/log/*
chmod -R 2775 $RELEASE_PATH/tmp/cache/
echo "Done."

echo "Running sanity check"
bundle exec rake config:check
SANITY_CHECK_EXIT_CODE=$?
echo "Done."

if [[ "$SANITY_CHECK_EXIT_CODE" != "0" ]]; then
  echo "Sanity check failed, aborting. Please roll back to the previous version of the package."
  echo "The database has not been migrated yet, so reinstalling the previous version is safe."
  exit $SANITY_CHECK_EXIT_CODE
fi

echo "Checking database status"
# If we use `grep -q`, rake will write a backtrace on EPIPE.
if bundle exec rake db:migrate:status | grep '^database: ' >/dev/null; then
    echo "Starting db:migrate"
    bundle exec rake db:migrate
elif [ 0 -eq ${PIPESTATUS[0]} ]; then
    # The database exists, but the migrations table doesn't.
    echo "Setting up database"
    bundle exec rake db:structure:load db:seed
else
    echo "Error: Database is not ready to set up. Aborting." >&2
    exit 1
fi
echo "Done."

echo "Restarting nginx"
service "$NGINX_SERVICE" restart
echo "Done."
