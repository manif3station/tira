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
#
# TKT-364: three lists decide what a policy carries - POLICY_FIELDS (12),
# POLICY_SCOPE (3), POLICY_ROLE_FIELDS (3) - and the guard below used to
# read only the first from source. The other six are stored (the engine
# loops over all three when writing and reading a policy) and were checked
# by nothing, so the exact failure base was could still happen to any of
# them. Widened to all three, accepting a name read either by the original
# literal $policy->{name}/$args{name} match, or by a for-loop over the
# field's own list whose body reads $policy->{$var} back through the loop
# variable - the role fields' own read is exactly that shape, and a purely
# textual widening would have reported all three unread against working
# code.

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
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'policy.add', tira => $tira,
            argv => [ '--rule', 'card-full-details',
                '--enter', 'done', '--base', 'anything', '--action', 'bridge-reminder' ] ) };
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

# Three lists decide what a policy carries - POLICY_FIELDS, POLICY_SCOPE,
# POLICY_ROLE_FIELDS - and the guard above only ever read the first from
# source. The other six are stored (the engine loops over all three when
# writing and reading a policy) and were checked by nothing, so the exact
# failure this file exists for could still happen to any of them. TKT-364.
#
# A literal $policy->{name} / $args{name} match cannot be copied as-is to
# the other two lists: the role fields are read through a loop variable
# ('for my $field ( ..., @POLICY_ROLE_FIELDS ) { ... $policy->{$field} ... }'),
# so a purely textual match against each field's own name reports all three
# role fields unread - a false positive against working code. Accepting a
# name read through the list itself, not only by literal subscript, is what
# makes this true rather than merely stricter.
sub unread_policy_fields {
    my ($source) = @_;
    my %list_source = map {
        my ($members) = $source =~ /my \@$_ = qw\(([^)]*)\)/s;
        $_ => [ split ' ', $members // '' ];
    } qw(POLICY_FIELDS POLICY_SCOPE POLICY_ROLE_FIELDS);

    # A list is read via a loop when a for-loop's own parenthesised list
    # names it and the loop variable is then used to read BACK from a
    # stored policy ($policy->{$var}) - the behavioral-use side. A loop
    # that only writes $args{$var} into a policy under construction does
    # not count: every field is swept through exactly that generic copy
    # when a policy is built, which is precisely how 'base' hid in the
    # first place, so appearing in a write-loop is not being acted on -
    # the same distinction the literal check draws by requiring the arrow
    # form to mean genuine engine behavior.
    my %read_via_loop;
    while ( $source =~ /for my \$(\w+)\s*\(([^)]*)\)\s*\{/g ) {
        my ( $var, $inside, $body_start ) = ( $1, $2, pos($source) );

        # A window after the loop opens, not the whole file: two loops can
        # reuse the same variable name ($field, here, more than once), and
        # a read anywhere in the file for that name would otherwise credit
        # every loop sharing it, including ones that never read anything.
        my $body = substr( $source, $body_start, 800 );

        for my $list ( keys %list_source ) {

            # A word boundary, not a bare substring match - POLICY_SCOPE is
            # a prefix of the unrelated POLICY_SCOPE_FIELDS, which would
            # otherwise count a loop over the combined list as reading the
            # narrower one it merely starts with.
            next if $inside !~ /\@\Q$list\E\b/;
            $read_via_loop{$list} = 1 if $body =~ /\$policy->\{\$\Q$var\E\}/;
        }
    }

    my @unread;
    for my $list ( sort keys %list_source ) {
        for my $field ( @{ $list_source{$list} } ) {
            next if $read_via_loop{$list};
            my $q = quotemeta $field;
            push @unread, $field
              if $source !~ /\$policy->\{$q\}/ && $source !~ /\$args\{$q\}/;
        }
    }
    return sort @unread;
}

{
    open my $fh, '<', File::Spec->catfile(qw(lib Tira.pm)) or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;

    my @all_fields = map {
        my ($members) = $source =~ /my \@$_ = qw\(([^)]*)\)/s;
        split ' ', $members // '';
    } qw(POLICY_FIELDS POLICY_SCOPE POLICY_ROLE_FIELDS);
    is( scalar @all_fields, 18, 'all three lists together declare 18 names a policy may carry' );

    is_deeply( [ unread_policy_fields($source) ], [],
        'and every one of the 18 is read somewhere, so none of them is a setting that does nothing' );
}

# --- proved by breaking it: an unread name in either of the other two lists ----

{
    ( my $with_unread_scope = do {
        open my $fh, '<', File::Spec->catfile(qw(lib Tira.pm)) or die $!;
        local $/;
        <$fh>;
    } ) =~ s/(my \@POLICY_SCOPE = qw\([^)]*)\)/$1 phantom_scope_field)/;
    is_deeply( [ unread_policy_fields($with_unread_scope) ], ['phantom_scope_field'],
        'a name added to POLICY_SCOPE that nothing reads is caught' );
}

{
    ( my $with_unread_role = do {
        open my $fh, '<', File::Spec->catfile(qw(lib Tira.pm)) or die $!;
        local $/;
        <$fh>;
    } ) =~ s/(my \@POLICY_ROLE_FIELDS = qw\([^)]*)\)/$1 phantom_role_field)/;

    # Adding a name to POLICY_ROLE_FIELDS makes the WHOLE list "unread" by
    # this guard's own loop-based rule, once one member is not - which is
    # correct: 'for my $field (@POLICY_ROLE_FIELDS) { ... $policy->{$field}
    # ... }' (role_remove's own guard against a policy naming a role that
    # stops existing) reads every member of @POLICY_ROLE_FIELDS by
    # construction, phantom_role_field included, so a phantom addition does
    # not actually break that loop's own guarantee. What proves the guard
    # still catches something is the DIFFERENT case above (POLICY_SCOPE,
    # read only by literal subscript) and the case below (the same loop,
    # removed outright).
    ( my $with_no_loop_at_all = $with_unread_role ) =~
      s/for my \$field \(\@POLICY_ROLE_FIELDS\)/for my \$field ()/;
    my @caught = unread_policy_fields($with_no_loop_at_all);
    ok( ( grep { $_ eq 'phantom_role_field' } @caught ),
        'and with the reading loop itself removed, every role field - including the phantom one - is correctly reported unread' );
    ok( ( grep { $_ eq 'column_role' } @caught ),
        'a genuinely-read role field is reported unread too, once the only thing that read it is gone - '
          . 'proving this is not a guard that only ever finds what was already known missing' );
}

# --- and the other direction: the widened guard does not false-positive -------
#
# column_role is read only through role_remove's 'for my $field
# (@POLICY_ROLE_FIELDS) { ... $policy->{$field} ... }' loop - never by a
# literal $policy->{column_role} - so this is the case a purely textual
# widening would have broken.

{
    open my $fh, '<', File::Spec->catfile(qw(lib Tira.pm)) or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;
    ok( $source !~ /\$policy->\{column_role\}/,
        'column_role has no literal $policy->{column_role} anywhere in source' );
    ok( !( grep { $_ eq 'column_role' } unread_policy_fields($source) ),
        'yet the widened guard does not report it unread, because it is read through the loop' );
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

TKT-364 widened that check from C<POLICY_FIELDS> alone to all three lists
that decide what a policy carries, accepting a name read either by literal
subscript or by a for-loop over its own list that reads back through the
loop variable - the shape the role fields are genuinely read in, and the
one a purely textual widening would have reported unread against working
code.

=cut
