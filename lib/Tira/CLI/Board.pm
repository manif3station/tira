package Tira::CLI::Board;

# Seven command bodies about the board itself rather than about a card on it:
# who may work a column, which card comes next, who is logged in, what the
# policies are, what moved between columns, a rule suspended, and the
# file-taking form of attachment.add.
#
# None is large alone - the biggest is column_roles at 38 lines - and together
# they are 165 lines that were in the middle of the dispatcher, which no other
# command needs to read. They are one module because they are one subject: the
# board's own rules and the people under them.
#
# This comment said "Four command bodies... 97 lines" until three more arrived
# in a later slice. A second reader caught the same drift in the POD below and
# reported this comment as already corrected; it was not. Two descriptions of
# one file, both stale, and only one of them noticed.

use strict;
use warnings;

use Tira;
# Tira::CLI is always in memory when this runs - nothing loads this module
# except Tira::CLI itself - but the helpers below are called by their full
# names, and an assumption a reader has to reconstruct is not a dependency.
# The require is free (%INC already holds it) and it is what makes
# `perl -c` on this file alone meaningful. TKT-607.
use Tira::CLI ();

sub column_roles {
    my ( $tira, $args, $option ) = @_;
    my %args = %{$args};

    # Taking one back, which nothing could do - a role declared by mistake
    # was permanent and undoing it meant editing .tira by hand. TKT-384.
    # The reason is required by the engine and belongs to the removal alone:
    # accepted-and-ignored beside a --role would be a stored explanation for
    # something nobody could later find.
    die "A reason belongs to --remove-role. Declaring a role does not take one\n"
      if defined $option->{reason} && !$option->{remove_roles};
    return $tira->column_roles_remove( %args, roles => $option->{remove_roles},
        reason => $option->{reason}, author => $option->{author} )
      if $option->{remove_roles};
    return $tira->column_roles(%args) if !$option->{roles};

    # Written the way he says it: which column is the backlog, which is
    # in progress. Each --role takes name=column, and any role may be
    # left unset because most projects have a column for very few of them.
    #
    # 'entry' alone may be given more than once - a board can start new
    # cards in more than one place - and repeating it accumulates rather
    # than the last one silently winning, the way a second --role of any
    # other name still does. TKT-496.
    my %roles;
    for my $pair ( @{ $option->{roles} } ) {
        my ( $role, $column ) = split /=/, $pair, 2;
        die "A role is written as name=column, not '$pair'\n"
          if !defined $column || $column eq '' || $role eq '';
        if ( $role eq 'entry' ) {
            push @{ $roles{$role} }, $column;
        }
        else {
            $roles{$role} = $column;
        }
    }
    return $tira->column_roles_set( %args, roles => \%roles );
}

sub next_card {
    my ( $tira, $args, $option ) = @_;
    my %args = %{$args};
    my $order = $tira->work_order( %args,
        ( $option->{brief} ? ( brief => 1 ) : () ),
        ( defined $option->{truncate} ? ( truncate => $option->{truncate} ) : () ) );

    # A quiet board used to answer with a bare array while a busy one
    # answered with {next, then} - the same command returning two
    # different TYPES depending on state. A caller written against the
    # documented shape does result->{next}, which works every time the
    # board has work and raises an error the first time it goes quiet -
    # precisely when a scheduled caller runs unattended and nobody is
    # watching. One shape now serves both states: next is undef rather
    # than an object when nothing is waiting, and the empty answer stays
    # just as unambiguous. TKT-354.
    return { next => undef, then => [] } if !@{$order};

    # The first one is the answer; the rest are what it was chosen over,
    # which is the part that makes the answer checkable rather than taken
    # on trust.
    return { next => $order->[0], then => [ @{$order}[ 1 .. $#{$order} ] ] };
}

sub login_verbs {
    my ( $tira, $args, $option, $command ) = @_;
    my %args = %{$args};
    # $1 below is this match's, not the dispatcher's. The block read the
    # capture left by the if() it used to sit inside; as a sub it sets its
    # own, so a stale match elsewhere cannot choose the branch.
    $command =~ /\Alogin\.(register|check|status|logout)\z/ or return;
    my $action = $1;
    return $tira->login_register( %args, password => $option->{password} )
      if $action eq 'register';

    # A wrong password and a person who does not exist must look the same
    # from outside, or the command becomes a way to find out who is here.
    return { ok => $tira->login_verify( %args, password => $option->{password} )
          ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false }
      if $action eq 'check';

    # The listing says who, never what they are holding: a token is the
    # credential itself.
    return [ map { { person => $_->{person}, started_at => $_->{started_at},
                     last_seen_at => $_->{last_seen_at} } }
             @{ $tira->session_list(%args) } ]
      if $action eq 'status';

    die "Use --id PERSON or --all to say whose sessions to end\n"
      if !$option->{all} && ( !defined $args{id} || $args{id} eq '' );
    my $ended = 0;
    for my $session ( @{ $tira->session_list(%args) } ) {
        next if !$option->{all} && $session->{person} ne $args{id};
        $tira->session_end( %args, token => $session->{token} );
        $ended++;
    }
    return { ended => $ended };
}

sub policy_verbs {
    my ( $tira, $args, $option, $command ) = @_;
    my %args = %{$args};
    # $1 below is this match's, not the dispatcher's. The block read the
    # capture left by the if() it used to sit inside; as a sub it sets its
    # own, so a stale match elsewhere cannot choose the branch.
    $command =~ /\Apolicy\.(add|list|remove)\z/ or return;
    my $action = $1;
    return $tira->policy_list(%args) if $action eq 'list';
    return $tira->policy_remove(%args) if $action eq 'remove';
    my %policy = map { $_ => $option->{$_} }
      grep { defined $option->{$_} }
      qw(rule action enter column age read_age max pattern message require require_link link_to sandbox notify);

    # Where the policy is declared decides how narrow it is: naming a
    # board, a column or a card each makes it beat the level above.
    $policy{type} = $option->{type} if defined $option->{type};
    $policy{on_column} = $option->{on_column} if defined $option->{on_column};
    $policy{ref} = $args{ref} if defined $args{ref};
    # The three role fields are not copied here. They arrive in %args
    # like every other option and policy_add reads them from there, which
    # was proved by taking the copy away and watching nothing change - so
    # the line existed to look careful rather than to do anything. TKT-221.

    # --before already means a date filter elsewhere, so the column form
    # is spelled out rather than overloading a flag that means something
    # different on every other command.
    $policy{before} = $option->{before_column} if defined $option->{before_column};
    return $tira->policy_add( %args, %policy );
}

# Four more blocks out of the dispatcher: what moved between columns, a rule
# suspended, the dashboard verbs, and the file-attachment form of
# attachment.add. Small individually and about the board rather than a card,
# which is what this module is for. TKT-607.

sub notify_moves {
    my ( $tira, $args, $option ) = @_;
    my %args = %{$args};

    # A bare call is a read, not "turn it on" - defaulting enabled to 1
    # here made every plain d2 tira.notify.moves look, to the engine, like
    # --watch had been given. Only pass it when something was actually
    # named. TKT-398.
    return $tira->notify_moves(
        project => $args{project},
        ( defined $option->{column} ? ( column => $option->{column} ) : () ),
        ( defined $option->{chat} ? ( chat => $option->{chat} ) : () ),
        ( defined $option->{watched} ? ( enabled => $option->{watched} ) : () ),
    );
}

sub rule_suspend {
    require Tira::CLI::Police;
    my ( $tira, $args, $option ) = @_;
    my %args = %{$args};
    my $store = $option->{store}
      // Tira::CLI::Police::_police_store( $tira->discover_project(%args) );
    return $tira->rule_suspend( %args, store => $store,
        rule => $option->{rule}, seconds => $option->{seconds},
        reason => $option->{reason},
        ( defined $option->{pid} ? ( pid => $option->{pid} ) : () ) );
}


sub attachment_add_files {
    my ( $tira, $args, $option ) = @_;
    my %args = %{$args};
    my @added;
    for my $path ( @{ $option->{files} } ) {
        my $one = eval { $tira->attachment_add( %args, file => $path ) };
        if ( !$one ) {
            die "$@" . ( @added ? "\nAttached before the failure: "
                . join( ', ', map { $_->{original_filename} } @added ) . "\n" : '' );
        }
        push @added, $one;
    }
    return \@added;
}

1;

__END__

=head1 NAME

Tira::CLI::Board - the board's own rules: columns, the next card, logins, policies

=head1 DESCRIPTION

C<column_roles> answers who may work a column. C<next_card> answers which card
comes next. C<login_verbs> covers C<login.register>, C<login.check>,
C<login.status> and C<login.logout>. C<policy_verbs> covers C<policy.add>,
C<policy.list> and C<policy.remove>. C<notify_moves> answers what moved between
columns, C<rule_suspend> suspends a rule, and C<attachment_add_files> is the
file-taking form of C<attachment.add>.

Seven bodies, all of them blocks inside C<Tira::CLI::_invoke> until 4.74. None
is large alone; together they were about 150 lines that every other command had
to be read past.

This entry said "four command bodies... 97 lines" for the first hour, because
three more arrived in a later slice and the POD was not re-read. A second reader
found it. It is the same fault the whole card is about, in the file that exists
because of it.

=head2 The captures that had to be re-taken

C<login_verbs> and C<policy_verbs> chose their branch from C<$1>, the capture
left by the C<if> in C<_invoke> they sat inside. A sub reading a caller's
capture gets whatever the last match anywhere left, and takes a branch rather
than failing - so each matches C<$command> itself.

=head2 How this module is loaded

C<Tira::CLI> pulls this in with C<require> at the point one of its verbs runs,
so a command that never needs it never compiles it. It calls into L<Tira::CLI::Police>, and asks for
that the same way - inside the sub that needs it, not at the top of this
file. A C<use> there is correct and turns a lazy chain eager, which is how
C<tira.next> came to compile four modules for the sake of one helper for the
first hour after the split.

=head1 SEE ALSO

L<Tira::CLI>

=cut
