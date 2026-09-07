#!/usr/bin/env perl
# TKT-635. record_update and create_record accept %args wholesale and read
# only the keys they know - anything else is silently ignored. A caller who
# misspells a composed field (required_exempt as exempt_required, say) gets
# no error and no effect: the card is written back exactly as it was, with
# no sign the argument was ever seen.
#
# THE FIX IS NARROW BY DESIGN, matching the acceptance criteria on the card:
# only a key that RESEMBLES a real field (small edit distance) is refused.
# Both engine methods are called internally with a shared %option hash that
# carries every CLI flag ever declared (Tira::CLI.pm's single big spec
# autovivifies every $option{...} slot it names, whether or not that flag
# was passed) - so record_update/create_record already see dozens of
# entirely unrelated, always-present, usually-undef keys on every real call.
# Refusing every key the method does not itself use would break that
# call shape immediately. Refusing only a NEAR MISS - close in spelling to a
# real field, and therefore almost certainly a typo of one - catches the
# actual failure (TKT-635's own: exempt_required for required_exempt)
# without touching a legitimate foreign key such as `refs` or `columns`.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-09-07T22:00:00Z'} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Spellcheck', dir => $root, columns => ['backlog, done'],
    members => ['claude'], sow_prefix => 'SPS', epic_prefix => 'SPE', ticket_prefix => 'SPT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'seed' );

# --- the exact failure the card was filed about ------------------------------

{
    eval {
        $tira->record_update(
            project => $root, ref => $card->{ref}, author => 'claude',
            exempt_required => ['some item'], exempt_reason => ['because'],
        );
    };
    like( $@, qr/exempt_required/,
        'a misspelled required_exempt is refused and named' );
    like( $@, qr/required_exempt/,
        'and the refusal suggests the field it was probably meant to be' );

    my ( undef, $record ) = $tira->_record_data( project => $root, ref => $card->{ref} );
    is_deeply( $record->{required_exempt}, [],
        'and nothing was silently written - the card is untouched' );
}

# --- the correctly spelled call still works exactly as before ---------------

{
    my $updated = $tira->record_update(
        project => $root, ref => $card->{ref}, author => 'claude',
        required_exempt => ['some item'], exempt_reason => ['because'],
    );
    is( scalar @{ $updated->{required_exempt} }, 1,
        'the correctly spelled call is unaffected' );
}

# --- create_record gets the same treatment -----------------------------------

{
    eval {
        $tira->create_record(
            project => $root, type => 'ticket', titel => 'a typo in the field itself',
        );
    };
    like( $@, qr/titel/, 'create_record refuses a near-miss key too' );
    like( $@, qr/title/, 'and names the field it was probably meant to be' );
}

# --- a key that is unrelated to any real field is left alone ----------------
#
# This is the other half of the acceptance criteria: "internal calls that
# pass %args wholesale between helpers keep working - the check does not
# fire on keys a method legitimately ignores." Tira::CLI.pm's shared
# %option hash carries dozens of these on every real record.update/
# record.create call (e.g. `refs`, used only by record.show); none of them
# resemble a real field closely enough to be a plausible typo.

{
    my $updated = $tira->record_update(
        project => $root, ref => $card->{ref}, author => 'claude',
        title => 'still fine', refs => ['TKT-999'], dashboard_host => 'x',
    );
    is( $updated->{title}, 'still fine',
        'a call carrying unrelated, legitimately-ignored keys still succeeds' );
}

done_testing();

__END__

=head1 NAME

635-an-argument-nobody-asked-for.t - a misspelled record_update/create_record
key is refused and named, an unrelated one is not

=head1 DESCRIPTION

TKT-635. C<record_update> and C<create_record> read C<%args> for the keys
they know and silently ignore everything else, so a caller who misspells a
composed field name gets no error and no effect - exactly the failure a
wrong C<--exempt-required> spelling produced when called directly against
the engine. Both methods now refuse a key that is a near miss (small edit
distance) of a real field, naming it and suggesting the field it probably
meant, while a key that does not resemble any real field - the dozens
`Tira::CLI.pm`'s shared option hash always carries, whether or not that
flag was passed on the command line this time - is left alone exactly as
before.

=cut
