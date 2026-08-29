package Tira::CLI::Browser;

# The coderefs the browser dashboard is built from, moved out of Tira::CLI so
# that reading the CLI to change one command no longer means reading these too.
#
# This is 702 lines needed by exactly one invocation - the one that serves a
# board - and Tira::CLI loads it with require at that point rather than with use
# at the top, the same way it already treats Tira::DashboardWeb and
# Tira::OnboardWeb. A CLI call that never serves a board never compiles any of
# it.
#
# THE ENTRY POINT KEEPS ITS OLD NAME. Tira::CLI::browser_providers still exists
# and still answers; it forwards here. Twenty test files and the dashboard call
# it by that name, and a refactor that renames its own front door is not
# behaviour-preserving. Tira::CLI is the index: it says the thing exists and
# where it lives.
#
# The six helpers this needs are called as Tira::CLI::_name(), qualified rather
# than imported. Nothing loads this module except Tira::CLI, so Tira::CLI is
# always already in memory when these run - and writing the package name at the
# call site says where the helper lives, which is the whole point of splitting
# the file.

use strict;
use warnings;

use Cpanel::JSON::XS ();
use File::Temp ();
use Tira;
# Tira::CLI is always in memory when this runs - nothing loads this module
# except Tira::CLI itself - but the helpers below are called by their full
# names, and an assumption a reader has to reconstruct is not a dependency.
# The require is free (%INC already holds it) and it is what makes
# `perl -c` on this file alone meaningful. TKT-607.
use Tira::CLI ();

sub providers {
    require Tira::CLI::Police;
    my (%args) = @_;
    my $tira = $args{tira};
    my $project = $args{project};
    my $json = Tira::json_object()->canonical;
    my %editable = map { $_ => 1 } qw(
        title description problem_or_feature solution_needed source
        sdlc_gate lifecycle fix_version assignee reporter priority
        start_date due_date
    );
    my %list_editable = (
        labels => 'labels_replace', affects_versions => 'affects_versions_replace',
        key_details => 'key_details_replace', deliverables => 'deliverables_replace',
        acceptance_criteria => 'acceptance_replace', test_steps => 'test_steps_replace',
        bdd => 'bdd_replace', atdd => 'atdd_replace',
        scope_included => 'scope', scope_excluded => 'scope',
    );
    return (
        move => sub {
            my ($payload) = @_;
            die "Move payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref column)) {
                die "Move payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my %move_args = (
                project => $project,
                ( defined $payload->{type} ? ( type => $payload->{type} ) : () ),
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                ref => $payload->{ref}, column => $payload->{column},
            );

            # The gating half of TKT-426 stays CLI/agent-only on purpose - a
            # human moving a card in the browser is not an agent skipping a
            # gate. But the bookkeeping half (populating a destination
            # column's required-action template, resetting one on the way
            # back through) is not enforcement, it is keeping the card
            # accurate for whoever looks at it next - and that has to happen
            # here too, or a browser move silently leaves required_items
            # stale in either direction. TKT-452.
            my $before = eval { $tira->record_show(%move_args) };
            my $from   = $before ? $before->{column} : undef;
            my $record = $tira->record_move(%move_args);

            # column_list (and the required-action bookkeeping below) needs a
            # concrete board type, unlike record_show/record_move above, which
            # resolve the record by ref alone (TKT-532) - recovered here from
            # the record record_move already loaded, so a caller is never
            # required to say what the engine can already tell for itself.
            my %column_args = ( %move_args, type => $record->{type} );
            my $columns = eval { $tira->column_list(%column_args) };
            Tira::CLI::_apply_column_required_actions( $tira, \%column_args, $from, $payload->{column}, $columns, $record )
              if ref $columns eq 'ARRAY';

            # The destination's ENTRY actions land here too, for the same
            # reason its exit ones do: bookkeeping, not gating. The refusal
            # stays CLI-only (TKT-426), so a dragged card is admitted - but it
            # arrives carrying what that column asks of it rather than
            # pretending nothing was asked. TKT-591.
            # The failure is SAID rather than dropped. This path cannot
            # refuse - that is TKT-426's whole point - but it can decline to
            # be silent: a column whose entry list could not be placed leaves
            # the card claiming nothing was asked of it, and the server log is
            # where whoever is running the dashboard would find out. Codex
            # review caught the POD promising a report that nothing made.
            my $entry_failed = ref $columns eq 'ARRAY'
              ? Tira::CLI::_populate_entry_required_actions( $tira, \%column_args, $payload->{column}, $columns, $record )
              : [];
            printf {*STDERR} "%s moved into %s, but %d of that column's entry required action(s) could not be put on the card: %s\n",
              $payload->{ref}, $payload->{column}, scalar @{$entry_failed},
              join( '; ', map { ( length $_->[0] ? $_->[0] : '(an empty entry action)' ) . " - $_->[1]" } @{$entry_failed} )
              if @{$entry_failed};

            # Bookkeeping, so it belongs here as well as on the CLI path -
            # TKT-452's distinction exactly: the gating half stays CLI-only
            # because a human dragging a card is not an agent skipping a gate,
            # but keeping the card accurate for whoever looks at it next is
            # not enforcement and has to happen either way. Left out at first,
            # which meant a card dragged back to backlog in the browser went
            # on claiming somebody was working its tasks - the very fault
            # TKT-596 exists to fix, surviving on the other path. TKT-596.
            Tira::CLI::_reset_linked_tasks_on_return( $tira, \%column_args, $payload->{column} );

            $record = $tira->record_show(%column_args) if ref $columns eq 'ARRAY';

            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        detail => sub {
            my ($payload) = @_;
            die "Record detail requires ref\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref};
            my $record = $tira->record_show(
                project => $project,
                ( defined $payload->{type} ? ( type => $payload->{type} ) : () ),
                ref => $payload->{ref},
            );
            Tira::CLI::_stamp_attachment_types( $tira, $project, $payload->{ref}, $record );
            return $json->encode($record);
        },
        # The browser goes through the same subroutines the command line goes
        # through, so a rule cannot be enforced in one and forgotten in the
        # other. A failed sign-in answers ok => false rather than dying,
        # because the login page has to show a message, not a stack trace.
        # Fetched only when somebody expands the section. A card has a great
        # deal happen to it, and loading all of it whenever a card is opened
        # would bury everything else on the card.
        work_log => sub {
            my ($payload) = @_;
            die "A card reference is required\n" if !defined $payload->{ref};
            return $json->encode(
                $tira->work_log( project => $project, ref => $payload->{ref} ) );
        },

        # What police has said about this card, read when the card opens rather
        # than when a section is expanded: there is at most one line per thing
        # police has said, unlike the work log, and the section has to know
        # whether it has anything before it decides to appear at all.
        #
        # A card reference is required. Answering an unnamed card with the whole
        # board's enforcement log would put every other card's chasing on
        # whichever card happened to be open.
        police_log => sub {
            my ($payload) = @_;
            die "A card reference is required\n" if !defined $payload->{ref};
            return $json->encode(
                $tira->enforcement_log(
                    project => $project,
                    store   => $args{store}
                      // Tira::CLI::Police::_police_store( $tira->discover_project( project => $project ) ),
                    ref     => $payload->{ref},
                ) );
        },
        login_page => sub {
            my $project_name = eval { $tira->project_show( project => $project )->{name} };
            return $tira->login_page_html( name => $project_name );
        },
        login_start => sub {
            my ($payload) = @_;
            my $token = eval {
                $tira->login_start(
                    project => $project, id => $payload->{id},
                    password => $payload->{password},
                );
            };
            return $json->encode( { ok => Cpanel::JSON::XS::false } ) if !defined $token;
            return $json->encode( { ok => Cpanel::JSON::XS::true, token => $token } );
        },
        login_register => sub {
            my ($payload) = @_;
            my $person = eval {
                $tira->login_register(
                    project => $project, id => $payload->{id},
                    password => $payload->{password},
                );
            };
            return $json->encode( { ok => Cpanel::JSON::XS::false } ) if !$person;
            my $token = $tira->login_start(
                project => $project, id => $payload->{id}, password => $payload->{password} );
            return $json->encode( { ok => Cpanel::JSON::XS::true, token => $token, claimed => Cpanel::JSON::XS::true } );
        },
        session_resume => sub {
            my ($payload) = @_;
            my $session = $tira->session_resume( project => $project, token => $payload->{token} );
            return $json->encode( $session ? { %{$session} } : { person => undef } );
        },
        session_peek => sub {
            my ($payload) = @_;
            my $session = $tira->session_peek( project => $project, token => $payload->{token} );
            return $json->encode( $session ? { %{$session} } : { person => undef } );
        },
        session_end => sub {
            my ($payload) = @_;
            my $ended = eval { $tira->session_end( project => $project, token => $payload->{token} ) };
            return $json->encode( { ok => $ended ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false } );
        },
        question_answer => sub {
            my ($payload) = @_;
            die "Answering needs a question and some text\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{text};
            return $json->encode( {
                ok => Cpanel::JSON::XS::true,
                question => $tira->question_answer(
                    project => $project, id => $payload->{id},
                    text => $payload->{text}, author => $payload->{author},
                ),
            } );
        },
        question_attach => sub {
            my ($payload) = @_;
            die "Attaching needs a question, a filename and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id}
              || !defined $payload->{filename} || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            die "That upload is empty\n" if !length $content;

            # The browser hands over bytes rather than a path, so they are
            # written somewhere the engine can take a path to and then removed.
            require File::Temp;
            my ( $fh, $path ) = File::Temp::tempfile(
                SUFFIX => ( $payload->{filename} =~ /(\.[A-Za-z0-9]+)\z/ ? $1 : '.bin' ) );
            binmode $fh;
            print {$fh} $content;
            close $fh;
            my $question = eval {
                $tira->question_attach(
                    project => $project, id => $payload->{id},
                    file => $path, to => $payload->{to},
                    filename => $payload->{filename} );
            };
            my $error = $@;
            unlink $path;
            die $error if !$question;
            return $json->encode( { ok => Cpanel::JSON::XS::true, question => $question } );
        },
        question_mark => sub {
            my ($payload) = @_;
            die "Marking needs a question and a mark\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{mark};
            return $json->encode( {
                ok => Cpanel::JSON::XS::true,
                question => $tira->question_mark(
                    project => $project, id => $payload->{id}, mark => $payload->{mark} ),
            } );
        },
        columns => sub {
            my ($query) = @_;
            my $list = $tira->column_list( project => $project, type => $query->{type} );

            # Which columns already start new cards, so the dialog's own
            # checkbox opens showing what tira.column.roles --role entry=X
            # already declared, rather than always opening blank. TKT-494.
            my $declared = eval { $tira->column_roles( project => $project, type => $query->{type} )->{entry} };
            my @entries = ref $declared eq 'ARRAY' ? @{$declared}
              : ( defined $declared && $declared ne '' ? ($declared) : () );
            my %is_entry = map { $_ => 1 } @entries;
            $_->{entry} = $is_entry{ $_->{name} } ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false
              for @{$list};
            return $json->encode($list);
        },
        column_apply => sub {
            my ($payload) = @_;
            die "Column layout must be an object with a type and columns\n"
              if ref($payload) ne 'HASH' || ref $payload->{columns} ne 'ARRAY';
            my $result = $tira->column_apply(
                project => $project, type => $payload->{type},
                columns => $payload->{columns},
            );

            # An 'entry' field is which columns the dialog's own checkboxes
            # left checked - a full replacement of the entry role, the same
            # semantics tira.column.roles --role entry=X already has, not an
            # add-only merge. Omitted entirely (not an empty array) means the
            # save was only ever about layout, so the existing entry columns
            # are left exactly as they were. TKT-494.
            if ( exists $payload->{entry} && ref $payload->{entry} eq 'ARRAY' ) {
                $tira->column_roles_set(
                    project => $project, type => $payload->{type},
                    roles   => { entry => $payload->{entry} },
                );
            }
            return $json->encode($result);
        },
        # The board-wide police policy engine, separate from a column's own
        # required-action template (the columns/column_apply pair above): 36
        # rules covering things a column dialog cannot express at all -
        # conversation-not-folded, question-unanswered, card-stalled and the
        # rest. Requested directly: "create a new modal on the html
        # dashboard, the user can view and edit and add the policies not
        # just column policies." TKT-493.
        policies => sub {
            return $json->encode( {
                declared     => $tira->policy_list( project => $project ),
                declined     => $tira->policy_declined( project => $project ),
                undeclared   => $tira->policy_undeclared( project => $project ),
                rules        => $tira->policy_rule_specs(),
                actions      => $tira->policy_actions(),
                token_fields => $tira->policy_message_fields(),
                token_help   => $tira->policy_message_field_help(),
            } );
        },
        policy_add => sub {
            my ($payload) = @_;
            die "Policy payload must be an object\n" if ref($payload) ne 'HASH';

            # Every field policy.add itself accepts, so nothing typeable on
            # the command line is unreachable from the dashboard - the same
            # completeness bar TKT-493's own acceptance criteria set.
            my %policy = map { $_ => $payload->{$_} }
              grep { defined $payload->{$_} && $payload->{$_} ne '' }
              qw(rule action enter before column age read_age max pattern
                 message require sandbox require_link link_to
                 type on_column ref);
            return $json->encode(
                $tira->policy_add( project => $project, %policy ) );
        },
        policy_remove => sub {
            my ($payload) = @_;
            die "A policy id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode(
                $tira->policy_remove( project => $project, id => $payload->{id} ) );
        },
        policy_decline => sub {
            my ($payload) = @_;
            die "A policy rule is required\n" if !defined $payload->{rule} || $payload->{rule} eq '';
            return $json->encode(
                $tira->policy_decline(
                    project => $project, rule => $payload->{rule}, reason => $payload->{reason},
                    ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                ) );
        },

        # TKT-516: the Task List section's own providers, one per CLI verb -
        # full parity, his words, so every one of these exists even where a
        # thin dashboard control is all it needs.
        tasklist => sub {
            my ($query) = @_;
            return $json->encode(
                $tira->tasklist_list( project => $project, session => $query->{session} // '' ) );
        },
        tasklist_add => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            return $json->encode( $tira->tasklist_add(
                project => $project, text => $payload->{text}, session => $payload->{session} // '',
                refs => $payload->{refs} // [],
            ) );
        },
        tasklist_update => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode( $tira->tasklist_update(
                project => $project, id => $payload->{id}, status => $payload->{status},
                text => $payload->{text}, session => $payload->{session} // '' ) );
        },
        tasklist_next => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_next( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_shift => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_shift( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_pop => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_pop( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_unshift => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            return $json->encode( $tira->tasklist_unshift(
                project => $project, text => $payload->{text}, session => $payload->{session} // '' ) );
        },
        tasklist_slice => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            die "A position is required\n" if !defined $payload->{position};
            return $json->encode( $tira->tasklist_slice(
                project => $project, text => $payload->{text}, position => $payload->{position},
                session => $payload->{session} // '' ) );
        },
        tasklist_remove => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode( $tira->tasklist_remove(
                project => $project, id => $payload->{id}, session => $payload->{session} // '' ) );
        },
        tasklist_import => sub {
            my ($payload) = @_;
            die "A card ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_import(
                project => $project, ref => $payload->{ref}, session => $payload->{session} // '' ) );
        },
        tasklist_prune => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_prune( project => $project, session => $payload->{session} // '' ) );
        },
        tasklist_task_attach_add => sub {
            my ($payload) = @_;
            die "Attachment upload requires id, filename, and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{filename}
              || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            return $json->encode( $tira->tasklist_task_attach_add_content(
                project => $project, id => $payload->{id},
                filename => $payload->{filename}, content => $content,
                session => $payload->{session} // '',
            ) );
        },
        tasklist_task_attach_discard => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A filename is required\n" if !defined $payload->{filename} || $payload->{filename} eq '';
            return $json->encode( $tira->tasklist_task_attach_discard(
                project => $project, id => $payload->{id}, files => [ $payload->{filename} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_task_ref_link => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_task_ref_link(
                project => $project, id => $payload->{id}, refs => [ $payload->{ref} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_task_ref_unlink => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_task_ref_unlink(
                project => $project, id => $payload->{id}, refs => [ $payload->{ref} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_sessions => sub {
            return $json->encode( $tira->tasklist_sessions( project => $project ) );
        },

        search => sub {
            my ($query) = @_;

            # No type: the board filter searches the whole project, because a
            # question reference can name a card on any board.
            return $json->encode( [] ) if !defined $query->{text} || $query->{text} eq '';
            return $json->encode(
                $tira->search(
                    project => $project, text => $query->{text},
                    ( defined $query->{type} && $query->{type} ne '' ? ( type => $query->{type} ) : () ),
                    refs_only => 1,
                )
            );
        },
        create => sub {
            my ($payload) = @_;
            die "Create payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(type column title)) {
                die "Create payload requires type, column, and title\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || $payload->{$key} eq '';
            }
            my %optional;
            for my $field (qw(description priority assignee reporter)) {
                next if !defined $payload->{$field} || $payload->{$field} eq '';
                die "Field '$field' requires a plain value\n" if ref $payload->{$field};
                $optional{$field} = $payload->{$field};
            }
            $optional{reporter} = $payload->{_signed_in}
              if !defined $optional{reporter} && defined $payload->{_signed_in};
            my $record = $tira->create_record(
                project => $project, type => $payload->{type}, title => $payload->{title},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                %optional,
            );
            $record = $tira->record_move(
                project => $project, ref => $record->{ref}, column => $payload->{column},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
            ) if $payload->{column} ne 'backlog';
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        update => sub {
            my ($payload) = @_;
            die "Update payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref field)) {
                die "Update payload requires ref, field, and value\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || !exists $payload->{value};
            }
            my $field = $payload->{field};
            my $value = $payload->{value};
            if ( $list_editable{$field} ) {
                die "Field '$field' requires an array value\n" if ref $value ne 'ARRAY';
                die "Field '$field' accepts plain text items only\n" if grep { ref $_ || !defined $_ } @{$value};
                my %change;
                if ( $field =~ /\Ascope_(included|excluded)\z/ ) {
                    my $side = $1;
                    my $scope = $tira->record_show( project => $project, ref => $payload->{ref} )->{scope};
                    $change{scope} = { %{ $scope // {} }, $side => $value };
                }
                else {
                    $change{ $list_editable{$field} } = $value;
                }
                my $record = $tira->record_update(
                    project => $project, ref => $payload->{ref},
                    author => $payload->{author} // $payload->{_signed_in}, %change );
                return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
            }
            die "Field '$field' is not editable\n" if !$editable{$field};
            die "Field '$field' requires a plain value\n" if ref $value;
            die "Update base must be a plain value\n" if exists $payload->{base} && ref $payload->{base};
            my $record = $tira->record_update(
                project => $project, ref => $payload->{ref},
                author => $payload->{author} // $payload->{_signed_in}, $field => $value,
                ( exists $payload->{base} ? ( expect => { $field => $payload->{base} } ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        link_types => sub {
            return $json->encode(
                [ map { { outward => $_->{outward}, inward => $_->{inward} } }
                  @{ $tira->link_type_list( project => $project ) } ]
            );
        },
        ( map {
            my ( $name, $method ) = @{$_};
            ( $name => sub {
                my ($payload) = @_;
                die ucfirst( $name =~ tr/_/ /r ) . " requires parent and child\n"
                  if ref($payload) ne 'HASH'
                  || !defined $payload->{parent} || ref $payload->{parent}
                  || !defined $payload->{child} || ref $payload->{child};
                my $result = $tira->$method(
                    project => $project, parent => $payload->{parent}, child => $payload->{child},
                );
                return $json->encode( { ok => Cpanel::JSON::XS::true, result => $result } );
            } );
        } ( [ hierarchy_link => 'hierarchy_link' ], [ hierarchy_unlink => 'hierarchy_unlink' ],
            [ subitem_link => 'subitem_link' ], [ subitem_unlink => 'subitem_unlink' ] ) ),
        link_add => sub {
            my ($payload) = @_;
            die "Link add requires from, type, and to\n"
              if ref($payload) ne 'HASH'
              || grep { !defined $payload->{$_} || ref $payload->{$_} } qw(from type to);
            my $link = $tira->link_add(
                project => $project, from => $payload->{from},
                type => $payload->{type}, to => $payload->{to},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, link => $link } );
        },
        link_remove => sub {
            my ($payload) = @_;
            die "Link removal requires from, type, and to\n"
              if ref($payload) ne 'HASH'
              || grep { !defined $payload->{$_} || ref $payload->{$_} } qw(from type to);
            my $result = $tira->link_remove(
                project => $project, from => $payload->{from},
                type => $payload->{type}, to => $payload->{to},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, result => $result } );
        },
        checklist_add => sub {
            my ($payload) = @_;
            die "Checklist payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref item status)) {
                die "Checklist add requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $entry = $tira->checklist_add(
                project => $project, ref => $payload->{ref}, author => $payload->{author} // $payload->{_signed_in},
                item => $payload->{item}, status => $payload->{status},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        checklist_update => sub {
            my ($payload) = @_;
            die "Checklist payload must be an object\n" if ref($payload) ne 'HASH';
            die "Checklist update requires ref and id\n"
              if !defined $payload->{ref} || ref $payload->{ref} || !defined $payload->{id} || ref $payload->{id};
            my $entry = $tira->checklist_update(
                project => $project, ref => $payload->{ref}, id => $payload->{id},
                author => $payload->{author} // $payload->{_signed_in},
                ( defined $payload->{item} ? ( item => $payload->{item} ) : () ),
                ( defined $payload->{status} ? ( status => $payload->{status} ) : () ),
                ( defined $payload->{command} ? ( command => $payload->{command} ) : () ),
                ( defined $payload->{proof} ? ( proof => $payload->{proof} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        required_action_update => sub {
            my ($payload) = @_;
            die "Required action payload must be an object\n" if ref($payload) ne 'HASH';
            die "Required action update requires ref and id\n"
              if !defined $payload->{ref} || ref $payload->{ref} || !defined $payload->{id} || ref $payload->{id};
            my $entry = $tira->required_item_update(
                project => $project, ref => $payload->{ref}, id => $payload->{id},
                author => $payload->{author} // $payload->{_signed_in},
                ( defined $payload->{item} ? ( item => $payload->{item} ) : () ),
                ( defined $payload->{status} ? ( status => $payload->{status} ) : () ),
                ( defined $payload->{command} ? ( command => $payload->{command} ) : () ),
                ( defined $payload->{proof} ? ( proof => $payload->{proof} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        comment_add => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';

            # A comment is personal, unlike an assignment or a move - TKT-458.
            # Everywhere else on the board an explicit author is a deliberate
            # override the session defers to; here it is the one thing a
            # signed-in person cannot hand to someone else by picking wrong,
            # so the session wins even over an author the payload names.
            $payload->{author} = $payload->{_signed_in}
              if defined $payload->{_signed_in};
            for my $key (qw(ref author text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            die "Project person '$payload->{author}' is inactive\n"
              if grep { $_->{id} eq $payload->{author} && !$_->{active} }
              @{ $tira->person_list( project => $project ) };
            my $comment = $tira->comment_add(
                project => $project, ref => $payload->{ref},
                author => $payload->{author}, text => $payload->{text},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, comment => $comment } );
        },
        comment_update => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }

            # Same reasoning as comment_add (TKT-458): a comment is personal,
            # so the signed-in session is who edited it - not something a
            # client-sent field could override even if it tried to. TKT-466.
            my $comment = $tira->comment_update(
                project => $project, ref => $payload->{ref},
                author => $payload->{_signed_in} // $payload->{author},
                comment => $payload->{comment}, text => $payload->{text},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, comment => $comment } );
        },
        comment_remove => sub {
            my ($payload) = @_;
            die "Comment removal payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment)) {
                die "Comment removal requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $removed = $tira->comment_remove(
                project => $project, ref => $payload->{ref}, comment => $payload->{comment},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, removed => $removed } );
        },
        people => sub {
            return $json->encode(
                [ map { { id => $_->{id}, name => $_->{name} } }
                  grep { $_->{active} } @{ $tira->person_list( project => $project ) } ]
            );
        },
        attachment_fetch => sub {
            my ($payload) = @_;
            die "Attachment fetch requires ref and sha\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{sha};
            my $got = $tira->attachment_get(
                project => $project, sha => $payload->{sha},
                ( defined $payload->{extension} ? ( extension => $payload->{extension} ) : () ),
            );
            die "Attachment '$payload->{sha}' not found\n" if $got->{deleted};
            my $record = $tira->record_show( project => $project, ref => $payload->{ref} );
            my ($reference) =
              grep { $_->{sha} eq $payload->{sha} }
              ( @{ $record->{attachments} }, map { @{ $_->{attachments} // [] } } @{ $record->{comments} } );
            my $extension = $payload->{extension} // ( $reference ? $reference->{extension} : 'bin' );
            my $filename = $reference ? $reference->{original_filename} : "$payload->{sha}.$extension";
            return {
                content => $got->{content},
                content_type => Tira::CLI::_attachment_content_type($extension),
                filename => $filename,
                inline => Tira::CLI::_attachment_content_type($extension) eq 'application/octet-stream' ? 0 : 1,
            };
        },
        attachment_add => sub {
            my ($payload) = @_;
            die "Attachment upload requires ref, filename, and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{filename}
              || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            my $attachment = $tira->attachment_add_content(
                project => $project, ref => $payload->{ref},
                filename => $payload->{filename}, content => $content,
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, attachment => $attachment } );
        },
        attachment_discard => sub {
            my ($payload) = @_;
            die "Discard payload must be an object\n" if ref($payload) ne 'HASH';
            my $reference = $tira->attachment_discard(
                project => $project, ref => $payload->{ref}, sha => $payload->{sha},
                extension => $payload->{extension},
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
            );
            return Tira::json_object()->canonical->encode(
                { ok => Cpanel::JSON::XS::true, attachment => $reference } );
        },

        attachment_remove => sub {
            my ($payload) = @_;
            die "Attachment removal requires ref and sha\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{sha};
            my $result = $tira->attachment_detach(
                project => $project, ref => $payload->{ref}, sha => $payload->{sha},
                ( defined $payload->{extension} ? ( extension => $payload->{extension} ) : () ),
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, %{$result} } );
        },
    );
}

1;

__END__

=head1 NAME

Tira::CLI::Browser - the coderefs the browser dashboard is built from

=head1 DESCRIPTION

C<providers> returns the flat hash of named coderefs L<Tira::DashboardWeb>
requires to build its Dancer2 app - one entry per route, so a browser mutation
can never drift from the engine's own validated command surface.

It lived in C<Tira::CLI> until 4.74, where it was 701 lines of the 6,048 that
had to be read to change any command at all. It is needed by one invocation,
the one that serves a board, so C<Tira::CLI> now loads it with C<require> at
that point - the shape the CLI already used for L<Tira::DashboardWeb> and
L<Tira::OnboardWeb>, and the reason a CLI call that never serves a board never
compiles Dancer2.

=head2 providers

Takes C<tira> and C<project>. Returns the provider hash.

TKT-516 added C<tasklist>, C<tasklist_add>, C<tasklist_update>,
C<tasklist_next>, C<tasklist_shift>, C<tasklist_pop>, C<tasklist_unshift>,
C<tasklist_slice>, C<tasklist_remove>, C<tasklist_import>, C<tasklist_prune>,
C<tasklist_task_attach_add>, C<tasklist_task_attach_discard>,
C<tasklist_task_ref_link>, and C<tasklist_task_ref_unlink>, giving the browser
dashboard's Task List section full parity with C<tira.tasklist.*>.

TKT-540: C<tasklist_update>, C<tasklist_remove>, C<tasklist_task_attach_add>,
C<tasklist_task_attach_discard>, C<tasklist_task_ref_link>, and
C<tasklist_task_ref_unlink> now forward the payload's C<session> field to the
engine, matching the other eight tasklist providers - previously these six
silently dropped it, so a session switched in the dashboard's own session box
could view an item it could not then mutate once TKT-538 began enforcing
session ownership.

=head2 Why the helpers are written out in full

Six of C<Tira::CLI>'s private helpers are called from here, as
C<Tira::CLI::_attachment_content_type> and so on rather than imported. Nothing
loads this module except C<Tira::CLI>, so that package is always in memory by
the time any of these run.

Qualifying them is deliberate beyond necessity: a reader of this file can see
that the helper lives in the index rather than here, which is the distinction
the split exists to make. An import would have hidden exactly the fact worth
showing.

=head2 How this module is loaded

C<Tira::CLI> pulls this in with C<require> at the point one of its verbs runs,
so a command that never needs it never compiles it. It calls into L<Tira::CLI::Police>, and asks for
that the same way - inside the sub that needs it, not at the top of this
file. A C<use> there is correct and turns a lazy chain eager, which is how
C<tira.next> came to compile four modules for the sake of one helper for the
first hour after the split.

=head1 SEE ALSO

L<Tira::CLI>, L<Tira::DashboardWeb>

=cut
