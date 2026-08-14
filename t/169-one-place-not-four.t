#!/usr/bin/env perl
# The gate survives an install in every step, not the one that failed first.
#
# TKT-168 made the board audit survive the skill being rewritten underneath it.
# The very next push failed the same way one step earlier:
#
#     pre-push: backing up the board
#     Command 'project.show' not found in skill 'tira'.
#     pre-push: the board backup failed
#
# tools/board-backup makes four d2 calls and had none of the protection that had
# just been added to tools/card-holes - which runs after it, in the same gate,
# against the same installed skill.
#
# That is this project's own recurring fault, committed an hour after writing
# about it: the fix went where the failure happened to appear rather than where
# the class lives. Running the backup by hand immediately afterwards wrote 179
# records, which is the same signature as the two audit failures before it.
#
# board-backup is shell and card-holes is python, so they cannot share a
# function. They share a script: one small caller that runs a d2 call with the
# wait, so a tool added tomorrow inherits it instead of learning this the way
# board-backup just did.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira::CLI;

my $caller = File::Spec->catfile(qw(tools tira-call));
ok( -x $caller, 'there is one caller the gate tools share' );

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

# --- both tools go through it -----------------------------------------------------
#
# The whole point. Two languages, one decision - written once rather than twice
# in dialects that can drift.

my $backup = slurp('tools/board-backup');
like( $backup, qr/tira-call/, 'the board backup calls through it' );
unlike( $backup, qr/^\s*d2 tira\./m,
    'and no longer calls d2 directly, which is what left it unprotected' );

my $holes = slurp('tools/card-holes');
like( $holes, qr/tira-call/, 'and so does the board audit' );

# --- it waits on the one failure that means an install ------------------------------

my $shared = slurp('tools/tira-call');
like( $shared, qr/not found in skill/, 'it knows the failure that means the skill was being written' );
like( $shared, qr/sleep/, 'and waits rather than failing on the instant' );
like( $shared, qr/attempts/i, 'and says how many times it tried if it never resolves' );

# --- proved by running it, against a command that vanishes once -----------------------

my $tmp = tempdir( CLEANUP => 1 );
my $marker = File::Spec->catfile( $tmp, 'seen' );
my $stub = File::Spec->catfile( $tmp, 'd2' );
open my $out, '>', $stub or die $!;
print {$out} <<"SH";
#!/usr/bin/env bash
if [ ! -f '$marker' ]; then
  touch '$marker'
  echo "Command 'project.show' not found in skill 'tira'." >&2
  exit 1
fi
echo '{"name":"a board"}'
SH
close $out;
chmod 0755, $stub or die $!;

my $answer = `PATH='$tmp':\$PATH '@{[ File::Spec->rel2abs($caller) ]}' tira.project.show -o json 2>&1`;
is( $? >> 8, 0, 'a command that appears only on the second attempt is not fatal' );
like( $answer, qr/a board/, 'and its answer is the one the command finally gave' );

# --- while a genuine failure is still fatal --------------------------------------------
#
# A caller that retried everything would make the gate go quiet exactly when
# something is really wrong, which is worse than the flake it was written for.

my $angry = File::Spec->catfile( $tmp, 'd2' );
open my $bad, '>', $angry or die $!;
print {$bad} "#!/usr/bin/env bash\necho 'the board is on fire' >&2\nexit 1\n";
close $bad;
chmod 0755, $angry or die $!;

my $refused = `PATH='$tmp':\$PATH '@{[ File::Spec->rel2abs($caller) ]}' tira.project.show -o json 2>&1`;
isnt( $? >> 8, 0, 'a failure it cannot explain still stops the gate' );
like( $refused, qr/on fire/, 'and passes on what the command actually said' );
unlike( $refused, qr/attempts/i, 'without pretending it tried repeatedly' );

done_testing;

__END__

=head1 NAME

169-one-place-not-four.t - the gate survives an install in every step

=head1 DESCRIPTION

The board audit was hardened against the skill being reinstalled mid-gate and
the next push failed the same way in the backup step, which makes four C<d2>
calls and had none of it. The fix had gone where the failure appeared rather
than where the class lives.

Both tools now call through one small script that waits on that single failure
and no other. Any other failure stops the gate at once and is passed on
verbatim; a call that never resolves fails saying how many attempts were made.

=cut
