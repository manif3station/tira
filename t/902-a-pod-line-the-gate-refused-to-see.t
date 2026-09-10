#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

# tools/hooks/commit-msg's code_changed check counts every staged file under
# lib/, t/, cli/, skills/ or tools/ as a code change, and refuses it unless
# the card is in tests-red, implement or verify. The document column's own
# entry required action says "Add that to all the POD in Perl scripts and
# Perl modules" - and Perl modules live in lib/, so the gate refuses the very
# edit that column instructs. Hit live on TKT-892, 2026-09-04: a POD-only
# addition to lib/Tira/Job.pm was refused with "TKT-892 is in document, which
# claims the code is settled - but this commit changes code."
#
# TKT-902's fix reads the file itself rather than trusting the path or the
# commit message's own claim: a lib/*.pm change is exempted from
# code_changed only when its whole non-POD residual (every non-blank line
# outside a =pod/=headN...=cut block or everything after __END__/__DATA__,
# the same shape this project's own .pm/.t files already use) is IDENTICAL
# between HEAD and the staged version - not merely "does every touched line
# fall inside a POD region", which a first draft used and a Codex review
# broke: inserting __END__ (or removing a =cut) touches no line of live
# code, yet can hide code that follows from Perl's parser, or extend a POD
# block to swallow code the diff never touched at all. Comparing the whole
# residual catches that: any code newly hidden or revealed is present in one
# residual and absent from the other. A commit that also touches one real
# line of Perl is still refused exactly as before, whatever the message
# claims.
#
# Testing the real hook file directly against a throwaway git repo, the same
# pattern t/1017 uses - not a copy of its bash, which would drift from the
# fix rather than prove it.

my $tmp  = tempdir( CLEANUP => 1 );
my $repo = File::Spec->catdir( $tmp, 'repo' );
mkdir $repo or die "mkdir $repo: $!";
system( 'git', '-C', $repo, 'init', '--quiet' ) == 0 or die 'git init failed';
system( 'git', '-C', $repo, 'config', 'user.email', 'a@b.c' );
system( 'git', '-C', $repo, 'config', 'user.name',  'Test' );

my $real_hook = File::Spec->rel2abs(
    File::Spec->catfile( 'tools', 'hooks', 'commit-msg' ) );
mkdir File::Spec->catdir( $repo, 'tools' );
mkdir File::Spec->catdir( $repo, 'tools', 'hooks' );
my $hook = File::Spec->catfile( $repo, 'tools', 'hooks', 'commit-msg' );
{
    open my $in,  '<', $real_hook or die $!;
    open my $out, '>', $hook      or die $!;
    local $/;
    print {$out} <$in>;
}
chmod 0755, $hook;

my $bin      = File::Spec->catdir( $tmp, 'bin' );
my $fake_d2  = File::Spec->catfile( $bin, 'd2' );
mkdir $bin or die $!;

sub write_fake_d2 {
    my ($column) = @_;
    open my $fh, '>', $fake_d2 or die $!;
    print {$fh} <<"D2";
#!/usr/bin/env bash
if [[ "\$1" == "tira.ticket.show" ]]; then
  echo '{"count":1,"order":["TKT-9002"],"records":{"TKT-9002":{"column":"$column"}}}'
  exit 0
fi
exit 1
D2
    close $fh;
    chmod 0755, $fake_d2;
}
write_fake_d2('document');

sub run_hook {
    my ($subject) = @_;
    my $msg_file = File::Spec->catfile( $tmp, 'msg.txt' );
    open my $mfh, '>', $msg_file or die $!;
    print {$mfh} "$subject\n";
    close $mfh;

    local $ENV{PATH} = "$bin:$ENV{PATH}";
    my $out = `cd '$repo' && '$hook' '$msg_file' 2>&1`;
    return ( $?, $out );
}

sub write_and_stage {
    my ( $relpath, $content ) = @_;
    my @parts = split m{/}, $relpath;
    my $name  = pop @parts;
    my $dir   = $repo;
    for my $part (@parts) {
        $dir = File::Spec->catdir( $dir, $part );
        mkdir $dir if !-d $dir;
    }
    my $path = File::Spec->catfile( $dir, $name );
    open my $fh, '>', $path or die $!;
    print {$fh} $content;
    close $fh;
    system( 'git', '-C', $repo, 'add', $relpath ) == 0 or die "git add $relpath failed";
}

# --- a real module, committed first so later edits are DIFFS, not new files -

write_and_stage( 'lib/Widget.pm', <<'PM' );
package Widget;
sub new { return bless {}, shift }
1;
PM
system( 'git', '-C', $repo, 'commit', '-q', '-m', 'TKT-9002: seed Widget.pm' ) == 0
  or die 'seed commit failed';

# --- adding POD only, from 'document' - must be ACCEPTED --------------------

write_and_stage( 'lib/Widget.pm', <<'PM' );
package Widget;
sub new { return bless {}, shift }
1;

__END__

=head1 NAME

Widget - a thing

=cut
PM
my ( $status, $out ) = run_hook('TKT-9002: document Widget');
is( $status, 0, 'a POD-only lib/ addition is accepted from the document column' )
  or diag($out);
unlike( $out, qr/claims the code is settled/,
    'and the code-changed refusal text does not appear' );

# --- the same file, now with ONE real line of Perl added too - must REFUSE -

system( 'git', '-C', $repo, 'commit', '-q', '-m', 'TKT-9002: pod only, checkpoint' ) == 0
  or die 'checkpoint commit failed';
write_and_stage( 'lib/Widget.pm', <<'PM' );
package Widget;
sub new { return bless {}, shift }
sub extra { return 1 }
1;

__END__

=head1 NAME

Widget - a thing

=cut
PM
( $status, $out ) = run_hook('TKT-9002: document Widget, again');
isnt( $status, 0, 'a mixed commit (POD plus one real line) is still refused from document' );
like( $out, qr/claims the code is settled/,
    'with the same refusal text as an ordinary code change' );

# --- a lying message does not help - the diff is read, not the claim -------

( $status, $out ) = run_hook('TKT-9002: POD only, I promise');
isnt( $status, 0,
    'a commit message that CLAIMS pod-only is still refused when the diff says otherwise' );

# --- inserting __END__ ahead of live code hides that code from Perl's ------
# --- parser without touching a line of it - the diff line added really is
# --- POD-shaped, but the change is not POD-only in substance -------------

system( 'git', '-C', $repo, 'reset', '--hard', 'HEAD' ) == 0 or die 'reset failed';
write_and_stage( 'lib/Widget.pm', <<'PM' );
package Widget;
sub new { return bless {}, shift }
sub still_reachable { return 42 }
1;
PM
system( 'git', '-C', $repo, 'commit', '-q', '-m', 'TKT-9002: seed a reachable sub' ) == 0
  or die 'seed commit failed';

write_and_stage( 'lib/Widget.pm', <<'PM' );
package Widget;
sub new { return bless {}, shift }
1;

__END__

sub still_reachable { return 42 }
PM
( $status, $out ) = run_hook('TKT-9002: just adding a marker, honest');
isnt( $status, 0,
    'inserting __END__ ahead of a live sub is refused - it hides code from Perl without the diff touching a line of it' );
like( $out, qr/claims the code is settled/,
    'with the same refusal text, since this is a real change in what the module does' );

# --- backlog and pending-push still refuse a POD-only commit outright ------

system( 'git', '-C', $repo, 'reset', '--hard', 'HEAD' ) == 0 or die 'reset failed';
write_and_stage( 'lib/Widget.pm', <<'PM' );
package Widget;
sub new { return bless {}, shift }

__END__

=head1 NAME

Widget - a thing, now with an extra POD paragraph

=cut
PM
write_fake_d2('backlog');
( $status, $out ) = run_hook('TKT-9002: document Widget from backlog');
isnt( $status, 0, 'a POD-only commit is still refused from backlog - that column is not "being written" at all' );

write_fake_d2('pending-push');
( $status, $out ) = run_hook('TKT-9002: document Widget from pending-push');
isnt( $status, 0, 'and from pending-push - same reasoning, code is meant to be settled there' );

done_testing();

__END__

=head1 NAME

t/902-a-pod-line-the-gate-refused-to-see.t - the commit gate tells POD-only lib/ changes from real code

=head1 WHY

TKT-902: the document column's own required action asks an agent to add POD
to Perl modules, which live in lib/ - and the commit gate's code_changed
check refused any staged lib/ file unconditionally, refusing the very edit
the column instructs. Hit live on TKT-892, 2026-09-04.

=head1 WHAT IS ASSERTED

A POD-only lib/*.pm change is accepted from 'document'; the same file with
one real line of Perl added is still refused, with or without a commit
message that claims otherwise; inserting __END__ ahead of a live sub (which
touches no line of that sub, yet hides it from Perl) is refused too, since
the fix compares the whole non-POD residual rather than only the changed
lines; backlog and pending-push still refuse a POD-only commit outright,
since those columns claim no work is happening.

=head1 KNOWN LIMITATION

The POD scanner is line-based, the same as most POD tooling (Pod::Simple
included) - it does not track Perl's own lexical state, so a heredoc or
quoted string containing a line that merely LOOKS like a POD directive
(starts with C<=word> at column zero) is misread as real POD, and code
after it could change undetected by this check alone. Disclosed rather than
chased: closing it needs a real Perl tokenizer, which this gate - a
development-process safety net for a single trusted agent's own board, not
a defense against an adversarial committer - does not have and is not sized
to acquire.

=cut
