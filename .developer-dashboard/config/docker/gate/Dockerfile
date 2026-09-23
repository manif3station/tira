FROM developer-dashboard:latest

WORKDIR /tmp

COPY cpanfile /tmp/cpanfile

RUN cpanm --notest --installdeps .

# TKT-1073, self-caught: the old docker-compose.testing.yml's own Dockerfile
# installed Devel::Cover explicitly (it is a test-only tool, deliberately not
# in cpanfile's own runtime deps) - this new Dockerfile did not, so the
# mandatory 100% statement+subroutine coverage gate could not run at all
# under this mechanism (`perl -MDevel::Cover ...` failed with "Can't locate
# Devel/Cover.pm"). Installed the same way the old Dockerfile did.
RUN cpanm --notest Devel::Cover Test::More

COPY . /root/.developer-dashboard/skills/tira

# TKT-1073, self-caught: the COPY above also brought in this repo's own
# .tira - its live production board - baking a static snapshot of it into
# every test image at this path, since nothing excluded it. Nothing writes
# back to the real board through that copy (frozen at build time, not a
# live mount), but shipping it into the directory doc-examples/prove
# actually run from breaks t/172's own "no board created in the directory
# examples ran from" check, since one is already sitting there before any
# example runs. Removed here; the ADD below puts its own (still real,
# deliberately provided) copy at /test-project/.tira, a separate location
# this fix does not touch.
RUN rm -rf /root/.developer-dashboard/skills/tira/.tira

WORKDIR /root/.developer-dashboard/skills/tira

ADD .tira /test-project/.tira

WORKDIR /test-project

# TKT-1073, self-caught: compose's own `init: true` (docker-init/tini as PID 1)
# made every fork-based test (t/394, a real onboarding server started/stopped
# via a forked watchdog) die reliably a few seconds in - confirmed 8/8
# failures with init: true present, versus reliable passes with it removed.
# Plain "sleep infinity" as PID 1 (no init: true) fixes the test but reaps
# nothing - Michael's own correction, 2026-09-21: that leaves reparented
# zombies to accumulate for the whole life of one container session
# (confirmed live: 2 defunct perl processes left behind by a single t/394
# run with no reaper present at all).
#
# Isolated by systematic A/B testing (each variant run 3x with a full
# container restart between attempts, to rule out one failure cascading into
# false failures for the rest): the actual trigger is installing a CUSTOM
# $SIG{TERM} handler on PID 1, not reaping itself. A `waitpid(-1, WNOHANG)`
# loop with NO custom signal handler passed 3/3 restarts and reaped a real
# zombie cleanly in the same run; the identical loop WITH `$SIG{TERM} =
# sub { exit 0 }` added failed 3/3. The exact kernel/docker mechanism this
# traces to was not conclusively identified (ptrace access to inspect it
# directly was refused by the host), but the correlation was deterministic
# and reproduced independently for tini itself (`init: true`) and this
# script's own earlier signal-handling variant alike.
#
# Known, accepted cost: `docker compose down`/`docker stop` now take the
# full ~10s default grace period before force-killing PID 1, since Perl's
# `sleep()` builtin does not respond to SIGTERM as promptly as a plain
# coreutils `sleep` binary would (confirmed: even a bare `perl -e "sleep
# 999999"` with no custom handler and no reaping shows the same ~10s stop
# time) - a signal-responsiveness quirk of Perl's own sleep implementation,
# unrelated to this fix. This only slows teardown between test sessions,
# never affects a test's own correctness, and was judged not worth chasing
# further given the fix's actual purpose (reap zombies without breaking
# fork tests) is already satisfied.
CMD ["perl", "-e", "while(1){ 1 while waitpid(-1,1)>0; sleep 1 }"]
