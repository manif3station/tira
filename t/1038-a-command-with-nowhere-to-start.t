#!/usr/bin/env perl
# tira.attachment.where has no CLI entrypoint - documented, dispatched, but
# does not run.
#
# TKT-1038. TKT-766 (5.89) added attachment_where to lib/Tira.pm and
# dispatched 'attachment.where' => 'attachment_where' in lib/Tira/CLI.pm,
# and both manuals document it as shipped - but the executable file under
# skills/attachment/cli/ was never created, the same missing-file shape
# TKT-895 fixed for skills/question/cli/withdraw. 'd2 tira.attachment.where'
# answers "Command not found" because there is no entrypoint for the
# dispatcher to be invoked from at all.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $entrypoint = 'skills/attachment/cli/where';

ok( -f $entrypoint, "$entrypoint exists" )
  or diag("the bug this card is about: attachment.where is documented and dispatched, but has no entrypoint file to run at all");
ok( -x $entrypoint, "$entrypoint is executable" );

# --- and it actually dispatches to attachment_where, end to end ------------

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    project => $root, name => 'Where', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
open my $fh, '>', File::Spec->catfile( $tmp, 'file.txt' ) or die $!;
print {$fh} "content\n";
close $fh;
my $attached = $tira->attachment_add( project => $root, ref => $card->{ref},
    file => File::Spec->catfile( $tmp, 'file.txt' ), author => 'claude' );
my $sha = $attached->{sha};

SKIP: {
    skip 'entrypoint missing - cannot exercise it end to end', 2 if !-x $entrypoint;
    local $ENV{TIRA_HOME} = $root;
    my $out = `perl -Ilib $entrypoint --sha $sha -o json 2>&1`;
    unlike( $out, qr/not found/i, "d2 tira.attachment.where --sha resolves rather than answering 'not found'" )
      or diag($out);

    # Not just "didn't say not found" - the real answer, naming the card
    # this attachment actually belongs to. A wrong-but-not-'not found'
    # failure (a different refusal, empty output) would pass the check
    # above; this would not.
    like( $out, qr/\Q$card->{ref}\E/, 'and names the card this attachment is actually on' )
      or diag($out);
}

done_testing();

__END__

=head1 NAME

1038-a-command-with-nowhere-to-start.t - tira.attachment.where has a real
entrypoint to run from

=head1 WHY

TKT-1038. attachment_where was added to lib/Tira.pm and dispatched in
lib/Tira/CLI.pm, and documented as shipped since 5.89, but
skills/attachment/cli/where was never created - the same missing-entrypoint
shape TKT-895 fixed for question.withdraw.

=head1 WHAT IS ASSERTED

That skills/attachment/cli/where exists, is executable, and actually
dispatches to attachment_where when run.

=cut
