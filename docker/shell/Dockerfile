# Slurm node Docker container.

FROM arvados/base
MAINTAINER Ward Vandewege <ward@curoverse.com>

RUN apt-get update -q
RUN apt-get install -qy \
    python-pip python-gflags python-google-api-python-client \
    python-virtualenv libattr1-dev libfuse-dev python-dev python-llfuse fuse \
    crunchstat python-arvados-fuse cron vim supervisor openssh-server

ADD fuse.conf /etc/fuse.conf
RUN chmod 644 /etc/fuse.conf

ADD generated/superuser_token /tmp/superuser_token

RUN /usr/local/rvm/bin/rvm-exec default gem install arvados-cli arvados

# Supervisor.
ADD supervisor.conf /etc/supervisor/conf.d/arvados.conf
ADD generated/setup.sh /usr/local/bin/setup.sh

# Start the supervisor.
CMD ["/usr/bin/supervisord", "-n"]
