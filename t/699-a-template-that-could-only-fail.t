#!/usr/bin/env perl
# TKT-699. column_update and column_apply store a required-action template
# exactly as given - an empty string, a whitespace-only string, or the same
# text twice. Nothing refuses that, and nothing says anything about it. The
# consequence arrives later and elsewhere: every move into that column is
# refused, permanently, and the message names the column rather than the
# command that broke it.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Templates', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TPS', epic_prefix => 'TPE', ticket_prefix => 'TPT',
);

# --- column_update refuses an empty exit required action, naming which ------

{
    my $ok = eval {
        $tira->column_update( project => $root, type => 'ticket', name => 'implement',
            required_action => [ 'Do the real thing', '' ] );
        1;
    };
    ok( !$ok, 'column_update refuses an empty exit required action' );
    like( $@ // '', qr/exit required action/i,
        'and the refusal names it as an exit required action' );
}

# --- and a whitespace-only one, which passes a naive length check -----------

{
    my $ok = eval {
        $tira->column_update( project => $root, type => 'ticket', name => 'implement',
            required_action => [ 'Do the real thing', '   ' ] );
        1;
    };
    ok( !$ok, 'column_update refuses a whitespace-only exit required action' );
}

# --- and an empty entry required action, naming which -----------------------

{
    my $ok = eval {
        $tira->column_update( project => $root, type => 'ticket', name => 'implement',
            entry_required_action => [ 'Already done', '' ] );
        1;
    };
    ok( !$ok, 'column_update refuses an empty entry required action' );
    like( $@ // '', qr/entry required action/i,
        'and the refusal names it as an entry required action' );
}

# --- a duplicate is refused too, not silently deduped -----------------------
#
# The template would otherwise hold two entries while required_item_add
# stores one - a count two readers of the same column would disagree about.

{
    my $ok = eval {
        $tira->column_update( project => $root, type => 'ticket', name => 'implement',
            required_action => [ 'Same thing', 'Same thing' ] );
        1;
    };
    ok( !$ok, 'column_update refuses a duplicate exit required action' );
    like( $@ // '', qr/Same thing/,
        'and names the duplicated text' );
}

{
    my $ok = eval {
        $tira->column_update( project => $root, type => 'ticket', name => 'implement',
            entry_required_action => [ 'Same thing', 'Same thing' ] );
        1;
    };
    ok( !$ok, 'column_update refuses a duplicate entry required action' );
}

# --- a legitimate template is unaffected -------------------------------------

{
    my $updated = eval {
        $tira->column_update( project => $root, type => 'ticket', name => 'implement',
            required_action => [ 'Do the real thing', 'Then check it' ],
            entry_required_action => [ 'Already done' ] );
    };
    ok( $updated, 'a legitimate, non-empty, distinct template is stored' )
      or diag($@);
    is_deeply( $updated->{required_actions}, [ 'Do the real thing', 'Then check it' ],
        'the exit template is exactly what was sent' );
    is_deeply( $updated->{entry_required_actions}, ['Already done'],
        'and so is the entry template' );
}

# --- column_apply refuses the same faults, on its own whole-layout route ----

{
    my $columns = $tira->column_list( project => $root, type => 'ticket' );

    my $ok = eval {
        $tira->column_apply(
            project => $root, type => 'ticket',
            columns => [ map {
                $_->{name} eq 'implement'
                  ? { %{$_}, required_actions => [ 'Fine', '' ] }
                  : $_;
            } @{$columns} ],
        );
        1;
    };
    ok( !$ok, 'column_apply refuses an empty exit required action in a whole-layout replace' );
}

{
    my $columns = $tira->column_list( project => $root, type => 'ticket' );

    my $ok = eval {
        $tira->column_apply(
            project => $root, type => 'ticket',
            columns => [ map {
                $_->{name} eq 'implement'
                  ? { %{$_}, entry_required_actions => [ 'Twice', 'Twice' ] }
                  : $_;
            } @{$columns} ],
        );
        1;
    };
    ok( !$ok, 'column_apply refuses a duplicate entry required action in a whole-layout replace' );
}

{
    my $columns = $tira->column_list( project => $root, type => 'ticket' );
    my $applied = eval {
        $tira->column_apply(
            project => $root, type => 'ticket',
            columns => [ map {
                $_->{name} eq 'implement'
                  ? { %{$_}, required_actions => [ 'Fine', 'Also fine' ] }
                  : $_;
            } @{$columns} ],
        );
    };
    ok( $applied, 'column_apply stores a legitimate template unchanged' )
      or diag($@);
}

# --- a column already broken (a legacy board) still gets today's move ------
# --- refusal, with its reason and its working fix line - THIS MUST NOT ------
# --- CHANGE. The fix is at the point of typing, not at the point of use. ---

{
    # Reach past the engine's own new validation the same way a board that
    # predates this fix would already hold a broken template on disk -
    # writing the config directly rather than through column_update.
    require YAML::XS;
    my $path = File::Spec->catfile( $root, '.tira', 'ticket', 'config.yml' );
    my $config = YAML::XS::LoadFile($path);
    for my $column ( @{ $config->{columns} } ) {
        $column->{entry_required_actions} = ['']  if $column->{name} eq 'implement';
    }
    YAML::XS::DumpFile( $path, $config );

    my $card = $tira->create_record(
        project => $root, type => 'ticket',
        title => 'A card behind a column with a legacy broken template',
        problem_or_feature => 'x', solution_needed => 'x', key_details => ['x'],
        deliverables => ['x'], acceptance_criteria => ['x'], test_steps => ['x'],
        bdd => ['x'], atdd => ['x'], description => 'x', scope_in => ['x'], scope_out => ['x'],
    );

    require Tira::CLI;
    my $violation = Tira::CLI::_column_entry_required_action_violation(
        $tira, project => $root, type => 'ticket', ref => $card->{ref}, column => 'implement' );

    ok( $violation, 'a card behind a legacy broken template still cannot move in' );
    like( $violation // '', qr/Cannot move .* into implement/,
        'and the refusal names the move and the column' );
    like( $violation // '', qr/entry-required-action/,
        'and its working fix line is unchanged' );
}

done_testing();

__END__

=head1 NAME

699-a-template-that-could-only-fail.t - a required-action template is refused
where it is typed, not where it is used

=head1 DESCRIPTION

TKT-699. C<column_update> and C<column_apply> used to accept an empty,
whitespace-only, or duplicated required-action entry - entry or exit - and
say nothing. The failure arrived later, at every move into that column,
which the existing refusal already reports correctly and continues to.
Both writers now refuse at the point of typing instead, naming which
argument was empty or which text repeated; a legitimate template is
unaffected on either route, and a column whose template was already broken
before this fix still gets the original move refusal.

=cut
