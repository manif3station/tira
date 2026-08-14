#!/usr/bin/env perl
# A release is refused only for reasons about the release.
#
# The gate failed twice on a command that ships:
#
#     card-holes: tira.epic.show -o json failed:
#         Command 'epic.show' not found in skill 'tira'.
#     card-holes: tira.ticket.list -o json failed:
#         Command 'ticket.list' not found in skill 'tira'.
#
# Both entrypoints exist and run seconds later. The evidence for why: the
# installed skill directory was rewritten at 15:36:05, inside the failing push;
# the installed copy read VERSION=1.73 while the tree was at 1.74, so the
# previous release was being installed while the next was being pushed; and two
# police processes had been running from that installed copy for four hours,
# which is the likely reason an install happens at all.
#
# The dispatcher resolves a command by looking for its entrypoint in the
# installed skill. While that directory is being written the entrypoint is
# briefly absent, and a shipped command is reported as unknown.
#
# The first occurrence was written off as transient and recorded as an
# observation. The second is why this exists: twice, on different commands, is a
# defect rather than a coincidence.
#
# It matters most here because the gate is what everything else is trusted
# through. A release refused for an unrelated reason teaches whoever is pushing
# to retry rather than to read, and a gate people retry past is not a gate.

use strict;
use warnings;

use File::Spec;
use Test::More;

use lib 'lib';
use Tira::CLI;

plan skip_all => 'python3 is not installed here' if !Tira::CLI::_program_exists('python3');

my $audit = File::Spec->catfile(qw(tools card-holes));
ok( -x $audit, 'the board audit ships and is runnable' );

open my $fh, '<', $audit or die $!;
my $source = do { local $/; <$fh> };
close $fh;

# --- it survives a command that vanished -----------------------------------------------
#
# Only this failure, and only for a moment. A command that is genuinely absent
# fails the gate as loudly as ever - what is tolerated is the window in which a
# shipped command cannot be seen.

like( $source, qr/not found in skill/,
    'the audit knows the failure that means the skill was being written' );
like( $source, qr/\bsleep\b|time\.sleep/,
    'and waits rather than failing on the instant' );
like( $source, qr/for attempt in|range\(/,
    'trying again rather than once' );

# --- while every other failure is still fatal --------------------------------------------
#
# A retry that swallowed everything would be worse than the flake: the audit
# would go quiet exactly when the board is broken.

like( $source, qr/raise SystemExit/,
    'a failure it cannot explain still stops the gate' );

# --- and a second failure is not silent ----------------------------------------------------

like( $source, qr/after \d+ attempts|tried \d+ times|attempts/i,
    'and if it never resolves, the gate says how many times it tried' );

# --- proved on the shape itself --------------------------------------------------------------
#
# A check that reads the source proves the code says the right thing; this
# proves the thing it says actually works. A command that appears only on the
# second attempt is what an install looks like from outside.

{
    my $tmp = File::Spec->catdir( File::Spec->tmpdir, "tira-vanish-$$" );
    mkdir $tmp;
    my $flaky = File::Spec->catfile( $tmp, 'd2' );
    my $marker = File::Spec->catfile( $tmp, 'seen' );

    open my $out, '>', $flaky or die $!;
    print {$out} <<"SH";
#!/usr/bin/env bash
if [ ! -f '$marker' ]; then
  touch '$marker'
  echo "Command 'ticket.list' not found in skill 'tira'." >&2
  exit 1
fi
echo '[]'
SH
    close $out;
    chmod 0755, $flaky or die $!;

    my $probe = File::Spec->catfile( $tmp, 'probe.py' );
    open my $py, '>', $probe or die $!;
    print {$py} <<'PY';
import json, subprocess, sys, time
def tira(*args):
    for attempt in range(3):
        done = subprocess.run(['d2', *args], capture_output=True, text=True)
        if done.returncode == 0:
            return json.loads(done.stdout)
        if 'not found in skill' not in done.stderr:
            break
        time.sleep(0.1)
    raise SystemExit('failed')
print(json.dumps(tira('tira.ticket.list', '-o', 'json')))
PY
    close $py;

    my $answer = `PATH='$tmp':\$PATH python3 '$probe' 2>&1`;
    is( $? >> 8, 0, 'a command that appears only on the second attempt is not fatal' );
    like( $answer, qr/\[\]/, 'and its answer is the one the command finally gave' );

    unlink $flaky, $marker, $probe;
    rmdir $tmp;
}

done_testing;

__END__

=head1 NAME

167-a-command-that-vanished-mid-install.t - a release is refused only for reasons about it

=head1 DESCRIPTION

The release gate failed twice reporting a shipped command as unknown, because
the installed skill directory was being rewritten while the gate ran: the
dispatcher resolves a command by finding its entrypoint, and during an install
the entrypoint is briefly absent.

The board audit now waits and tries again on that one failure, and on nothing
else - any other failure still stops the gate, and a command that never resolves
still fails it, saying how many times it tried.

=cut
