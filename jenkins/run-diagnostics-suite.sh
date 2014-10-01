#!/bin/bash

EXITCODE=0

# Sanity check
if ! [[ -n "$WORKSPACE" ]]; then
  echo "WORKSPACE environment variable not set"
  exit 1
fi

title () {
    txt="********** $1 **********"
    printf "\n%*s%s\n\n" $((($COLUMNS-${#txt})/2)) "" "$txt"
}

timer_reset() {
    t0=$SECONDS
}

timer() {
    echo -n "$(($SECONDS - $t0))s"
}

source /etc/profile.d/rvm.sh
echo $WORKSPACE

title "Starting diagnostics"
timer_reset

cd $WORKSPACE

cp -f /home/jenkins/diagnostics/arvados-workbench/application.yml $WORKSPACE/apps/workbench/config/

cd $WORKSPACE/apps/workbench

HOME="$GEMHOME" bundle install --no-deployment

if [[ ! -d tmp ]]; then
  mkdir tmp
fi

RAILS_ENV=diagnostics bundle exec rake TEST=test/diagnostics/pipeline_test.rb

ECODE=$?

if [[ "$ECODE" != "0" ]]; then
  title "!!!!!! DIAGNOSTICS FAILED (`timer`) !!!!!!"
  EXITCODE=$(($EXITCODE + $ECODE))
  exit $EXITCODE
fi

title "Diagnostics complete (`timer`)"

exit $EXITCODE
