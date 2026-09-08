#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

# tools/hooks/commit-msg refuses a commit unless the card it names is in a
# column that means "being written". It learns the column by shelling out to
# `d2 tira.$kind.show --ref $ref -o json` and reading .column off the result.
# Since TKT-659, .show answers {count, order, records: {REF: {...}}} rather
# than a flat record - so the hook's old one-liner always read column as "",
# which matches neither the idle list nor the writing list, and refused every
# commit that changed code no matter what column the card was actually in.
# Reproduced live: TKT-1014's own commit, made from 'verify', was refused
# with "TKT-1014 is in '', which claims the code is settled".
#
# Testing the real hook file directly, with a stand-in `d2` on PATH that
# returns canned JSON - not a copy of its python one-liner, which would drift
# from the fix rather than prove it.

my $tmp = tempdir( CLEANUP => 1 );

my $repo = File::Spec->catdir( $tmp, 'repo' );
mkdir $repo or die "mkdir $repo: $!";
system( 'git', '-C', $repo, 'init', '--quiet' ) == 0 or die 'git init failed';
system( 'git', '-C', $repo, 'config', 'user.email', 'a@b.c' );
system( 'git', '-C', $repo, 'config', 'user.name',  'Test' );

my $lib_file = File::Spec->catfile( $repo, 'lib', 'Widget.pm' );
mkdir File::Spec->catdir( $repo, 'lib' );
open my $fh, '>', $lib_file or die $!;
print {$fh} "package Widget;\n1;\n";
close $fh;
system( 'git', '-C', $repo, 'add', 'lib/Widget.pm' ) == 0 or die 'git add failed';

my $bin = File::Spec->catdir( $tmp, 'bin' );
mkdir $bin or die $!;
my $fake_d2 = File::Spec->catfile( $bin, 'd2' );

# The hook finds its own project root as two directories up from itself
# (tools/hooks/commit-msg -> project root), then cd's there before running
# git - so it has to live at that same relative path under the test repo,
# not be run from the real tira checkout's own tools/hooks/.
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

sub write_fake_d2 {
    my ($column) = @_;
    open my $fh, '>', $fake_d2 or die $!;
    if ( defined $column ) {
        # The envelope shape .show has answered since TKT-659 - the exact
        # shape the hook's old one-liner could not read a column out of.
        print {$fh} <<"D2";
#!/usr/bin/env bash
if [[ "\$1" == "tira.ticket.show" ]]; then
  echo '{"count":1,"order":["TKT-9001"],"records":{"TKT-9001":{"column":"$column"}}}'
  exit 0
fi
exit 1
D2
    }
    close $fh;
    chmod 0755, $fake_d2;
}

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

# --- the envelope shape, card in 'verify' - must be ALLOWED --------------

write_fake_d2('verify');
my ( $status, $out ) = run_hook('TKT-9001: fix the widget');
is( $status, 0, 'a card in verify, read through the envelope shape, is not refused' )
  or diag($out);
unlike( $out, qr/claims the code is settled/,
    'and the MSK-02 refusal text does not appear' );

# --- the envelope shape, card in 'implement' - also allowed ---------------

write_fake_d2('implement');
( $status, $out ) = run_hook('TKT-9001: fix the widget');
is( $status, 0, 'a card in implement, read through the envelope shape, is not refused' )
  or diag($out);

# --- the envelope shape, card in 'backlog' - still refused, unaffected ---

write_fake_d2('backlog');
( $status, $out ) = run_hook('TKT-9001: fix the widget');
isnt( $status, 0, 'a card genuinely in backlog is still refused' );
like( $out, qr/is in 'backlog'/, 'naming the real column, not an empty one' );

# --- the envelope shape, card in 'pending-push' - refused, MSK-02 wording -

write_fake_d2('pending-push');
( $status, $out ) = run_hook('TKT-9001: fix the widget');
isnt( $status, 0,
    'a card in pending-push, which claims the code is settled, is refused' );
like( $out, qr/claims the code is settled/, 'with the MSK-02 wording' );
unlike( $out, qr/is in ''/,
    'and the column named in the refusal is the real one, not empty' );

done_testing();

__END__

=head1 NAME

1017-a-column-read-through-an-envelope.t - commit-msg's column check
reads through the envelope .show has answered since TKT-659

=head1 DESCRIPTION

TKT-1017. tools/hooks/commit-msg read a card's column via
C<json.load(sys.stdin).get("column","")>, which found nothing once .show
started answering C<{count, order, records: {REF: {...}}}> rather than a
flat record - so every card read as column "", matching neither the idle
list nor the writing list, and every code commit was refused regardless of
the card's real column. Reproduced live: TKT-1014's own commit, made from
'verify', was refused with "TKT-1014 is in '', which claims the code is
settled". The extraction now unwraps the envelope first, the same way
every other C<.show> caller already does.

=cut
