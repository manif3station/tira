#!/usr/bin/env perl
# A policy cannot carry a setting that does nothing.
#
# POLICY_FIELDS lists the fields a policy may carry. One of them - base - was
# read by nothing. The engine accepted it, wrote it into the policy record and
# gave it back on every read, and git shows it never had a reader in the whole
# history of the file.
#
# It is the same list that produced the opposite fault. read_age was accepted by
# the CLI, validated by the engine and then silently dropped, because it was NOT
# in this list. One list decides what a policy carries, and it has now been
# wrong in both directions - which is why removing base is only half of this.
#
# The half that lasts is the check below: every field the list admits has to be
# read somewhere in the engine. Written the same way as the guard on declared
# refusals, and for the same reason - the fault is not that base was wrong, it
# is that nothing would have said so.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T05:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Fields', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'FDS', epic_prefix => 'FDE', ticket_prefix => 'FDT',
);

# --- the setting that did nothing -----------------------------------------------
#
# It is no longer a field a policy carries, so setting it writes nothing and
# reads back as absent - where before it was stored and handed back on every
# read, beside the fields that work.

my $made = $tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'backlog', base => 'anything at all', action => 'bridge-reminder' );
ok( !exists $made->{base}, 'a policy no longer carries a field nothing reads' );
my ($stored_back) = @{ $tira->policy_list( project => $root ) };
ok( !exists $stored_back->{base}, 'and reading it back does not produce one either' );

# The engine takes the caller's whole request by design - the CLI hands it every
# parsed option - so it cannot refuse every name it does not store without
# refusing half the commands. The contract a person meets is the CLI's, and that
# does refuse it outright.
{
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => 'policy.add', tira => $tira,
            argv => [ '--project', $root, '--rule', 'card-full-details',
                '--enter', 'done', '--base', 'anything', '--action', 'bridge-reminder' ] );
    };
    isnt( $status, 0, 'and typing it is refused outright, which is where a person meets it' );
    like( $err, qr/base/, 'naming the option that does not exist' );
}

# --- while the fields that work still work ----------------------------------------
#
# The risk in removing a name from a list is removing one that mattered. Each of
# these carries a decision the rule beside it acts on.

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'card-metrics',
    enter => 'done', require => 'due_date', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'wip-limit',
    column => 'implement', max => '3', action => 'bridge-reminder' );

my %stored = map { $_->{rule} => $_ } @{ $tira->policy_list( project => $root ) };
is( $stored{'card-full-details'}{enter}, 'implement', 'a column to enter is still carried' );
is( $stored{'card-metrics'}{require},    'due_date',  'what a card must have is still carried' );
is( $stored{'wip-limit'}{max},           '3',         'and a limit is still carried' );

# --- and the list cannot grow another one -----------------------------------------
#
# The half that lasts. base was wrong for the whole life of the file and nothing
# said so; what is checked here is not base but the shape that hid it.

{
    open my $fh, '<', File::Spec->catfile(qw(lib Tira.pm)) or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;

    my ($list) = $source =~ /my \@POLICY_FIELDS = qw\(([^)]*)\)/s;
    my @fields = split ' ', $list;
    ok( scalar @fields, 'the engine declares which fields a policy may carry' );

    my @unread;
    for my $field (@fields) {
        my $q = quotemeta $field;

        # Read as a policy's own field, or taken as a named argument by the
        # engine when the policy is being made. Either is somebody acting on it;
        # appearing in the list is not.
        push @unread, $field
          if $source !~ /\$policy->\{$q\}/
          && $source !~ /\$args\{$q\}/;
    }
    is_deeply( \@unread, [],
        'and every one of them is read somewhere, so none of them is a setting that does nothing' );
}

done_testing;

__END__

=head1 NAME

148-a-field-that-never-meant-anything.t - a policy cannot carry a setting that does nothing

=head1 DESCRIPTION

C<base> was listed among the fields a policy may carry and was read by nothing,
for the whole life of the file. The engine accepted it, stored it and returned
it, so a caller setting it had every reason to believe it meant something.

The same list produced the opposite fault when C<read_age> was accepted,
validated and then dropped for being absent from it. So this removes C<base> and
adds the check that would have caught either: every field the list admits must
be read somewhere in the engine.

=cut
