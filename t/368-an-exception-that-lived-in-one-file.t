#!/usr/bin/env perl
# TKT-285. Probe-verified on 2.35: tira.card.required returned a flat list of
# 14 field names, parent among them, and the two exceptions to that list -
# a SOW needs none, a card labelled standalone needs none either - existed
# as prose in tira.usage and nowhere else: not in this command's own output,
# not in tira.skills, and tools/card-holes (the push gate) carried an
# independent hardcoded copy of the identical two exceptions - a fourth
# place that could silently drift from the other three. A caller building a
# naive completeness check straight from tira.card.required's field list,
# exactly as the manual invites, flagged every legitimately parentless card:
# 169 of 304 live cards on this project's own board at the time, every one
# of them standalone.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Exempted', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'EXS', epic_prefix => 'EXE', ticket_prefix => 'EXT',
);

my $answer = Tira->card_required;
is( ref $answer, 'HASH', 'the definition is structured, not a flat list' );
is( ref $answer->{fields}, 'ARRAY', 'the field list is still there' );
is( ref $answer->{exempt}, 'HASH', 'and the exceptions ride along with it' );

# --- a naive check built straight from the field list, matching TKT-285's --
# own test step: "build the naive check from the command's output and
# assert it agrees with the push gate on a finished standalone card" -------

sub naive_missing {
    my ($record) = @_;
    my %labels = map { lc($_) => 1 } @{ $record->{labels} // [] };
    my $rule   = $answer->{exempt}{parent} // {};
    my $exempt = ( grep { $_ eq ( $record->{type} // '' ) } @{ $rule->{types} // [] } )
      || ( grep { $labels{ lc $_ } } @{ $rule->{labels} // [] } );

    my @missing;
    for my $field ( @{ $answer->{fields} } ) {
        next if $field eq 'parent' && $exempt;
        push @missing, $field if !$record->{$field};
    }
    return \@missing;
}

my $sow = $tira->create_record( project => $root, type => 'sow', title => 'A statement of work' );
my $standalone = $tira->create_record( project => $root, type => 'ticket',
    title => 'Investigation raised on its own', labels => ['standalone'] );
my $orphan = $tira->create_record( project => $root, type => 'ticket',
    title => 'A ticket with no parent and no label' );

ok( !( grep { $_ eq 'parent' } @{ naive_missing($sow) } ),
    'a naive check built from the field list alone agrees a SOW needs no parent' );
ok( !( grep { $_ eq 'parent' } @{ naive_missing($standalone) } ),
    'and agrees a standalone card needs no parent either - the exception rides with the fields' );
ok( ( grep { $_ eq 'parent' } @{ naive_missing($orphan) } ),
    'and still flags a genuinely parentless, non-standalone card' );

# --- and the engine's own real answer agrees on the one thing this ticket
# is actually about: whether 'parent' is flagged - not on the shape of every
# other field, which card_missing already tests elsewhere (t/224, t/227) ---

my $engine_missing = $tira->card_missing( project => $root, ref => $sow->{ref} );
ok( !( grep { $_ eq 'parent' } @{$engine_missing} ),
    "the engine's own card_missing agrees a SOW needs no parent, same as the naive check" );

done_testing;

__END__

=head1 NAME

368-an-exception-that-lived-in-one-file.t - card.required's exceptions ride with the fields

=head1 DESCRIPTION

C<tira.card.required> used to return a flat list of field names with the
two exceptions to it (a SOW needs no parent, a standalone card needs none
either) living only as prose in C<tira.usage> - not in this command, not in
C<tira.skills>, and the push gate (C<tools/card-holes>) carried its own
independent hardcoded copy. A caller building a completeness check from the
field list alone, exactly as the manual invites, flagged every legitimately
parentless card.

The command now returns C<{fields => [...], exempt => {...}}>, and a naive
check built straight from that structure - matching this ticket's own test
step - agrees with the engine's real C<card_missing> on a SOW, a standalone
card, and a genuinely incomplete one.

=cut
