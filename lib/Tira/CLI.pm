package Tira::CLI;

use strict;
use warnings;

use Encode qw(decode encode_utf8 FB_CROAK);
use Cwd qw(cwd);
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP ();
use Tira;

sub run {
    my ( $class, %args ) = @_;
    my $command = $args{command} // '';
    my $type = $args{type};
    my $argv = $args{argv} || [];
    my $tira = $args{tira} || Tira->new( path_resolver => _dd_path_resolver() );
    my $browser_server = $args{browser_server} || \&_serve_browser;
    my %option = ( output => 'toon' );
    my $environment_project;
    my $decoded = eval {
        for my $argument ( @{$argv} ) {
            $argument = decode( 'UTF-8', $argument, FB_CROAK ) if !utf8::is_utf8($argument);
        }
        if ( defined $ENV{TIRA_HOME} ) {
            $environment_project = utf8::is_utf8( $ENV{TIRA_HOME} )
              ? $ENV{TIRA_HOME} : decode( 'UTF-8', $ENV{TIRA_HOME}, FB_CROAK );
        }
        1;
    };
    return _error( $tira, 'toon', $@ || 'Invalid UTF-8 command-line input' ) if !$decoded;
    my $parsed = GetOptionsFromArray(
        $argv,
        'name=s' => \$option{name}, 'dir=s' => \$option{dir}, 'title:s' => \$option{title},
        'description=s' => \$option{description}, 'project=s' => \$option{project},
        'output|o=s' => \$option{output}, 'help' => \$option{help},
        'id=s' => \$option{id}, 'email=s' => \$option{email},
        'outward=s' => \$option{outward}, 'inward=s' => \$option{inward},
        'type=s' => \$option{type}, 'label=s@' => \$option{labels},
        'after=s' => \$option{after}, 'before=s' => \$option{before},
        'new-name=s' => \$option{new_name}, 'prefix=s' => \$option{prefix},
        'digits=i' => \$option{digits}, 'ref=s' => \$option{ref},
        'column=s' => \$option{column}, 'parent=s' => \$option{parent},
        'child=s' => \$option{child},
        'text=s' => \$option{text}, 'problem|problem-or-feature=s' => \$option{problem_or_feature},
        'solution-needed=s' => \$option{solution_needed}, 'source=s' => \$option{source},
        'from=s' => \$option{from}, 'to=s' => \$option{to},
        'author=s' => \$option{author}, 'file=s' => \$option{file},
        'format=s' => \$option{format}, 'comment=s' => \$option{comment},
        'sha=s' => \$option{sha}, 'extension=s' => \$option{extension},
        'summary=s' => \$option{summary}, 'uri=s' => \$option{uri},
        'gate=s' => \$option{gate}, 'result=s' => \$option{result},
        'details=s' => \$option{details},
        'item=s' => \$option{item}, 'status=s' => \$option{status},
        'field=s@' => \$option{fields}, 'pattern=s' => \$option{pattern},
        'with=s' => \$option{with}, 'note=s' => \$option{note},
        'reporter=s' => \$option{reporter}, 'due-date=s' => \$option{due_date},
        'start-date=s' => \$option{start_date}, 'sdlc-gate=s' => \$option{sdlc_gate},
        'lifecycle=s' => \$option{lifecycle}, 'priority=s' => \$option{priority},
        'fix-version=s' => \$option{fix_version},
        'repair-columns' => \$option{repair_columns}, 'apply' => \$option{apply},
        'recursive' => \$option{recursive}, 'include-deleted' => \$option{include_deleted},
        'include-discard' => \$option{include_discard},
        'full' => \$option{full}, 'dry-run' => \$option{dry_run},
        'key-detail=s@' => \$option{key_details}, 'deliverable=s@' => \$option{deliverables},
        'scope-in=s@' => \$option{scope_in}, 'scope-out=s@' => \$option{scope_out},
        'acceptance|acceptance-criteria=s@' => \$option{acceptance}, 'test-step=s@' => \$option{test_steps},
        'bdd=s@' => \$option{bdd}, 'atdd=s@' => \$option{atdd},
        'assignee=s' => \$option{assignee}, 'person=s@' => \$option{people},
        'attach=s@' => \$option{attach},
        'affects-version=s@' => \$option{affects_versions},
        'set-key-details=s' => \$option{set_key_details},
        'set-deliverables=s' => \$option{set_deliverables},
        'set-acceptance|set-acceptance-criteria=s' => \$option{set_acceptance},
        'set-test-steps=s' => \$option{set_test_steps},
        'set-bdd=s' => \$option{set_bdd}, 'set-atdd=s' => \$option{set_atdd},
        'set-labels=s' => \$option{set_labels},
        'set-affects-versions=s' => \$option{set_affects_versions},
    );
    return _error( $tira, $option{output}, 'Invalid command-line options' ) if !$parsed || @{$argv};

    if ( $option{help} ) {
        print _usage( $command, $type );
        return 0;
    }

    return _error( $tira, 'toon', "Unsupported output format '$option{output}'" )
      if $command eq 'attachment.get' && $option{output} !~ /\A(?:toon|json|human)\z/;
    return _error( $tira, 'toon', 'Table output is available only for dashboard commands' )
      if $option{output} eq 'table' && $command !~ /\Adashboard(?:\.(?:sow|epic|ticket))?\z/;
    return _error( $tira, 'toon', 'Browser output is available only for dashboard commands' )
      if $option{output} =~ /\Abrowser(?:=|\z)/ && $command !~ /\Adashboard(?:\.(?:sow|epic|ticket))?\z/;

    my ( $browser_host, $browser_port );
    if ( $option{output} =~ /\Abrowser(?:=(.*))?\z/ ) {
        my $endpoint = defined $1 && length $1 ? $1 : '0.0.0.0:7899';
        my $valid = eval {
            ( $browser_host, $browser_port ) = _browser_endpoint($endpoint);
            1;
        };
        return _error( $tira, 'toon', $@ || 'Invalid browser endpoint' ) if !$valid;
    }

    $option{project} = $environment_project if !defined $option{project} && defined $environment_project;

    my $result;
    my $ok = eval {
        $result = _invoke( $tira, $command, $type, \%option );
        1;
    };
    return _error( $tira, $option{output}, $@ || 'Unknown Tira failure' ) if !$ok;

    if ( $command eq 'attachment.get' ) {
        print $result->{content};
        return $result->{deleted} ? 1 : 0;
    }

    if ( defined $browser_host ) {
        my $render = sub {
            my %render_option = %option;
            $render_option{output} = 'table';
            my $dashboard = _invoke( $tira, $command, $type, \%render_option );
            return $tira->format_output(
                $dashboard, output => 'table', project => $option{project}, live => 1,
                with_title => defined $option{title},
            );
        };
        my $data = sub {
            my %data_option = %option;
            $data_option{output} = 'toon';
            my $dashboard = _invoke( $tira, $command, $type, \%data_option );
            return $tira->format_output( $dashboard, output => 'json', project => $option{project} );
        };
        my %providers = browser_providers( tira => $tira, project => $option{project} );
        my $served = eval {
            $browser_server->(
                host => $browser_host, port => $browser_port, render => $render, data => $data,
                %providers,
            );
            1;
        };
        return _error( $tira, 'toon', $@ || 'Unable to serve dashboard' ) if !$served;
        return 0;
    }

    my $formatted = eval { $tira->format_output( $result, output => $option{output}, project => $option{project} ) };
    return _error( $tira, 'toon', $@ || 'Unable to format output' ) if !defined $formatted;
    print _utf8_bytes($formatted);
    return 0;
}

sub _dd_path_resolver {
    return sub {
        my ($name) = @_;
        require Developer::Dashboard::Config;
        require Developer::Dashboard::FileRegistry;
        require Developer::Dashboard::PathRegistry;
        my $home = $ENV{HOME} // '';
        $home =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe home path\n";
        $home = $1;
        my $paths = Developer::Dashboard::PathRegistry->new(
            home => $home, cwd => cwd(), workspace_roots => [], project_roots => [],
        );
        my $files = Developer::Dashboard::FileRegistry->new( paths => $paths );
        my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
        $paths->register_named_paths( $config->path_aliases );
        return $paths->resolve_dir($name);
    };
}

sub _browser_endpoint {
    my ($endpoint) = @_;
    $endpoint =~ /\A(0\.0\.0\.0|127\.0\.0\.1|localhost)(?::([0-9]+))?\z/
      or die "Unsupported browser endpoint '$endpoint'\n";
    my ( $host, $port ) = ( $1, defined $2 ? 0 + $2 : 7899 );
    die "Browser port must be between 1 and 65535\n" if $port < 1 || $port > 65535;
    return ( $host, $port );
}

sub _serve_browser {
    require Tira::DashboardWeb;
    return Tira::DashboardWeb->serve(@_);
}

# One provider set feeds both the CLI-launched Dancer2 server and the
# standalone dashboard.psgi, so browser mutations can never drift from the
# engine's validated command surface.
sub browser_providers {
    my (%args) = @_;
    my $tira = $args{tira};
    my $project = $args{project};
    my $json = JSON::PP->new->canonical;
    my %editable = map { $_ => 1 } qw(
        title description problem_or_feature solution_needed source
        sdlc_gate lifecycle fix_version assignee reporter priority
        start_date due_date
    );
    return (
        move => sub {
            my ($payload) = @_;
            die "Move payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(type ref column)) {
                die "Move payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $record = $tira->record_move(
                project => $project, type => $payload->{type},
                ref => $payload->{ref}, column => $payload->{column},
            );
            return $json->encode( { ok => JSON::PP::true, record => $record } );
        },
        detail => sub {
            my ($payload) = @_;
            die "Record detail requires type and ref\n"
              if ref($payload) ne 'HASH' || !defined $payload->{type} || !defined $payload->{ref};
            my $record = $tira->record_show(
                project => $project, type => $payload->{type}, ref => $payload->{ref},
            );
            return $json->encode($record);
        },
        update => sub {
            my ($payload) = @_;
            die "Update payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref field)) {
                die "Update payload requires ref, field, and value\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || !exists $payload->{value};
            }
            die "Field '$payload->{field}' is not editable\n" if !$editable{ $payload->{field} };
            die "Update payload requires ref, field, and a plain value\n" if ref $payload->{value};
            my $record = $tira->record_update(
                project => $project, ref => $payload->{ref},
                $payload->{field} => $payload->{value},
            );
            return $json->encode( { ok => JSON::PP::true, record => $record } );
        },
        comment_add => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';
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
            return $json->encode( { ok => JSON::PP::true, comment => $comment } );
        },
        comment_update => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $comment = $tira->comment_update(
                project => $project, ref => $payload->{ref},
                comment => $payload->{comment}, text => $payload->{text},
            );
            return $json->encode( { ok => JSON::PP::true, comment => $comment } );
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
            return $json->encode( { ok => JSON::PP::true, removed => $removed } );
        },
        people => sub {
            return $json->encode(
                [ map { { id => $_->{id}, name => $_->{name} } }
                  grep { $_->{active} } @{ $tira->person_list( project => $project ) } ]
            );
        },
    );
}

sub _invoke {
    my ( $tira, $command, $record_type, $option ) = @_;
    my %args = %{$option};
    delete @args{qw(output help apply repair_columns recursive include_deleted include_discard full dry_run attach set_key_details set_deliverables set_acceptance set_test_steps set_bdd set_atdd set_labels set_affects_versions)};
    $args{type} = $record_type if defined $record_type;
    my %sets = (
        set_key_details => 'key_details_replace', set_deliverables => 'deliverables_replace',
        set_acceptance => 'acceptance_replace', set_test_steps => 'test_steps_replace',
        set_bdd => 'bdd_replace', set_atdd => 'atdd_replace',
        set_labels => 'labels_replace', set_affects_versions => 'affects_versions_replace',
    );
    for my $set ( keys %sets ) {
        next if !defined $option->{$set};
        my $append = $set eq 'set_labels' ? 'labels'
          : $set eq 'set_affects_versions' ? 'affects_versions'
          : $sets{$set} =~ s/_replace\z//r;
        die "Cannot combine append and replacement for '$append'\n" if defined $args{$append};
        $args{ $sets{$set} } = _json_array_input( $option->{$set} );
    }
    $args{label} = $option->{labels}[0] if $command =~ /\Acolumn\.(?:add|rename)\z/ && $option->{labels};

    return $tira->create_project( name => $option->{name}, dir => $option->{dir} // '.' ) if $command eq 'project.create';
    return $tira->create_record(%args) if $command eq 'record.create';
    return $tira->export_records(%args) if $command eq 'export';
    if ( $command eq 'import' ) {
        die "Import file is required\n" if !defined $option->{file};
        my $changes = JSON::PP::decode_json( _text_input( $option->{file} ) );
        return $tira->bulk_import( %args, changes => $changes, dry_run => $option->{dry_run} );
    }
    return $tira->replace_records( %args, dry_run => $option->{dry_run} ) if $command eq 'replace';
    return $tira->project_show(%args) if $command eq 'project.show';
    return $tira->project_update(%args) if $command eq 'project.update';
    return $tira->person_list(%args) if $command eq 'project.people.list';
    return $tira->person_add(%args) if $command eq 'project.people.add';
    return $tira->person_update(%args) if $command eq 'project.people.update';
    return $tira->person_remove(%args) if $command eq 'project.people.remove';
    return $tira->person_activate(%args) if $command eq 'project.people.activate';
    return $tira->person_deactivate(%args) if $command eq 'project.people.deactivate';
    return $tira->link_type_list(%args) if $command eq 'project.link-types.list';
    return $tira->link_type_add(%args) if $command eq 'project.link-types.add';
    return $tira->link_type_remove(%args) if $command eq 'project.link-types.remove';
    return $tira->project_validate( %args, repair => $option->{repair_columns} ) if $command eq 'project.validate';
    return $tira->board_show(%args) if $command eq 'board.show';
    return $tira->board_refs(%args) if $command eq 'board.refs';
    return $tira->column_list(%args) if $command eq 'column.list';
    return $tira->column_add(%args) if $command eq 'column.add';
    return $tira->column_rename(%args) if $command eq 'column.rename';
    return $tira->column_reorder(%args) if $command eq 'column.reorder';
    return $tira->column_remove(%args) if $command eq 'column.remove';
    return $tira->column_sync( %args, apply => $option->{apply} ) if $command eq 'column.sync';

    if ( $command =~ /\Arecord\.(show|list|update|move|discard|restore|clone)\z/ ) {
        my $action = $1;
        return $tira->record_show(%args) if $action eq 'show';
        return $tira->record_list(%args) if $action eq 'list';
        return $tira->record_update(%args) if $action eq 'update';
        return $tira->record_move(%args) if $action eq 'move';
        return $tira->record_discard(%args) if $action eq 'discard';
        return $tira->record_restore(%args) if $action eq 'restore';
        return $tira->record_clone(%args);
    }

    my %method = (
        'hierarchy.link' => 'hierarchy_link', 'hierarchy.unlink' => 'hierarchy_unlink', 'hierarchy.show' => 'hierarchy_show',
        'subitem.link' => 'subitem_link', 'subitem.unlink' => 'subitem_unlink',
        'link.add' => 'link_add', 'link.remove' => 'link_remove', 'link.list' => 'link_list',
        'assign.list' => 'assignment_list', 'assign.add' => 'assignment_add',
        'assign.remove' => 'assignment_remove', 'assign.set' => 'assignment_set',
        'comment.list' => 'comment_list', 'comment.add' => 'comment_add',
        'comment.update' => 'comment_update', 'comment.remove' => 'comment_remove',
        'comment.attach' => 'comment_attach',
        'attachment.add' => 'attachment_add', 'attachment.list' => 'attachment_list',
        'attachment.get' => 'attachment_get', 'attachment.remove' => 'attachment_remove',
        'evidence.list' => 'evidence_list', 'evidence.add' => 'evidence_add',
        'evidence.annotate' => 'evidence_annotate',
        'gate.list' => 'gate_list', 'gate.add' => 'gate_add',
        'gate.annotate' => 'gate_annotate',
        'checklist.list' => 'checklist_list', 'checklist.add' => 'checklist_add',
        'checklist.update' => 'checklist_update',
        'search' => 'search', 'dashboard' => 'dashboard',
        'dashboard.sow' => 'dashboard', 'dashboard.epic' => 'dashboard', 'dashboard.ticket' => 'dashboard',
    );
    my $method = $method{$command} or die "Unsupported Tira command '$command'\n";
    $args{person} = $option->{people}[0] if $command =~ /\Aassign\.(?:add|remove)\z/ && $option->{people};
    $args{people} = $option->{people} // [] if $command eq 'assign.set';
    $args{recursive} = $option->{recursive} if $command eq 'hierarchy.show';
    if ( $command =~ /\Adashboard(?:\.(sow|epic|ticket))?\z/ ) {
        $args{type} = $1 if defined $1;
        $args{include_discard} = $option->{include_discard};
        $args{summary} = $option->{output} ne 'json';
        $args{with_title} = defined $option->{title};
        $args{include_mtime} = $option->{output} eq 'table' || $option->{output} =~ /\Abrowser(?:=|\z)/;
    }
    $args{include_deleted} = $option->{include_deleted} if $command eq 'attachment.list';
    if ( $command =~ /\Acomment\.(?:add|update)\z/ && defined $option->{file} ) {
        die "Use only one of --text or --file\n" if defined $option->{text};
        $args{text} = _text_input( $option->{file}, utf8 => 1 );
    }
    if ( $command eq 'comment.add' && $option->{attach} ) {
        my $comment = $tira->$method(%args);
        $tira->comment_attach( %args, comment => $comment->{id}, file => $_ ) for @{ $option->{attach} };
        return $tira->comment_list(%args)->[-1];
    }
    return $tira->$method(%args);
}

sub _text_input {
    my ( $file, %args ) = @_;
    my $fh;
    if ( $file eq '-' ) {
        $fh = *STDIN;
    }
    else {
        open $fh, '<:raw', $file or die "Cannot read '$file': $!\n";
    }
    my $content = do { local $/; <$fh> };
    close $fh if $file ne '-';
    return $args{utf8} ? decode( 'UTF-8', $content, FB_CROAK ) : $content;
}

sub _json_array_input {
    my ($file) = @_;
    my $data = JSON::PP::decode_json( _text_input($file) );
    die "Replacement input must be a JSON array\n" if ref($data) ne 'ARRAY';
    return $data;
}

sub _error {
    my ( $tira, $output, $message ) = @_;
    $message =~ s/\s+\z//;
    my $formatted = eval { $tira->format_output( { error => $message }, output => $output ) };
    $formatted = JSON::PP->new->canonical->pretty->encode( { error => $message } ) if !defined $formatted;
    print STDERR _utf8_bytes($formatted);
    return 2;
}

sub _utf8_bytes {
    my ($text) = @_;
    return utf8::is_utf8($text) ? encode_utf8($text) : $text;
}

sub _usage {
    my ( $command, $type ) = @_;
    return "Usage: dashboard tira.project.create --name NAME [--dir DIR] [-o toon|json|human]\n"
      if $command eq 'project.create';
    return "Usage: dashboard tira.$type.create --title TITLE [record field options] [-o toon|json|human]\n"
      if defined $type;
    return "Usage: dashboard tira.$command [options] [-o toon|json|human]\n";
}

1;

__END__

=head1 NAME

Tira::CLI - Shared command boundary for Tira DD commands

=head1 DESCRIPTION

Parses the common project and record metadata options, invokes L<Tira>, and
applies the TOON-first output and structured error contract. Project-location
selection is intentionally omitted from user-facing help. Text input is decoded
strictly as UTF-8 and structured output is emitted as UTF-8 bytes; attachment
content remains raw. Dashboard commands additionally support self-contained
HTML and validated Dancer2 browser serving.

=head1 METHODS

=head2 run

Runs one named command against an argument array and returns its process exit
code without calling C<exit>, allowing direct unit testing.

=cut
