package Tira::Render;

# The human and table renderers, lifted out of Tira.pm so that reading the
# engine to change one command no longer means reading these too. TKT-746's
# third lift (TKT-834), after Tira::Toon (TKT-830) and Tira::Tasklist
# (TKT-832).
#
# WHAT IS HERE: everything format_output delegates to except the TOON
# encoder, which went to Tira::Toon. _markdown and _markdown_fields render
# the "human" format; _dashboard_table builds the HTML board.
#
# LOADED LAZILY. format_output requires this module immediately before its
# human and table branches, and nowhere else - so a caller asking for toon
# or json output never compiles any of it. t/485 asserts both halves: this
# module compiles standalone without Tira.pm loaded first, and a
# format_output call for json or toon leaves Tira::Render out of %INC.
#
# THIS IS THE Tira::Toon SHAPE, NOT THE Tira::Tasklist SHAPE, and the
# difference was measured rather than assumed. All four subs are reached
# only from format_output's own branches; nothing in t/, cli/ or the CLI
# modules names them. One caller means format_output calls in here directly
# and no forwarder is left behind - unlike Tira::Tasklist, whose eighteen
# public entry points each kept one.
#
# TWO THINGS DELIBERATELY LEFT ON Tira, both because they have callers
# outside this concern:
#
#   _html_escape - the login page HTML uses it too (Tira.pm:6070). It is
#   reached here as $self->_html_escape(...), which resolves because $self
#   is still a blessed Tira.
#
#   _render_view / _view_asset / json_object - the view layer and the JSON
#   backend, used all over the engine. These are PLAIN functions, not
#   methods, so they are called here fully qualified as Tira::_render_view()
#   and so on. Left unqualified they would resolve against Tira::Render,
#   compile cleanly under perl -c, and die at runtime the first time a board
#   was rendered - which is the fault TKT-607 produced seven times and
#   TKT-832 produced at 36 call sites. Found by grepping the moved region
#   for its own dependencies BEFORE moving it, rather than by the suite
#   afterwards.

use strict;
use warnings;

# The narrowed answer: what is here, named, and nothing invented about what is
# not. Records keep their reference as a heading because that is how a reader
# tells one from the next; everything else is a line.
sub _markdown_fields {
    my ( $self, $data, %args ) = @_;
    my @records = ref $data eq 'ARRAY' ? @{$data} : ($data);
    my $text = '';
    for my $record (@records) {
        my %shown = %{$record};
        my $ref = delete $shown{ref};
        $text .= '# ' . $ref . "\n\n" if defined $ref;
        for my $field ( sort keys %shown ) {
            $text .= "- $field: " . _markdown_value( $shown{$field} ) . "\n";
        }
        $text .= "\n";
    }
    return $text;
}

sub _markdown_value {
    my ($value) = @_;
    return '_None_' if !defined $value;
    return @{$value} ? join( ', ', map { _markdown_value($_) } @{$value} ) : '_Empty._'
      if ref $value eq 'ARRAY';
    return join ', ', map { "$_: " . _markdown_value( $value->{$_} ) } sort keys %{$value}
      if ref $value eq 'HASH';
    return $value eq '' ? '_Empty._' : $value;
}

sub _dashboard_table {
    my ( $self, $data, %args ) = @_;
    die "Table output requires dashboard data\n"
      if ref($data) ne 'HASH' || ref( $data->{_column_order} ) ne 'HASH';
    my %heading = ( sow => 'Statements of Work', epic => 'Epics', ticket => 'Tickets' );
    my ( $rendered_cards, @rendered_boards ) = (0);
    my $boards = '';
    for my $type (qw(sow epic ticket)) {
        next if !exists $data->{_column_order}{$type};
        my @columns = @{ $data->{_column_order}{$type} };
        my $cells = join '', map {
            my $column = $_;
            my $cards = join '', map {
                my $ref = $self->_html_escape( $_->{ref} );
                my $title = defined $_->{title}
                  ? '<span class="card__title">' . $self->_html_escape( $_->{title} ) . '</span>' : '';
                my $mtime = 0 + ( $_->{_mtime} // 0 );

                # Empty rather than nought when nobody has set one. A card
                # nobody has prioritised is unassessed, not lowest, and the
                # sort has to be able to tell the difference.
                my $priority = defined $_->{priority} ? 0 + $_->{priority} : '';
                my $waiting = ( $_->{waiting} ? ' card--waiting' : '' )
                  . ( $_->{to_review} ? ' card--to-review' : '' );
                '<li data-ref="' . $ref . '" data-mtime="' . $mtime
                  . '" data-priority="' . $priority
                  . '"><button class="card' . $waiting . '" type="button" data-ref="' . $ref
                  . '"><span class="card__ref">' . $ref . '</span>' . $title . '</button></li>';
            } @{ $data->{$type}{$column} // [] };
            my $slug = $self->_html_escape($column);
            $rendered_cards += scalar @{ $data->{$type}{$column} // [] };
            '<section class="column' . ( $column eq 'discard' ? ' column--discard' : '' )
              . '"><h3 class="column__head"><span class="column__name">' . $slug
              . '</span><span class="column__count" data-count-for="' . $slug . '" hidden></span></h3>'
              . '<div class="column__body"><ol class="cards" data-column="' . $slug . '">' . $cards . '</ol>'
              . ( $args{live} && $column ne 'discard'

                # Nobody creates work straight into the discard pile. Offering
                # it there was a side effect of showing the column at all.
                ? '<button class="column__add" type="button" data-add-card="' . $slug . '">+ Add card</button>'
                : '' )
              . '</div></section>';
        } @columns;
        push @rendered_boards, $heading{$type};
        $boards .= '<section class="board board--' . $type . '" data-type="' . $type . '">'
          . '<header class="board__header"><span class="board__kicker">Tira board</span><h2>'
          . $heading{$type} . '</h2><div class="sorter" role="group" aria-label="Sort cards">'
          . '<button type="button" data-sort="mtime" class="is-active">Last modified</button>'
          . '<button type="button" data-sort="ref">Card reference</button>'
          . '<button type="button" data-sort="priority">Priority</button></div>'
          . '<input class="board-filter" type="search" data-filter="' . $type
          . '" placeholder="Filter cards" aria-label="Filter cards">'
          . '<div class="widther" role="group" aria-label="Column width">'
          . '<button type="button" data-width="standard" class="is-active">Standard</button>'
          . '<button type="button" data-width="fit">Fit all</button></div>'
          . '<button type="button" class="board-review" data-queue="answer"'
          . ' aria-pressed="false" title="Show only cards with a question nobody has answered">'
          . 'Questions to answer</button>'
          . '<button type="button" class="board-review" data-queue="review"'
          . ' aria-pressed="false" title="Show only cards whose answers are waiting to be accepted or rejected">'
          . 'Answers to review</button>'
          . (
            # Only where it can work. Editing columns posts to the server, so
            # on a page saved to disk this was a button that looked live, said
            # "Columns", and did nothing when clicked - the second such control
            # found on that page, after the queue toggles, and found the same
            # way. The toggles could be bound because filtering happens in the
            # page; this cannot, so the page does not offer it.
            $args{live}
            ? '<button type="button" class="board-columns" data-columns="' . $type . '">Columns</button>'
              . '<button type="button" class="board-policies" data-policies="1">Policies</button>'
            : ''
          )
          . '</header>'
          . '<div class="board__scroll"><div class="board__columns">'
          . $cells . '</div></div></section>';
    }

    # TKT-516: a lightweight sticky-note section below the ticket board -
    # his words, "not a messy piece of shit" - full CLI parity for the
    # tasklist feature. Live-only, the same way the Policies dialog is,
    # since it needs the server to actually do anything.
    $boards .= '<section class="board board--tasklist" data-type="tasklist">'
      . '<header class="board__header"><span class="board__kicker">Tira board</span><h2>Task List</h2>'
      . '<input class="tasklist-session" type="text" placeholder="Session (blank = shared)" aria-label="Session">'
      . '<select class="tasklist-sessions-list" aria-label="Known sessions"><option value="">Known sessions...</option></select></header>'
      . '<div class="tasklist-controls">'
      . '<input class="tasklist-text" type="text" placeholder="New task text" aria-label="New task text">'
      . '<button type="button" class="tasklist-add">Add</button>'
      . '<button type="button" class="tasklist-prune">Prune</button>'
      . '</div><p class="tasklist-error" hidden></p><ol class="tasklist-cards"></ol></section>'
      if $args{live};

    # Repeated jobs, directly under the Task List because that is where he
    # asked for them: "a new section under the tasklist to see all the
    # scheduled jobs, they like cronjob style the record". Read-only here -
    # the play button and the editor modal are their own card, so this
    # section is a table and nothing else. EPC-014, TKT-839.
    $boards .= '<section class="board board--jobs" data-type="jobs">'
      . '<header class="board__header"><span class="board__kicker">Tira board</span><h2>Repeated Jobs</h2></header>'
      . '<p class="jobs-error" hidden></p><ol class="jobs-cards"></ol></section>'
      if $args{live};
    my $project_heading = 'Tira Kanban';
    if ( defined $args{project} ) {
        my $project_name = eval { $self->project_show( project => $args{project} )->{name} };
        $project_heading = $self->_html_escape($project_name) if defined $project_name && $project_name ne '';
    }
    my $refresh_action = $args{live}
      ? q{fetch("/data",{cache:"no-store"}).then(response=>{if(response.status===401){location.reload();return null}if(!response.ok)throw new Error("refresh failed");return response.json()}).then(data=>{if(!data)return;if(data._version&&data._version!==document.documentElement.dataset.version){location.reload();return}markStale(data._stale);updateBoards(data);markUpdated();maybeRefreshDialog()}).catch(()=>{})}
      : q{location.reload()};
        my $column_editor = $args{live} ? Tira::_view_asset('column-editor.js') : '';
        my $policy_editor = $args{live} ? Tira::_view_asset('policy-editor.js') : '';
        my $tasklist_editor = $args{live} ? Tira::_view_asset('tasklist-editor.js') : '';
        my $jobs_editor = $args{live} ? Tira::_view_asset('jobs-editor.js') : '';
my $live_helpers = $args{live} ? Tira::_view_asset('live-helpers.js')
      : '';
    my $card_binding = $args{live}
      ? q{card.onclick=event=>{if(window.__tiraDragEndAt&&Date.now()-window.__tiraDragEndAt<50){window.__tiraDragEndAt=0;return}if(event.shiftKey){event.preventDefault();toggleSelection(card);return}if(selection.size)clearSelection();const ref=card.dataset.ref;const type=card.closest(".board").dataset.type;fetch("/record?type="+encodeURIComponent(type)+"&ref="+encodeURIComponent(ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("detail failed");return response.json()}).then(record=>{cardNavStack=[];updateBackButton();showCard(record)}).catch(()=>{});};}
      : q{card.onclick=()=>card.classList.toggle("is-selected");};
    my $dialog = $args{live}
      ? Tira::_render_view( 'dialogs.tt',
        { fields => [qw(enter before column age read_age max pattern message require sandbox require_link link_to)] } )
      : '';
    my $with_title = $args{with_title} ? '1' : '0';
    my $initial_refresh = $args{live} ? 'refreshDashboard();' : '';
    my $drag_script = $args{live}
      ? Tira::_view_asset('selection.js')
      : '';
    my $script = Tira::_view_asset('base-script.js') . $live_helpers . $column_editor . $policy_editor . $tasklist_editor . $jobs_editor
      . 'const bindBoards=()=>{document.querySelectorAll(".card").forEach(card=>{'
      . $card_binding . Tira::_view_asset('board-bindings.js') . $refresh_action
      . ';const scheduleRefresh=()=>setTimeout(()=>{Promise.resolve(refreshDashboard()).finally(scheduleRefresh)},refreshSeconds*1000);'
      . $initial_refresh
      . 'scheduleRefresh();'
      . Tira::_view_asset('hero-counts.js')
      . $drag_script;

    return Tira::_render_view( 'dashboard.tt', {
        version     => $Tira::VERSION,
        with_title  => $with_title,
        heading     => $project_heading,
        board_label => ( @rendered_boards == 1 ? $rendered_boards[0] : 'Kanban' ),
        cards       => $rendered_cards,
        css         => Tira::_view_asset('dashboard.css'),
        boards      => $boards,
        dialog      => $dialog,
        script      => $script,
    } );
}

sub _markdown {
    my ( $self, $data, %args ) = @_;

    # a question list carries a ref, so without this it was taken for a
    # record and drawn as a card with no title. The person who owns the
    # decision reads this view, not the JSON, so it is the one that matters.
    if ( ref($data) eq 'HASH' && ref( $data->{questions} ) eq 'ARRAY' && exists $data->{instruction} ) {
        my $heading = '# Questions on ' . $data->{ref}
          . ( defined $data->{title} && $data->{title} ne '' ? ": $data->{title}" : '' )
          . "\n\n";
        return $heading . "_No questions have been asked about this card._\n"
          if !@{ $data->{questions} };
        my $body = '';
        for my $question ( @{ $data->{questions} } ) {
            my $asked = $question->{author} ? " by $question->{author}" : '';
            $body .= "## $question->{id} \x{2014} $question->{status}\n\n"
              . "$question->{text}\n\n";
            $body .= "_Why:_ $question->{reason}\n\n" if $question->{reason};
            if ( @{ $question->{options} // [] } ) {
                my $n = 0;
                $body .= "_Options:_\n\n"
                  . join( '', map { ++$n . ". $_\n" } @{ $question->{options} } ) . "\n";
            }
            $body .= "_Asked $question->{asked_at}$asked._\n\n";
            $body .= "_Set aside $question->{discarded_at}._\n\n" if $question->{discarded_at};
            my $answer = $question->{answer};
            if ( !$answer ) {
                $body .= "_No answer yet \x{2014} this card is waiting on the owner._\n\n";
                next;
            }
            $body .= "> " . join( "\n> ", split /\n/, $answer->{text} ) . "\n\n";
            my @state = ("answered $answer->{answered_at}");
            push @state, "edited $answer->{updated_at}" if $answer->{updated_at};
            push @state, $answer->{read_at} ? "read $answer->{read_at}" : 'not yet read';
            push @state, $answer->{mark} ? "marked $answer->{mark}" : 'not yet marked';
            $body .= '_' . join( ', ', @state ) . "._\n\n";
        }
        return $heading . $body . "---\n\n$data->{instruction}\n";
    }

    if ( ref($data) eq 'HASH' && exists $data->{ref} ) {

        # An absent description is normal, not a reason to warn on every read.
        my $description = ( $data->{description} // '' ) ne ''
          ? $data->{description} : '_No description._';
        my %priority = ( 1 => 'Low', 2 => 'Medium Low', 3 => 'Medium', 4 => 'High', 5 => 'Very High' );
        my %names;
        my $people = eval {
            $self->person_list( defined $args{project} ? ( project => $args{project} ) : () );
        } // [];
        %names = map { $_->{id} => $_->{name} } @{$people};
        my $assignee = defined $data->{assignee} ? ( $names{ $data->{assignee} } // $data->{assignee} ) : '_Unassigned_';
        my $reporter = defined $data->{reporter} ? ( $names{ $data->{reporter} } // $data->{reporter} ) : '_None_';
        my $priority = defined $data->{priority} ? $priority{ $data->{priority} } : '_None_';
        my $checklist = @{ $data->{checklist} // [] }
          ? "\n## Checklist\n\n" . join( '', map { "- [$_->{status}] $_->{item}\n" } @{ $data->{checklist} } )
          : "\n## Checklist\n\n_Empty._\n";
        my $children = exists $data->{children}
          ? "\n## Children\n\n" . ( @{ $data->{children} }
              ? join( '', map { "- `$_->{ref}`" . ( defined $_->{title} ? " $_->{title}" : '' ) . "\n" }
                  @{ $data->{children} } )
              : "_Empty._\n" )
          : '';
        return '# ' . $data->{ref} . ': ' . ( $data->{title} // '' ) . "\n\n$description\n\n"
          . '- Type: `' . ( $data->{type} // '' ) . "`\n"
          . "- Assignee: $assignee\n"
          . "- Reporter: $reporter\n"
          . "- Priority: $priority\n"
          . '- Created: ' . ( $data->{created_at} // '' ) . "\n"
          . '- Last Updated: ' . ( $data->{last_updated} // '' ) . "\n"
          . $checklist
          . $children;
    }
    if ( ref($data) eq 'HASH' && ref( $data->{_column_order} ) eq 'HASH' ) {
        my $markdown = "# Tira Dashboard\n";
        for my $type (qw(sow epic ticket)) {
            next if !exists $data->{_column_order}{$type};
            $markdown .= "\n## " . uc($type) . "\n";
            for my $column ( @{ $data->{_column_order}{$type} } ) {
                $markdown .= "\n### $column\n";
                my $records = $data->{$type}{$column};
                $markdown .= @{$records}
                  ? join( '', map { "- `$_->{ref}`" . ( defined $_->{title} ? " $_->{title}" : '' ) . "\n" } @{$records} )
                  : "_Empty._\n";
            }
        }
        return $markdown;
    }
    return "# Tira Result\n\n```json\n" . Tira::json_object()->canonical->allow_nonref->pretty->encode($data) . "```\n";
}

1;

__END__

=head1 NAME

Tira::Render - the human and table renderers, one concern lifted out of Tira.pm

=head1 DESCRIPTION

Everything C<Tira::format_output> delegates to except the TOON encoder, which
lives in L<Tira::Toon>. C<_markdown> and C<_markdown_fields> render the
C<human> format; C<_dashboard_table> builds the HTML board.

Under C<live>, C<_dashboard_table> also emits the Repeated Jobs section - an
empty C<< <ol class="jobs-cards"> >> inside C<section.board--jobs>, placed
after the Task List section, and the C<jobs-editor.js> view asset that fills
it from the C<GET /jobs> route. Only the shell is built here: no job data is
concatenated into the page, which is what keeps F<t/426>'s claim true.

Loaded with C<require> from C<format_output> immediately before its C<human>
and C<table> branches, so a caller asking for C<toon> or C<json> never
compiles it.

=head1 CALL IT THROUGH TIRA, NOT DIRECTLY

C<Tira> is the public entry point; this module is an implementation detail of
C<format_output>. Every sub here takes C<$self> - a blessed C<Tira> - as its
first argument and is meant to be reached that way.

=head1 IF YOU EDIT THIS MODULE

=over 4

=item * B<Do not add C<use Tira::Render> to F<lib/Tira.pm>.> The per-call
C<require> is the point of the lift, and it is guarded rather than merely
asked for: F<t/485> renders nothing and asserts C<Tira/Render.pm> is absent
from C<%INC>, so collapsing it into a top-level C<use> turns that red.

=item * B<Qualify the helpers that stayed behind.> C<Tira::_render_view>,
C<Tira::_view_asset>, C<Tira::json_object> and C<$Tira::VERSION> are plain
functions and a package variable on C<Tira>, not methods, and must keep their
C<Tira::> prefix here. Unqualified they resolve against this package, compile
cleanly, and die when a board is rendered. C<$self-E<gt>_html_escape>,
C<$self-E<gt>person_list> and C<$self-E<gt>project_show> are method calls and
need no prefix.

=item * B<Do not "finish the cleanup" by dragging those helpers in here.>
Calling back into C<Tira> is the deliberate boundary of this lift, not an
unfinished edge of it. The rule is that a helper moves only if this concern
is its B<only> caller, and each of the ones left behind fails that test:
C<_html_escape> is also used by the login page HTML (F<lib/Tira.pm>, in
C<login_page_html>), and C<_render_view>, C<_view_asset>, C<json_object> and
C<$VERSION> are used across the whole engine. Moving any of them would put a
name somewhere its other callers cannot reach - which is the same mistake in
the opposite direction from leaving a call unqualified.

=back

=head1 WHAT MUST NOT REGRESS

F<t/485> is the file that holds this lift to its promises, and it asserts
four distinct things - if you change this module, that is the file to run
first:

=over 4

=item * C<Tira::Render> compiles and loads standalone, without C<Tira.pm>
having been loaded first.

=item * C<format_output> for C<json> B<and> for C<toon> both leave
C<Tira/Render.pm> out of C<%INC>. This is what enforces the lazy C<require>.

=item * Both rendering branches still produce what they produced before the
lift - whole-record C<human>, narrowed C<human> (the C<_markdown_fields>
branch TKT-157 fixed), and C<table>, including escaping performed through the
helper that stayed on C<Tira>.

=item * Both refusals survive: C<table> handed data that is not a board still
dies with C<Table output requires dashboard data>, and an unknown format is
still refused by C<format_output> itself.

=back

Those last two groups passed B<before> the lift as well as after, which is
what makes them a no-behaviour-change baseline rather than a description of
the end state.

=cut
