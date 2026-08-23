#!/usr/bin/env perl
# rule_suspend logged only prose - "priority-skipped on TKT-001 for 600s:
# reason text" - so the one question the log exists to answer, "which rules
# has this agent quieted, how often, why", needed a regex against a
# sentence never meant to be parsed. Each entry now also carries rule,
# seconds and reason as fields, alongside the same prose detail a person
# still reads. An entry written before this carried no fields at all and
# still reads back, rather than failing. TKT-348.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-23T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Counted', dir => $root, members => ['claude'],
    sow_prefix => 'CNS', epic_prefix => 'CNE', ticket_prefix => 'CNT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

# --- suspending a rule logs it with rule/seconds/reason as fields, prose too ------

$tira->rule_suspend( project => $root, store => $store,
    rule => 'priority-skipped', seconds => 300, reason => 'mid-gate on TKT-001' );
$tira->rule_suspend( project => $root, store => $store,
    rule => 'priority-skipped', seconds => 400, reason => 'mid-gate on TKT-002' );
$tira->rule_suspend( project => $root, store => $store,
    rule => 'card-still', seconds => 200, reason => 'writing evidence' );

my $entries = $tira->enforcement_log( project => $root, store => $store );
my @suspensions = grep { $_->{kind} eq 'rule-suspension' } @{$entries};

is( scalar @suspensions, 3, 'three suspensions logged' );

{
    my ($first) = @suspensions;
    is( $first->{fields}{rule}, 'priority-skipped', 'the rule is a field, not only inside the prose' );
    is( $first->{fields}{seconds}, 300, 'and the duration' );
    is( $first->{fields}{reason}, 'mid-gate on TKT-001', 'and the reason' );
    like( $first->{detail}, qr/priority-skipped/, 'the prose detail stays too, since a person still reads it' );
}

# --- suspensions can be counted and grouped by rule without parsing text ----------

{
    my %by_rule;
    $by_rule{ $_->{fields}{rule} }++ for @suspensions;
    is( $by_rule{'priority-skipped'}, 2, 'grouped by rule field: two priority-skipped suspensions' );
    is( $by_rule{'card-still'}, 1, 'and one card-still suspension' );
}

# --- an entry written before this shape existed still reads back -----------------

{
    open my $fh, '<', "$store/enforcement.json" or die $!;
    my $raw = do { local $/; <$fh> };
    close $fh;
    require Cpanel::JSON::XS;
    my $log = Cpanel::JSON::XS::decode_json($raw);
    # Simulate a pre-3.46 entry: no 'fields' key at all.
    delete $log->{entries}[0]{fields};
    open my $out, '>', "$store/enforcement.json" or die $!;
    print {$out} Cpanel::JSON::XS::encode_json($log);
    close $out;
}

{
    my $reread = $tira->enforcement_log( project => $root, store => $store );
    my @again = grep { $_->{kind} eq 'rule-suspension' } @{$reread};
    is( scalar @again, 3, 'the old-shaped entry still comes back, alongside the other two' );
    ok( !exists $again[0]{fields}, 'and it genuinely has no fields key, rather than a synthesized empty one' );
    like( $again[0]{detail}, qr/priority-skipped/, 'its prose is untouched' );
}

done_testing;

__END__

=head1 NAME

340-a-suspension-that-can-be-counted.t - a rule suspension carries structured fields

=head1 DESCRIPTION

C<rule_suspend> logged only prose, so the one question the enforcement log
exists to answer - which rules an agent has quieted, how often, and why -
needed a regex against a sentence never meant to be parsed. Each
C<rule-suspension> entry now also carries C<rule>, C<seconds> and
C<reason> as fields alongside the same prose C<detail> a person still
reads, so entries can be counted and grouped by rule without parsing text.
An entry written before this shape existed carries no C<fields> key at all
and still reads back correctly. TKT-348.

=cut
